import Foundation
import Synchronization
@testable import S3Client

/// An in-memory bucket behind `URLProtocol`, one per host, with the S3 subset the sync engine uses.
final class FakeS3: URLProtocol, @unchecked Sendable {
	struct Object {
		var data: Data
		var etag: String
		var metadata: [String: String]
		var lastModified: Date
	}

	struct Bucket {
		var objects: [String: Object] = [:]
		var version = 0
		/// Copies from these source keys answer 404 NoSuchKey.
		var failingCopySources: Set<String> = []
	}

	static let buckets = Mutex<[String: Bucket]>([:])

	let host: String

	static func client() -> (S3Client, FakeBucket) {
		let name = "fake-\(UUID().uuidString.lowercased())"
		let host = "\(name).fake.test"
		buckets.withLock { $0[host] = Bucket() }
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [FakeS3.self]
		let config = S3Config(
			endpoint: URL(string: "https://fake.test")!, region: "us-east-1", bucket: name,
			accessKeyId: "id", secretAccessKey: "secret", retry: RetryPolicy(maxAttempts: 1, baseDelay: 0.001))
		return (S3Client(config: config, sessionConfiguration: configuration), FakeBucket(host: host))
	}

	override init(request: URLRequest, cachedResponse: CachedURLResponse?, client: (any URLProtocolClient)?) {
		host = request.url?.host() ?? ""
		super.init(request: request, cachedResponse: cachedResponse, client: client)
	}

	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
	override func stopLoading() {}

	override func startLoading() {
		let (status, headers, body) = Self.buckets.withLock { buckets in
			handle(&buckets[host, default: Bucket()])
		}
		let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: body)
		client?.urlProtocolDidFinishLoading(self)
	}

	private func handle(_ bucket: inout Bucket) -> (Int, [String: String], Data) {
		let url = request.url!
		let key = String(url.path(percentEncoded: false).dropFirst())
		let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
		func param(_ name: String) -> String? { query.first { $0.name == name }?.value }
		func header(_ name: String) -> String? { request.value(forHTTPHeaderField: name) }
		func error(_ status: Int, _ code: String) -> (Int, [String: String], Data) {
			(status, [:], Data("<Error><Code>\(code)</Code><Message>m</Message></Error>".utf8))
		}
		func preconditionFails(_ existing: Object?) -> Bool {
			if let match = header("if-match"), existing?.etag != match { return true }
			if header("if-none-match") == "*", existing != nil { return true }
			return false
		}
		func newVersion(_ data: Data, _ metadata: [String: String]) -> Object {
			bucket.version += 1
			return Object(data: data, etag: "v\(bucket.version)", metadata: metadata, lastModified: Date())
		}
		let metadata = (request.allHTTPHeaderFields ?? [:]).reduce(into: [String: String]()) { result, field in
			let name = field.key.lowercased()
			if name.hasPrefix("x-amz-meta-") { result[String(name.dropFirst(11))] = field.value }
		}

		switch request.httpMethod ?? "GET" {
		case "GET" where param("list-type") == "2":
			let prefix = param("prefix") ?? ""
			var contents = "", prefixes = Set<String>()
			for (objectKey, object) in bucket.objects.sorted(by: { $0.key < $1.key }) where objectKey.hasPrefix(prefix) {
				let rest = objectKey.dropFirst(prefix.count)
				if param("delimiter") == "/", let slash = rest.firstIndex(of: "/") {
					prefixes.insert(prefix + rest[...slash])
					continue
				}
				contents += """
					<Contents><Key>\(objectKey)</Key><Size>\(object.data.count)</Size><ETag>"\(object.etag)"</ETag>\
					<LastModified>\(object.lastModified.ISO8601Format())</LastModified></Contents>
					"""
			}
			let common = prefixes.sorted().map { "<CommonPrefixes><Prefix>\($0)</Prefix></CommonPrefixes>" }.joined()
			return (200, [:], Data("<ListBucketResult><IsTruncated>false</IsTruncated>\(contents)\(common)</ListBucketResult>".utf8))
		case "HEAD":
			guard let object = bucket.objects[key] else { return (404, [:], Data()) }
			if let match = header("if-match"), match != object.etag { return (412, [:], Data()) }
			var headers = ["ETag": "\"\(object.etag)\"", "Content-Length": "\(object.data.count)"]
			for (name, value) in object.metadata { headers["x-amz-meta-\(name)"] = value }
			return (200, headers, Data())
		case "PUT" where header("x-amz-copy-source") != nil:
			let source = String(header("x-amz-copy-source")!.removingPercentEncoding!.drop { $0 != "/" }.dropFirst().drop { $0 != "/" }.dropFirst())
			if bucket.failingCopySources.contains(source) { return error(404, "NoSuchKey") }
			guard let object = bucket.objects[source] else { return error(404, "NoSuchKey") }
			if let match = header("x-amz-copy-source-if-match"), match != object.etag { return error(412, "PreconditionFailed") }
			if preconditionFails(bucket.objects[key]) { return error(412, "PreconditionFailed") }
			let copy = newVersion(object.data, header("x-amz-metadata-directive") == "REPLACE" ? metadata : object.metadata)
			bucket.objects[key] = copy
			return (200, [:], Data("<CopyObjectResult><ETag>\"\(copy.etag)\"</ETag></CopyObjectResult>".utf8))
		case "PUT":
			if preconditionFails(bucket.objects[key]) { return error(412, "PreconditionFailed") }
			let object = newVersion(requestBody(), metadata)
			bucket.objects[key] = object
			return (200, ["ETag": "\"\(object.etag)\""], Data())
		case "DELETE":
			bucket.objects[key] = nil
			return (204, [:], Data())
		case "POST" where param("delete") != nil:
			let body = String(decoding: requestBody(), as: UTF8.self)
			for part in body.components(separatedBy: "<Key>").dropFirst() {
				bucket.objects[part.components(separatedBy: "</Key>")[0]] = nil
			}
			return (200, [:], Data("<DeleteResult/>".utf8))
		default:
			return error(501, "NotImplemented")
		}
	}

	private func requestBody() -> Data {
		if let body = request.httpBody { return body }
		guard let stream = request.httpBodyStream else { return Data() }
		stream.open()
		defer { stream.close() }
		var data = Data()
		var buffer = [UInt8](repeating: 0, count: 64 << 10)
		while true {
			let count = stream.read(&buffer, maxLength: buffer.count)
			if count <= 0 { break }
			data.append(buffer, count: count)
		}
		return data
	}
}

/// Test access to one fake bucket.
struct FakeBucket: Sendable {
	let host: String

	func put(_ key: String, _ content: String = "", metadata: [String: String] = [:]) {
		FakeS3.buckets.withLock { buckets in
			buckets[host]!.version += 1
			buckets[host]!.objects[key] = FakeS3.Object(
				data: Data(content.utf8), etag: "v\(buckets[host]!.version)", metadata: metadata, lastModified: Date())
		}
	}

	func object(_ key: String) -> FakeS3.Object? {
		FakeS3.buckets.withLock { $0[host]?.objects[key] }
	}

	var keys: [String] {
		FakeS3.buckets.withLock { $0[host]?.objects.keys.sorted() ?? [] }
	}

	func failCopies(from key: String) {
		FakeS3.buckets.withLock { _ = $0[host]!.failingCopySources.insert(key) }
	}
}
