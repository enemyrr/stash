import CryptoKit
import Foundation

/// The only network layer. Every call fails with a typed `S3Error` (or `CancellationError`) instead of hanging.
public final class S3Client: Sendable {
    public let config: S3Config
    /// Small requests get their own connections so they never queue behind upload bytes on a shared HTTP/2 connection.
    let controlSession: URLSession
    let transferSession: URLSession
    let signer: SigV4Signer

    public convenience init(config: S3Config) {
        self.init(config: config, sessionConfiguration: .ephemeral)
    }

    init(config: S3Config, sessionConfiguration: URLSessionConfiguration) {
        sessionConfiguration.timeoutIntervalForRequest = config.timeouts.connect
        sessionConfiguration.timeoutIntervalForResource = 24 * 60 * 60
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpMaximumConnectionsPerHost = max(8, config.multipart.concurrency * 2)
        self.config = config
        controlSession = URLSession(configuration: sessionConfiguration)
        transferSession = URLSession(configuration: sessionConfiguration)
        signer = SigV4Signer(accessKeyId: config.accessKeyId, secretAccessKey: config.secretAccessKey, region: config.region)
    }

    deinit {
        controlSession.finishTasksAndInvalidate()
        transferSession.finishTasksAndInvalidate()
    }

    // MARK: List

    public func listObjectsV2(
        prefix: String? = nil, delimiter: String? = nil, continuationToken: String? = nil, maxKeys: Int? = nil
    ) async throws -> ListResult {
        var query = ["list-type": "2", "encoding-type": "url"]
        query["prefix"] = prefix
        query["delimiter"] = delimiter
        query["continuation-token"] = continuationToken
        query["max-keys"] = maxKeys.map(String.init)
        let response = try await execute(S3Request(method: "GET", query: query))
        return try ListResult(xml: XMLNode.parse(response.body))
    }

    /// Pages through the whole listing. `nextContinuationToken` is always nil.
    public func listAll(prefix: String? = nil, delimiter: String? = nil) async throws -> ListResult {
        var result = ListResult(objects: [], commonPrefixes: [])
        var token: String?
        repeat {
            let page = try await listObjectsV2(prefix: prefix, delimiter: delimiter, continuationToken: token)
            result.objects += page.objects
            result.commonPrefixes += page.commonPrefixes
            if let next = page.nextContinuationToken, next == token {
                throw S3Error.invalidResponse("Continuation token did not advance")
            }
            token = page.nextContinuationToken
        } while token != nil
        return result
    }

    // MARK: Read

    public func head(_ key: String, ifMatch etag: String? = nil) async throws -> ObjectInfo {
        let headers = etag.map { Precondition.ifMatch($0).headers } ?? [:]
        let response = try await execute(S3Request(method: "HEAD", key: key, headers: headers))
        return ObjectInfo(headers: response.headers)
    }

    public func get(_ key: String, range: ClosedRange<Int64>? = nil, ifMatch etag: String? = nil) async throws -> Data {
        try await execute(getRequest(key, range: range, ifMatch: etag)).body
    }

    /// Streams to a temporary file and replaces `destination` only after a complete, valid response.
    @discardableResult
    public func get(
        _ key: String, range: ClosedRange<Int64>? = nil, ifMatch etag: String? = nil, to destination: URL
    ) async throws -> ObjectInfo {
        ObjectInfo(headers: try await execute(getRequest(key, range: range, ifMatch: etag), saveTo: destination).headers)
    }

    private func getRequest(_ key: String, range: ClosedRange<Int64>?, ifMatch etag: String?) -> S3Request {
        S3Request(
            method: "GET", key: key, headers: etag.map { Precondition.ifMatch($0).headers } ?? [:],
            timing: .transfer(bytes: range.map { Int64($0.count) }), range: range
        )
    }

    // MARK: Write

    /// Returns the new ETag.
    @discardableResult
    public func put(
        _ key: String, data: Data, contentType: String? = nil, metadata: [String: String] = [:], condition: Precondition? = nil
    ) async throws -> String {
        let response = try await execute(S3Request(
            method: "PUT", key: key, headers: objectHeaders(contentType, metadata, condition),
            body: .data(data), timing: .transfer(bytes: Int64(data.count))
        ))
        return ETag.strip(response.headers["etag"] ?? "")
    }

