import CryptoKit
import Foundation

struct SigV4Signer: Sendable {
    static let unsignedPayload = "UNSIGNED-PAYLOAD"
    static let emptyPayloadHash = sha256Hex(Data())

    let accessKeyId: String
    let secretAccessKey: String
    let region: String
    var service = "s3"

    /// `path` is already URI-encoded. `headers` must include `host` and `x-amz-date`; all of them are signed.
    func authorization(method: String, path: String, query: [String: String], headers: [String: String], payloadHash: String) -> String {
        let amzDate = headers["x-amz-date"] ?? ""
        let canonical = canonicalRequest(method: method, path: path, query: query, headers: headers, payloadHash: payloadHash)
        let toSign = stringToSign(canonicalRequest: canonical.request, amzDate: amzDate)
        return "AWS4-HMAC-SHA256 Credential=\(accessKeyId)/\(scope(amzDate)), SignedHeaders=\(canonical.signedHeaders), "
            + "Signature=\(signature(stringToSign: toSign, amzDate: amzDate))"
    }

    func canonicalRequest(
        method: String, path: String, query: [String: String], headers: [String: String], payloadHash: String
    ) -> (request: String, signedHeaders: String) {
        let sorted = headers
            .map { ($0.key.lowercased(), $0.value.split(separator: " ").joined(separator: " ")) }
            .sorted { $0.0 < $1.0 }
        let signedHeaders = sorted.map(\.0).joined(separator: ";")
        let canonicalHeaders = sorted.map { "\($0.0):\($0.1)\n" }.joined()
        let request = [method, path, Self.canonicalQuery(query), canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")
        return (request, signedHeaders)
    }

    func stringToSign(canonicalRequest: String, amzDate: String) -> String {
        ["AWS4-HMAC-SHA256", amzDate, scope(amzDate), Self.sha256Hex(Data(canonicalRequest.utf8))].joined(separator: "\n")
    }

    func signature(stringToSign: String, amzDate: String) -> String {
        let key = ["\(amzDate.prefix(8))", region, service, "aws4_request"]
            .reduce(SymmetricKey(data: Data("AWS4\(secretAccessKey)".utf8))) { key, part in
                SymmetricKey(data: HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key))
            }
        return Data(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)).hex
    }

    private func scope(_ amzDate: String) -> String {
        "\(amzDate.prefix(8))/\(region)/\(service)/aws4_request"
    }

    static func canonicalQuery(_ query: [String: String]) -> String {
        query
            .map { (URIEncoding.encode($0.key), URIEncoding.encode($0.value)) }
            .sorted { $0 < $1 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    static func amzDate(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(dateSeparator: .omitted, timeSeparator: .omitted, timeZone: .gmt))
    }

    static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).hex
    }
}

enum URIEncoding {
    /// RFC 3986 encoding as SigV4 requires: only `A-Za-z0-9-._~` stay literal, everything else is `%XX` of its UTF-8 bytes.
    static func encode(_ value: String, keepSlash: Bool = false) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if isUnreserved(byte) || (keepSlash && byte == UInt8(ascii: "/")) {
                result.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                result += "%" + String(byte, radix: 16, uppercase: true).leftPadded(to: 2)
            }
        }
        return result
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
            true
        default: false
        }
    }
}

extension Data {
    var hex: String { map { String($0, radix: 16).leftPadded(to: 2) }.joined() }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
