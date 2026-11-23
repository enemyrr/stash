import Foundation
@testable import S3Client

/// Reads the integration test bucket from `STASH_TEST_S3_*` environment variables. Values are never printed.
enum TestCredentials {
    static let writablePrefix = "_stash-core-test/s3client/"
    static let s3: S3Config? = load()

    static func config(
        style: S3Config.AddressingStyle = .virtualHost, multipart: MultipartPolicy = MultipartPolicy()
    ) -> S3Config? {
        guard var config = s3 else { return nil }
        config.addressingStyle = style
        config.multipart = multipart
        return config
    }

    private static func load() -> S3Config? {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["STASH_TEST_S3_ENDPOINT"], let bucket = env["STASH_TEST_S3_BUCKET"],
              let accessKeyId = env["STASH_TEST_S3_ACCESS_KEY"], let secret = env["STASH_TEST_S3_SECRET_KEY"],
              let endpointURL = URL(string: endpoint.contains("://") ? endpoint : "https://\(endpoint)")
        else { return nil }
        let region = env["STASH_TEST_S3_REGION"] ?? "us-east-1"
        return S3Config(endpoint: endpointURL, region: region, bucket: bucket, accessKeyId: accessKeyId, secretAccessKey: secret)
    }
}
