import Foundation

struct S3Request: Sendable {
    enum Body: Sendable {
        case empty
        case data(Data)
        /// Streamed from disk with an unsigned payload.
        case file(URL)
    }

    enum Timing: Sendable {
        /// Idle limit `connect`, whole-call limit `request`.
        case quick
        /// Idle limit `stall`, whole-call limit scaled by size. `nil` means unknown size: idle limit only.
        case transfer(bytes: Int64?)
        /// Idle limit `stall`, no whole-call limit. A 200 response may still carry an `<Error>` body.
        case serverWork
    }

    var method: String
    var key: String?
    var query: [String: String] = [:]
    var headers: [String: String] = [:]
    var body: Body = .empty
    var timing: Timing = .quick
    var range: ClosedRange<Int64>?

    /// Replaying a conditional write or CompleteMultipartUpload after a 5xx can report failure for a write
    /// that already committed (412, NoSuchUpload), so those surface the first error instead.
    var isSafeToRetry: Bool {
        headers["if-match"] == nil && headers["if-none-match"] == nil && !(method == "POST" && query["uploadId"] != nil)
    }
}

struct S3Response: Sendable {
    var status: Int
    /// Lowercased names.
    var headers: [String: String]
    var body: Data
    /// Downloaded body, owned by the client until `send` installs or deletes it.
    var file: URL?

    init(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw S3Error.invalidResponse("Not an HTTP response") }
        status = http.statusCode
        headers = http.allHeaderFields.reduce(into: [:]) { result, field in
            if let name = field.key as? String, let value = field.value as? String { result[name.lowercased()] = value }
        }
        self.body = body
    }
}

extension S3Client {
    func execute(_ request: S3Request, saveTo destination: URL? = nil) async throws -> S3Response {
        var attempt = 1
        while true {
            do {
                return try await send(request, saveTo: destination)
            } catch let error as S3Error
                where error.isTransientServerError && request.isSafeToRetry && attempt < config.retry.maxAttempts {
                let delay = config.retry.baseDelay * pow(2, Double(attempt - 1)) * .random(in: 0.5...1.5)
                try await Task.sleep(for: .seconds(delay))
                attempt += 1
            }
        }
    }

    private func send(_ request: S3Request, saveTo destination: URL?) async throws -> S3Response {
        let urlRequest = try urlRequest(for: request, date: Date())
        let response: S3Response
        do {
            response = try await withDeadline(deadline(for: request.timing)) {
                let session = if case .transfer = request.timing { self.transferSession } else { self.controlSession }
                return try await Self.transport(urlRequest, on: session, body: request.body, saveTo: destination)
            }
        } catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            throw S3Error(error)
        }
        defer { response.file.map { try? FileManager.default.removeItem(at: $0) } }
        guard (200..<300).contains(response.status) else {
            throw S3Error(status: response.status, body: response.file.flatMap { try? Data(contentsOf: $0) } ?? response.body)
        }
        if let range = request.range {
            guard response.status == 206, response.headers["content-range"]?.hasPrefix("bytes \(range.lowerBound)-") == true else {
                throw S3Error.invalidResponse("Server ignored or changed the requested range")
            }
        }
        if case .serverWork = request.timing, (try? XMLNode.parse(response.body))?.name == "Error" {
            throw S3Error(status: response.status, body: response.body)
        }
        if let destination, let file = response.file {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: file)
            } else {
                try FileManager.default.moveItem(at: file, to: destination)
            }
        }
        return response
    }

    private static func transport(
        _ request: URLRequest, on session: URLSession, body: S3Request.Body, saveTo: URL?
    ) async throws -> S3Response {
        if saveTo != nil {
            let (temporary, response) = try await session.download(for: request)
            var result = try S3Response(response, body: Data())
            let owned = FileManager.default.temporaryDirectory.appending(path: "s3client-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: temporary, to: owned)
            result.file = owned
            return result
        }
        let (data, response) = switch body {
        case .empty: try await session.data(for: request)
        case let .data(payload): try await session.upload(for: request, from: payload)
        case let .file(url): try await session.upload(for: request, fromFile: url)
        }
        return try S3Response(response, body: data)
    }

    func urlRequest(for request: S3Request, date: Date) throws -> URLRequest {
        guard let scheme = config.endpoint.scheme, let endpointHost = config.endpoint.host() else {
            throw S3Error.invalidRequest("Endpoint needs a scheme and host: \(config.endpoint)")
        }
        let port = config.endpoint.port.map { ":\($0)" } ?? ""
        let key = request.key.map { URIEncoding.encode($0, keepSlash: true) }
        let bucket = URIEncoding.encode(config.bucket)
        let (host, path) = switch config.addressingStyle {
        case .path: ("\(endpointHost)\(port)", key.map { "/\(bucket)/\($0)" } ?? "/\(bucket)")
        case .virtualHost: ("\(bucket).\(endpointHost)\(port)", "/\(key ?? "")")
        }
        let query = SigV4Signer.canonicalQuery(request.query)
        guard let url = URL(string: "\(scheme)://\(host)\(path)\(query.isEmpty ? "" : "?\(query)")") else {
            throw S3Error.invalidRequest("Cannot build URL for key \(request.key ?? "")")
        }

        let payloadHash = switch request.body {
        case .empty: SigV4Signer.emptyPayloadHash
        case let .data(data): SigV4Signer.sha256Hex(data)
        case .file: SigV4Signer.unsignedPayload
        }
        var headers = request.headers
        headers["range"] = request.range.map { "bytes=\($0.lowerBound)-\($0.upperBound)" }
        headers["host"] = host
        headers["x-amz-date"] = SigV4Signer.amzDate(date)
        headers["x-amz-content-sha256"] = payloadHash
        let authorization = signer.authorization(
            method: request.method, path: path, query: request.query, headers: headers, payloadHash: payloadHash
        )
        headers["host"] = nil

        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: idleTimeout(for: request.timing))
        urlRequest.httpMethod = request.method
        for (name, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.setValue(authorization, forHTTPHeaderField: "authorization")
        // Never let URLSession transparently decompress object bytes.
        urlRequest.setValue("identity", forHTTPHeaderField: "accept-encoding")
        return urlRequest
    }

    private func idleTimeout(for timing: S3Request.Timing) -> TimeInterval {
        if case .quick = timing { config.timeouts.connect } else { config.timeouts.stall }
    }

    private func deadline(for timing: S3Request.Timing) -> TimeInterval? {
        switch timing {
        case .quick: config.timeouts.request
        case let .transfer(bytes?): config.timeouts.request + Double(bytes) / config.timeouts.minThroughput
        case .transfer(nil), .serverWork: nil
        }
    }
}

func withDeadline<T: Sendable>(_ seconds: TimeInterval?, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    guard let seconds else { return try await operation() }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw S3Error.network(.timeout)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
