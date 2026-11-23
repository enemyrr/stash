import Foundation
import Testing
@testable import S3Client

struct ErrorMappingTests {
    static func body(_ code: String) -> Data {
        Data("<?xml version=\"1.0\"?><Error><Code>\(code)</Code><Message>m</Message></Error>".utf8)
    }

    @Test(arguments: [
        (404, "NoSuchKey", S3Error.notFound),
        (404, "NoSuchUpload", .http(status: 404, code: "NoSuchUpload", message: "m")),
        (404, "NoSuchBucket", .http(status: 404, code: "NoSuchBucket", message: "m")),
        (403, "SignatureDoesNotMatch", .accessDenied(code: "SignatureDoesNotMatch")),
        (412, "PreconditionFailed", .preconditionFailed),
        (409, "ConditionalRequestConflict", .conflict(code: "ConditionalRequestConflict")),
        (503, "SlowDown", .http(status: 503, code: "SlowDown", message: "m")),
        (200, "InternalError", .http(status: 200, code: "InternalError", message: "m")),
    ])
    func mapsStatusAndCode(status: Int, code: String, expected: S3Error) {
        #expect(S3Error(status: status, body: Self.body(code)) == expected)
    }

    @Test func mapsBodilessHeadResponses() {
        #expect(S3Error(status: 404, body: Data()) == .notFound)
        #expect(S3Error(status: 403, body: Data()) == .accessDenied(code: nil))
        #expect(S3Error(status: 304, body: Data()) == .preconditionFailed)
    }

    @Test func retriesOnlyServerAndThrottlingErrors() {
        #expect(S3Error.http(status: 503, code: nil, message: nil).isTransientServerError)
        #expect(S3Error.http(status: 429, code: nil, message: nil).isTransientServerError)
        #expect(S3Error.http(status: 400, code: "RequestTimeout", message: nil).isTransientServerError)
        #expect(S3Error.http(status: 200, code: "InternalError", message: nil).isTransientServerError)
        #expect(!S3Error.http(status: 400, code: "InvalidArgument", message: nil).isTransientServerError)
        #expect(!S3Error.network(.timeout).isTransientServerError)
        #expect(!S3Error.notFound.isRetryable)
        #expect(S3Error.network(.offline).isRetryable)
        #expect(S3Error.conflict(code: nil).isRetryable)
    }

    @Test(arguments: [
        (URLError.Code.notConnectedToInternet, S3Error.NetworkReason.offline),
        (.cannotFindHost, .dns),
        (.dnsLookupFailed, .dns),
        (.cannotConnectToHost, .unreachable),
        (.timedOut, .timeout),
        (.networkConnectionLost, .connectionLost),
        (.serverCertificateUntrusted, .tls),
        (.badServerResponse, .other(URLError.Code.badServerResponse.rawValue)),
    ])
    func mapsURLErrors(code: URLError.Code, reason: S3Error.NetworkReason) {
        #expect(S3Error(URLError(code)) == .network(reason))
    }
}
