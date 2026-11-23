import CryptoKit
import Foundation
import Testing
@testable import S3Client

/// Runs against a real bucket set in `STASH_TEST_S3_*`. Writes only under `TestCredentials.writablePrefix`.
@Suite(.enabled(if: TestCredentials.s3 != nil, "STASH_TEST_S3_* is not set"))
struct IntegrationTests {
    static func withScratch(
        style: S3Config.AddressingStyle = .virtualHost, multipart: MultipartPolicy = MultipartPolicy(),
        _ body: (S3Client, String) async throws -> Void
    ) async throws {
        let client = S3Client(config: try #require(TestCredentials.config(style: style, multipart: multipart)))
        let prefix = "\(TestCredentials.writablePrefix)\(UUID().uuidString)/"
        do {
            try await body(client, prefix)
        } catch {
            try? await cleanUp(client, prefix)
            throw error
        }
        try await cleanUp(client, prefix)
    }

    static func cleanUp(_ client: S3Client, _ prefix: String) async throws {
        precondition(prefix.hasPrefix(TestCredentials.writablePrefix) && prefix.count > TestCredentials.writablePrefix.count)
        let keys = try await client.listAll(prefix: prefix).objects.map(\.key)
        precondition(keys.allSatisfy { $0.hasPrefix(prefix) })
        #expect(try await client.deleteObjects(keys).isEmpty)
        #expect(try await client.listAll(prefix: prefix).objects.isEmpty)
    }

    @Test(arguments: [S3Config.AddressingStyle.virtualHost, .path])
    func pagesListingsAndReadsRanges(style: S3Config.AddressingStyle) async throws {
        try await Self.withScratch(style: style) { client, prefix in
            for name in ["a.bin", "b.bin"] { try await client.put("\(prefix)\(name)", data: Data(repeating: 7, count: 5000)) }
            let first = try await client.listObjectsV2(prefix: prefix, maxKeys: 1)
            let token = try #require(first.nextContinuationToken)
            let second = try await client.listObjectsV2(prefix: prefix, continuationToken: token, maxKeys: 1)
            let object = try #require(first.objects.first)
            #expect(second.objects.first.map { $0.key > object.key } == true)

            let info = try await client.head(object.key)
            #expect(info.size == object.size)
            #expect(info.etag == object.etag)
            #expect(try await client.get(object.key, range: 0...4095, ifMatch: object.etag).count == 4096)
        }
    }

    @Test func mapsErrorsFromTheServer() async throws {
        let config = try #require(TestCredentials.config(style: .path))
        let client = S3Client(config: config)
        await #expect(throws: S3Error.notFound) { try await client.head("\(TestCredentials.writablePrefix)missing-\(UUID())") }
        await #expect(throws: S3Error.notFound) { try await client.get("\(TestCredentials.writablePrefix)missing-\(UUID())") }

        var wrongSecret = config
        wrongSecret.secretAccessKey = "not-the-secret"
        await #expect(throws: S3Error.accessDenied(code: "SignatureDoesNotMatch")) {
            try await S3Client(config: wrongSecret).listObjectsV2(maxKeys: 1)
        }

        var missingBucket = config
        missingBucket.bucket = "stash-core-missing-\(UUID().uuidString.lowercased().prefix(8))"
        do {
            _ = try await S3Client(config: missingBucket).listObjectsV2(maxKeys: 1)
            Issue.record("Expected NoSuchBucket")
        } catch let S3Error.http(status, code, _) {
            #expect(status == 404 && code == "NoSuchBucket")
        }
    }

