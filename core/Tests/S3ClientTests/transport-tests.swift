import Foundation
import Synchronization
import Testing
@testable import S3Client

/// Scripted responses per host, so tests stay independent when run in parallel.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (_ request: URLRequest, _ index: Int) -> (status: Int, body: String)
    static let handlers = Mutex<[String: Handler]>([:])
    static let requests = Mutex<[String: [String]]>([:])

    static func client(_ handler: @escaping Handler, multipart: MultipartPolicy = MultipartPolicy()) -> (S3Client, host: String) {
        let bucket = "mock-\(UUID().uuidString.lowercased())"
        handlers.withLock { $0["\(bucket).mock.test"] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let config = S3Config(
            endpoint: URL(string: "https://mock.test")!, region: "us-east-1", bucket: bucket,
            accessKeyId: "id", secretAccessKey: "secret", multipart: multipart,
            retry: RetryPolicy(maxAttempts: 3, baseDelay: 0.001)
        )
        return (S3Client(config: config, sessionConfiguration: configuration), "\(bucket).mock.test")
    }

    static func log(_ host: String) -> [String] { requests.withLock { $0[host] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return }
        let index = Self.requests.withLock { log in
            log[host, default: []].append("\(request.httpMethod ?? "") \(url.query() ?? "")")
            return log[host]!.count - 1
        }
        let (status, body) = Self.handlers.withLock { $0[host] }?(request, index) ?? (500, "")
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["ETag": "\"etag-\(index)\""])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

struct TransportTests {
    static let emptyListing = "<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>"
    static func error(_ code: String) -> String { "<Error><Code>\(code)</Code><Message>m</Message></Error>" }

    @Test func retriesThrottlingThenSucceeds() async throws {
        let (client, host) = MockURLProtocol.client { _, index in
            index < 2 ? (503, Self.error("SlowDown")) : (200, Self.emptyListing)
        }
        _ = try await client.listObjectsV2()
        #expect(MockURLProtocol.log(host).count == 3)
    }

    @Test func givesUpAfterMaxAttempts() async throws {
        let (client, host) = MockURLProtocol.client { _, _ in (500, Self.error("InternalError")) }
        await #expect(throws: S3Error.http(status: 500, code: "InternalError", message: "m")) { try await client.listObjectsV2() }
        #expect(MockURLProtocol.log(host).count == 3)
    }

    @Test func doesNotRetryClientErrors() async throws {
        let (client, host) = MockURLProtocol.client { _, _ in (403, Self.error("AccessDenied")) }
        await #expect(throws: S3Error.accessDenied(code: "AccessDenied")) { try await client.head("k") }
        #expect(MockURLProtocol.log(host).count == 1)
    }

    @Test func retriesErrorEmbeddedInSuccessfulServerWork() async throws {
        let (client, host) = MockURLProtocol.client { _, index in
            index == 0 ? (200, "  " + Self.error("InternalError")) : (200, "<DeleteResult/>")
        }
        #expect(try await client.deleteObjects(["a"]).isEmpty)
        #expect(MockURLProtocol.log(host).count == 2)
    }

    @Test func abortsMultipartUploadWhenAPartFails() async throws {
        let (client, host) = MockURLProtocol.client({ request, _ in
            switch (request.httpMethod, request.url?.query() ?? "") {
            case ("POST", "uploads="): (200, "<InitiateMultipartUploadResult><UploadId>u1</UploadId></InitiateMultipartUploadResult>")
            case ("PUT", let query) where query.hasPrefix("partNumber=2"): (403, Self.error("AccessDenied"))
            case ("PUT", _): (200, "")
            case ("DELETE", _): (204, "")
            default: (400, Self.error("Unexpected"))
            }
        }, multipart: MultipartPolicy(threshold: 10, partSize: 8, concurrency: 2))
        let file = FileManager.default.temporaryDirectory.appending(path: "s3client-\(UUID().uuidString)")
        try Data(repeating: 7, count: 30).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        await #expect(throws: S3Error.accessDenied(code: "AccessDenied")) { try await client.put("big", fileURL: file) }
        let log = MockURLProtocol.log(host)
        #expect(log.contains("DELETE uploadId=u1"))
        #expect(!log.contains { $0.hasPrefix("POST uploadId=") })
    }

    @Test func listAllFollowsContinuationTokens() async throws {
        let (client, _) = MockURLProtocol.client { request, _ in
            let first = !(request.url?.query()?.contains("continuation-token") ?? false)
            let key = first ? "a" : "b"
            let more = first ? "<IsTruncated>true</IsTruncated><NextContinuationToken>t/1</NextContinuationToken>" : "<IsTruncated>false</IsTruncated>"
            return (200, "<ListBucketResult>\(more)<Contents><Key>\(key)</Key><LastModified>2024-01-01T00:00:00Z</LastModified><ETag>\"e\"</ETag><Size>1</Size></Contents></ListBucketResult>")
        }
        #expect(try await client.listAll().objects.map(\.key) == ["a", "b"])
    }

    @Test func doesNotReplayConditionalWrites() async throws {
        let (client, host) = MockURLProtocol.client { _, _ in (503, Self.error("SlowDown")) }
        await #expect(throws: S3Error.http(status: 503, code: "SlowDown", message: "m")) {
            try await client.put("k", data: Data("x".utf8), condition: .ifNoneMatch("*"))
        }
        #expect(MockURLProtocol.log(host).count == 1)
    }

    @Test func keepsExistingFileWhenDownloadIsInvalid() async throws {
        let (client, _) = MockURLProtocol.client { _, index in
            index == 0 ? (200, "whole object, range ignored") : (404, Self.error("NoSuchKey"))
        }
        let file = FileManager.default.temporaryDirectory.appending(path: "s3client-\(UUID().uuidString)")
        try Data("previous".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        await #expect(throws: S3Error.invalidResponse("Server ignored or changed the requested range")) {
            try await client.get("k", range: 0...3, to: file)
        }
        await #expect(throws: S3Error.notFound) { try await client.get("k", to: file) }
        #expect(try Data(contentsOf: file) == Data("previous".utf8))
    }
}

