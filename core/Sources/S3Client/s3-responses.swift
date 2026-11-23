import Foundation

extension ListResult {
    init(xml root: XMLNode) throws {
        let urlEncoded = root.value("EncodingType") == "url"
        let decode = { (value: String) throws in urlEncoded ? try Self.urlDecode(value) : value }
        objects = try root.all("Contents").map { node in
            guard let key = node.value("Key"),
                  let size = node.value("Size").flatMap({ Int64($0) }),
                  let lastModified = node.value("LastModified").flatMap(S3Date.iso8601)
            else { throw S3Error.invalidResponse("Incomplete <Contents> entry") }
            return try S3Object(key: decode(key), size: size, etag: ETag.strip(node.value("ETag") ?? ""), lastModified: lastModified)
        }
        commonPrefixes = try root.all("CommonPrefixes").compactMap { $0.value("Prefix") }.map(decode)
        guard root.value("IsTruncated") == "true" else { return }
        guard let token = root.value("NextContinuationToken"), !token.isEmpty else {
            throw S3Error.invalidResponse("Truncated listing without NextContinuationToken")
        }
        nextContinuationToken = token
    }

    /// `encoding-type=url` encodes spaces as `+` on AWS and `%20` elsewhere; a literal `+` is always `%2B`.
    static func urlDecode(_ value: String) throws -> String {
        guard let decoded = value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else {
            throw S3Error.invalidResponse("Malformed URL-encoded key in listing: \(value)")
        }
        return decoded
    }
}

extension ObjectInfo {
    init(headers: [String: String]) {
        let total = headers["content-range"]?.split(separator: "/").last.flatMap { Int64($0) }
        size = total ?? headers["content-length"].flatMap { Int64($0) } ?? 0
        etag = ETag.strip(headers["etag"] ?? "")
        lastModified = headers["last-modified"].flatMap(S3Date.http)
        contentType = headers["content-type"]
        metadata = headers.reduce(into: [:]) { result, header in
            if header.key.hasPrefix("x-amz-meta-") { result[String(header.key.dropFirst(11))] = header.value }
        }
    }
}

extension DeleteFailure {
    static func parse(_ root: XMLNode) -> [DeleteFailure] {
        root.all("Error").map {
            DeleteFailure(key: $0.value("Key") ?? "", code: $0.value("Code") ?? "", message: $0.value("Message") ?? "")
        }
    }
}
