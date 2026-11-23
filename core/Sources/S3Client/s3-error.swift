import Foundation

public enum S3Error: Error, Sendable, Equatable {
    public enum NetworkReason: Sendable, Equatable {
        case offline
        case dns
        case unreachable
        case timeout
        case connectionLost
        case tls
        case other(Int)
    }

    /// The request may or may not have reached the server. For writes, reconcile with `head`.
    case network(NetworkReason)
    /// `NoSuchKey` or `NoSuchUpload`. A missing bucket is `.http(404, "NoSuchBucket", _)`.
    case notFound
    case accessDenied(code: String?)
    /// 412, or 304 on a conditional read.
    case preconditionFailed
    /// 409, for example `ConditionalRequestConflict` when a concurrent conditional write won.
    case conflict(code: String?)
    case http(status: Int, code: String?, message: String?)
    case invalidRequest(String)
    case invalidResponse(String)

    /// True when the same call can succeed later without changing anything.
    public var isRetryable: Bool {
        switch self {
        case .network, .conflict: true
        default: isTransientServerError
        }
    }

    var isTransientServerError: Bool {
        guard case let .http(status, code, _) = self else { return false }
        return [429, 500, 502, 503, 504].contains(status) || code.map(Self.transientCodes.contains) == true
    }

    private static let transientCodes: Set = [
        "SlowDown", "Throttling", "ThrottlingException", "RequestThrottled",
        "RequestTimeout", "InternalError", "ServiceUnavailable",
    ]
}

extension S3Error {
    init(status: Int, body: Data) {
        let error = (try? XMLNode.parse(body)).flatMap { $0.name == "Error" ? $0 : nil }
        let code = error?.value("Code")
        switch status {
        case 404 where code != "NoSuchBucket": self = .notFound
        case 403: self = .accessDenied(code: code)
        case 304, 412: self = .preconditionFailed
        case 409: self = .conflict(code: code)
        default: self = .http(status: status, code: code, message: error?.value("Message"))
        }
    }

    init(_ error: URLError) {
        let reason: NetworkReason = switch error.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive: .offline
        case .cannotFindHost, .dnsLookupFailed: .dns
        case .cannotConnectToHost: .unreachable
        case .timedOut: .timeout
        case .networkConnectionLost: .connectionLost
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired:
            .tls
        default: .other(error.code.rawValue)
        }
        self = .network(reason)
    }
}