/// Real sockets, no credentials needed.
struct OfflineTests {
    static func client(_ endpoint: String) -> S3Client {
        S3Client(config: S3Config(
            endpoint: URL(string: endpoint)!, region: "us-east-1", bucket: "b", accessKeyId: "id",
            secretAccessKey: "secret", addressingStyle: .path
        ))
    }

    @Test(.timeLimit(.minutes(1)))
    func unroutableEndpointFailsFastWithNetworkError() async {
        let started = ContinuousClock.now
        do {
            _ = try await Self.client("http://10.255.255.1").listObjectsV2()
            Issue.record("Expected a network error")
        } catch let error as S3Error {
            guard case .network = error else {
                Issue.record("Expected .network, got \(error)")
                return
            }
            #expect(error.isRetryable)
        } catch {
            Issue.record("Expected S3Error, got \(error)")
        }
        #expect(ContinuousClock.now - started < .seconds(12))
    }

    /// The kernel completes the TCP handshake for a listening socket that never accepts, so the server just goes silent.
    @Test(.timeLimit(.minutes(1)))
    func silentServerHitsIdleTimeout() async throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                  sin_port: 0, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try #require(bind(fd, $0, length) == 0 && listen(fd, 8) == 0 && getsockname(fd, $0, &length) == 0)
            }
        }
        let client = S3Client(config: S3Config(
            endpoint: URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))")!, region: "us-east-1", bucket: "b",
            accessKeyId: "id", secretAccessKey: "secret", addressingStyle: .path, timeouts: Timeouts(connect: 1)
        ))
        let started = ContinuousClock.now
        await #expect(throws: S3Error.network(.timeout)) { try await client.head("k") }
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test(.timeLimit(.minutes(1)))
    func unknownHostFailsWithDNSError() async {
        await #expect(throws: S3Error.network(.dns)) {
            _ = try await Self.client("https://stash-core-test.invalid").listObjectsV2()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationStopsAHangingRequest() async {
        let started = ContinuousClock.now
        let task = Task { try await Self.client("http://10.255.255.1").listObjectsV2() }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(3))
    }
}
