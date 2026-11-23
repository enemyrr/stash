import Foundation

public struct S3Object: Sendable, Equatable {
    public var key: String
    public var size: Int64
    public var etag: String
    public var lastModified: Date
}

public struct ListResult: Sendable, Equatable {
    public var objects: [S3Object]
    public var commonPrefixes: [String]
    public var nextContinuationToken: String?
}

public struct ObjectInfo: Sendable, Equatable {
    /// Full object size, also for ranged reads.
    public var size: Int64
    /// Without surrounding quotes. Multipart uploads end in `-<parts>`.
    public var etag: String
    public var lastModified: Date?
    public var contentType: String?
    /// `x-amz-meta-*` headers, lowercased names without the prefix.
    public var metadata: [String: String]
}

public enum Precondition: Sendable, Equatable {
    case ifMatch(String)
    /// `.ifNoneMatch("*")` creates the object only if the key is free.
    case ifNoneMatch(String)

    /// ETags go out unquoted: Hetzner (Ceph) compares conditional PUT headers byte for byte against the
    /// unquoted ETag, so the RFC-quoted form never matches. Reads accept both.
    var headers: [String: String] {
        switch self {
        case let .ifMatch(etag): ["if-match": ETag.strip(etag)]
        case let .ifNoneMatch(etag): ["if-none-match": ETag.strip(etag)]
        }
    }
}

public struct DeleteFailure: Sendable, Equatable {
    public var key: String
    public var code: String
    public var message: String
}

enum ETag {
    static func strip(_ etag: String) -> String {
        etag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    static func quote(_ etag: String) -> String {
        "\"\(strip(etag))\""
    }
}

enum S3Date {
    static func iso8601(_ string: String) -> Date? {
        (try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(string, strategy: .iso8601))
    }

    static func http(_ string: String) -> Date? {
        httpFormatter.date(from: string)
    }

    private static let httpFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