    /// Streams from disk. Files of at least `multipart.threshold` bytes go through a parallel multipart upload,
    /// which is aborted on failure or cancellation. Returns the new ETag.
    /// For multipart uploads `condition` goes on CompleteMultipartUpload, which some providers, such as Hetzner, ignore.
    @discardableResult
    public func put(
        _ key: String, fileURL: URL, contentType: String? = nil, metadata: [String: String] = [:], condition: Precondition? = nil
    ) async throws -> String {
        let size = try Int64(fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        if size >= config.multipart.threshold {
            return try await putMultipart(
                key, file: FileReader(fileURL), headers: objectHeaders(contentType, metadata, nil), condition: condition
            )
        }
        let response = try await execute(S3Request(
            method: "PUT", key: key, headers: objectHeaders(contentType, metadata, condition),
            body: .file(fileURL), timing: .transfer(bytes: size)
        ))
        return ETag.strip(response.headers["etag"] ?? "")
    }

    /// Server-side copy within the bucket. Fails with `.preconditionFailed` if the source ETag differs from
    /// `sourceIfMatch`, or if `condition` does not hold for the destination. Returns the new ETag.
    /// The source check is always enforced; some providers, such as Hetzner, ignore the destination `condition`.
    /// `updatingMetadata` replaces those metadata entries and keeps the others, so a copy onto itself updates metadata.
    @discardableResult
    public func copy(
        from source: String, to destination: String, sourceIfMatch: String? = nil, condition: Precondition? = nil,
        updatingMetadata: [String: String]? = nil
    ) async throws -> String {
        var info = try await head(source, ifMatch: sourceIfMatch)
        if let updatingMetadata { info.metadata.merge(updatingMetadata) { $1 } }
        if info.size > config.multipart.copyThreshold {
            return try await copyMultipart(from: source, to: destination, source: info, condition: condition)
        }
        var headers = condition?.headers ?? [:]
        if updatingMetadata != nil {
            headers.merge(objectHeaders(info.contentType, info.metadata, nil)) { $1 }
            headers["x-amz-metadata-directive"] = "REPLACE"
        }
        headers["x-amz-copy-source"] = copySource(source)
        headers["x-amz-copy-source-if-match"] = info.etag
        let response = try await execute(S3Request(method: "PUT", key: destination, headers: headers, timing: .serverWork))
        return ETag.strip(try XMLNode.parse(response.body).value("ETag") ?? "")
    }

    // MARK: Delete

    /// Succeeds for missing keys too.
    public func delete(_ key: String) async throws {
        _ = try await execute(S3Request(method: "DELETE", key: key))
    }

    /// Deletes in batches of 1000. Returns per-key failures; transport and auth errors throw.
    public func deleteObjects(_ keys: [String]) async throws -> [DeleteFailure] {
        var failures: [DeleteFailure] = []
        for start in stride(from: 0, to: keys.count, by: 1000) {
            let objects = keys[start..<min(start + 1000, keys.count)].map { "<Object><Key>\(XMLNode.escape($0))</Key></Object>" }
            let body = Data("<Delete><Quiet>true</Quiet>\(objects.joined())</Delete>".utf8)
            let headers = [
                "content-type": "application/xml",
                "content-md5": Data(Insecure.MD5.hash(data: body)).base64EncodedString(),
            ]
            let response = try await execute(S3Request(
                method: "POST", query: ["delete": ""], headers: headers, body: .data(body), timing: .serverWork
            ))
            failures += try DeleteFailure.parse(XMLNode.parse(response.body))
        }
        return failures
    }

    // MARK: Helpers

    func objectHeaders(_ contentType: String?, _ metadata: [String: String], _ condition: Precondition?) -> [String: String] {
        var headers = condition?.headers ?? [:]
        headers["content-type"] = contentType ?? "application/octet-stream"
        for (name, value) in metadata { headers["x-amz-meta-\(name.lowercased())"] = value }
        return headers
    }

    func copySource(_ key: String) -> String {
        "/\(URIEncoding.encode(config.bucket))/\(URIEncoding.encode(key, keepSlash: true))"
    }
}
