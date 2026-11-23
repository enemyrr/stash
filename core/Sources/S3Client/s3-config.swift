import Foundation

public struct S3Config: Sendable {
    public enum AddressingStyle: Sendable {
        /// `https://bucket.endpoint/key`
        case virtualHost
        /// `https://endpoint/bucket/key`
        case path
    }

    public var endpoint: URL
    public var region: String
    public var bucket: String
    public var accessKeyId: String
    public var secretAccessKey: String
    public var addressingStyle: AddressingStyle
    public var timeouts: Timeouts
    public var multipart: MultipartPolicy
    public var retry: RetryPolicy

    public init(
        endpoint: URL,
        region: String,
        bucket: String,
        accessKeyId: String,
        secretAccessKey: String,
        addressingStyle: AddressingStyle = .virtualHost,
        timeouts: Timeouts = Timeouts(),
        multipart: MultipartPolicy = MultipartPolicy(),
        retry: RetryPolicy = RetryPolicy()
    ) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.addressingStyle = addressingStyle
        self.timeouts = timeouts
        self.multipart = multipart
        self.retry = retry
    }
}

extension S3Config: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "S3Config(endpoint: \(endpoint), region: \(region), bucket: \(bucket), accessKeyId: \(accessKeyId), secretAccessKey: <redacted>)"
    }

    public var debugDescription: String { description }
}

public struct Timeouts: Sendable {
    /// Idle limit for small requests (list, head, delete). An unreachable host fails after this.
    public var connect: TimeInterval
    /// Whole-call limit for small requests.
    public var request: TimeInterval
    /// Idle limit for transfers and server-side work (copy, complete multipart, batch delete).
    /// Hetzner was seen silent for 35 s acknowledging a 16 MiB part and 57 s on an UploadPartCopy.
    public var stall: TimeInterval
    /// Slowest tolerated throughput in bytes per second. Transfer deadlines are `request + bytes / minThroughput`.
    public var minThroughput: Double

    public init(connect: TimeInterval = 10, request: TimeInterval = 30, stall: TimeInterval = 90, minThroughput: Double = 256 * 1024) {
        self.connect = connect
        self.request = request
        self.stall = stall
        self.minThroughput = minThroughput
    }
}

public struct MultipartPolicy: Sendable {
    public var threshold: Int64
    public var partSize: Int64
    public var concurrency: Int
    /// Objects larger than this are copied with UploadPartCopy. S3 caps CopyObject at 5 GiB.
    public var copyThreshold: Int64
    public var copyPartSize: Int64

    public init(
        threshold: Int64 = 64 << 20,
        partSize: Int64 = 16 << 20,
        concurrency: Int = 4,
        copyThreshold: Int64 = 5 << 30,
        copyPartSize: Int64 = 512 << 20
    ) {
        self.threshold = threshold
        self.partSize = partSize
        self.concurrency = concurrency
        self.copyThreshold = copyThreshold
        self.copyPartSize = copyPartSize
    }
}

public struct RetryPolicy: Sendable {
    /// Total attempts for 5xx and throttling responses. Network errors are never retried here.
    public var maxAttempts: Int
    public var baseDelay: TimeInterval

    public init(maxAttempts: Int = 3, baseDelay: TimeInterval = 0.25) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
    }
}