    @Test func roundTripsAnAwkwardKey() async throws {
        try await Self.withScratch { client, prefix in
            let key = "\(prefix)dir with space/åäö ✓ e\u{0301} +plus&amp=eq?q#h~.txt"
            let data = Data("hello stash, with a few more bytes".utf8)
            let etag = try await client.put(key, data: data, contentType: "text/plain", metadata: ["Mtime": "1700000000.5"])
            #expect(etag == Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined())

            let info = try await client.head(key)
            #expect(info.size == Int64(data.count))
            #expect(info.etag == etag)
            #expect(info.contentType == "text/plain")
            #expect(info.metadata["mtime"] == "1700000000.5")

            #expect(try await client.get(key) == data)
            #expect(try await client.get(key, range: 6...10) == data[6...10])
            await #expect(throws: S3Error.preconditionFailed) { try await client.get(key, ifMatch: "0123456789abcdef") }

            let file = FileManager.default.temporaryDirectory.appending(path: "s3client-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: file) }
            let downloaded = try await client.get(key, to: file)
            #expect(try Data(contentsOf: file) == data)
            #expect(downloaded.etag == etag)

            let listing = try await client.listAll(prefix: prefix)
            #expect(listing.objects.map(\.key) == [key])
            #expect(try await client.listAll(prefix: prefix, delimiter: "/").commonPrefixes == ["\(prefix)dir with space/"])

            let copyKey = "\(prefix)copy/ö.txt"
            #expect(try await client.copy(from: key, to: copyKey) == etag)
            #expect(try await client.get(copyKey) == data)

            try await client.delete(key)
            await #expect(throws: S3Error.notFound) { try await client.head(key) }
            try await client.delete(key)
        }
    }

    @Test func uploadsAndCopiesMultipart() async throws {
        let policy = MultipartPolicy(copyThreshold: 32 << 20, copyPartSize: 32 << 20)
        try await Self.withScratch(multipart: policy) { client, prefix in
            let size = 70 << 20
            var data = Data(count: size)
            data.withUnsafeMutableBytes { buffer in
                for (index, word) in buffer.bindMemory(to: UInt32.self).indices.enumerated() {
                    buffer.storeBytes(of: UInt32(truncatingIfNeeded: index &* 2_654_435_761), toByteOffset: word * 4, as: UInt32.self)
                }
            }
            let file = FileManager.default.temporaryDirectory.appending(path: "s3client-\(UUID().uuidString)")
            try data.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }

            let key = "\(prefix)big file.bin"
            let etag = try await client.put(key, fileURL: file)
            #expect(etag.hasSuffix("-5"))
            #expect(try await client.head(key).size == Int64(size))

            let boundary: Int64 = 16 << 20
            #expect(try await client.get(key, range: (boundary - 8)...(boundary + 8)) == data[Int(boundary - 8)...Int(boundary + 8)])

            let downloadedFile = FileManager.default.temporaryDirectory.appending(path: "s3client-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: downloadedFile) }
            let info = try await client.get(key, to: downloadedFile)
            #expect(info.etag == etag)
            #expect(try SHA256.hash(data: Data(contentsOf: downloadedFile)) == SHA256.hash(data: data))

            let copyKey = "\(prefix)copy/big file.bin"
            #expect(try await client.copy(from: key, to: copyKey, sourceIfMatch: etag).hasSuffix("-3"))
            let copyBoundary: Int64 = 32 << 20
            #expect(try await client.get(copyKey, range: (copyBoundary - 4)...(copyBoundary + 4))
                == data[Int(copyBoundary - 4)...Int(copyBoundary + 4)])
            #expect(try await client.head(copyKey).size == Int64(size))
            await #expect(throws: S3Error.preconditionFailed) {
                try await client.copy(from: key, to: copyKey, sourceIfMatch: "0123456789abcdef")
            }
        }
    }

    @Test func deletesInBatches() async throws {
        try await Self.withScratch { client, prefix in
            let keys = (0..<5).map { "\(prefix)batch/\($0) ü.txt" }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for key in keys { group.addTask { try await client.put(key, data: Data(key.utf8)) } }
                try await group.waitForAll()
            }
            #expect(try await client.listAll(prefix: prefix).objects.count == 5)
            #expect(try await client.deleteObjects(keys + ["\(prefix)never-existed"]).isEmpty)
            #expect(try await client.listAll(prefix: prefix).objects.isEmpty)
        }
    }

    /// Pins down which conditional writes the provider honours. The sync engine depends on the answer.
    @Test func honoursConditionalWrites() async throws {
        let small = MultipartPolicy(threshold: 6 << 20, partSize: 5 << 20)
        try await Self.withScratch(multipart: small) { client, prefix in
            let key = "\(prefix)conditional.txt"
            let etag = try await client.put(key, data: Data("v1".utf8))

            var outcomes: [(String, String)] = []
            func probe(_ name: String, _ operation: () async throws -> Void) async {
                do {
                    try await operation()
                    outcomes.append((name, "succeeded"))
                } catch {
                    outcomes.append((name, "\(error)"))
                }
            }
            await probe("PUT If-None-Match:* on existing key") { try await client.put(key, data: Data("v2".utf8), condition: .ifNoneMatch("*")) }
            await probe("PUT If-Match:<wrong etag>") { try await client.put(key, data: Data("v3".utf8), condition: .ifMatch("0123456789abcdef")) }
            await probe("PUT If-Match:<current etag>") { try await client.put(key, data: Data("v4".utf8), condition: .ifMatch(etag)) }
            await probe("PUT If-None-Match:* on free key") { try await client.put("\(prefix)fresh.txt", data: Data("x".utf8), condition: .ifNoneMatch("*")) }

            let file = FileManager.default.temporaryDirectory.appending(path: "s3client-\(UUID().uuidString)")
            try Data(repeating: 1, count: 11 << 20).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            await probe("CompleteMultipartUpload If-None-Match:* on existing key") {
                try await client.put(key, fileURL: file, condition: .ifNoneMatch("*"))
            }
            await probe("CopyObject If-None-Match:* onto existing key") {
                try await client.copy(from: "\(prefix)fresh.txt", to: key, condition: .ifNoneMatch("*"))
            }
            let result = Dictionary(uniqueKeysWithValues: outcomes)
            #expect(result["PUT If-None-Match:* on existing key"] == "preconditionFailed")
            #expect(result["PUT If-Match:<wrong etag>"] == "preconditionFailed")
            #expect(result["PUT If-Match:<current etag>"] == "succeeded")
            #expect(result["PUT If-None-Match:* on free key"] == "succeeded")
            withKnownIssue("Some providers, such as Hetzner, ignore If-None-Match on CompleteMultipartUpload and CopyObject", isIntermittent: true) {
                #expect(result["CompleteMultipartUpload If-None-Match:* on existing key"] == "preconditionFailed")
                #expect(result["CopyObject If-None-Match:* onto existing key"] == "preconditionFailed")
            }
        }
    }
}
