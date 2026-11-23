import Foundation

extension S3Client {
    func putMultipart(_ key: String, file: FileReader, headers: [String: String], condition: Precondition?) async throws -> String {
        let parts = Self.partRanges(size: file.size, partSize: config.multipart.partSize)
        return try await multipartUpload(key, headers: headers, condition: condition, partCount: parts.count) { uploadId, number in
            let data = try file.read(parts[number - 1])
            let response = try await self.execute(S3Request(
                method: "PUT", key: key, query: ["partNumber": "\(number)", "uploadId": uploadId],
                body: .data(data), timing: .transfer(bytes: Int64(data.count))
            ))
            guard let etag = response.headers["etag"] else { throw S3Error.invalidResponse("UploadPart returned no ETag") }
            return ETag.strip(etag)
        }
    }

    func copyMultipart(from source: String, to destination: String, source info: ObjectInfo, condition: Precondition?) async throws -> String {
        let parts = Self.partRanges(size: info.size, partSize: config.multipart.copyPartSize)
        let headers = objectHeaders(info.contentType, info.metadata, nil)
        return try await multipartUpload(destination, headers: headers, condition: condition, partCount: parts.count) { uploadId, number in
            let range = parts[number - 1]
            let response = try await self.execute(S3Request(
                method: "PUT", key: destination, query: ["partNumber": "\(number)", "uploadId": uploadId],
                headers: [
                    "x-amz-copy-source": self.copySource(source),
                    "x-amz-copy-source-range": "bytes=\(range.lowerBound)-\(range.upperBound)",
                    "x-amz-copy-source-if-match": info.etag,
                ],
                timing: .serverWork
            ))
            guard let etag = try XMLNode.parse(response.body).value("ETag") else {
                throw S3Error.invalidResponse("UploadPartCopy returned no ETag")
            }
            return ETag.strip(etag)
        }
    }

    private func multipartUpload(
        _ key: String, headers: [String: String], condition: Precondition?, partCount: Int,
        uploadPart: @escaping @Sendable (_ uploadId: String, _ partNumber: Int) async throws -> String
    ) async throws -> String {
        let created = try await execute(S3Request(method: "POST", key: key, query: ["uploads": ""], headers: headers))
        guard let uploadId = try XMLNode.parse(created.body).value("UploadId") else {
            throw S3Error.invalidResponse("CreateMultipartUpload returned no UploadId")
        }
        do {
            let etags = try await parallelMap(partCount, limit: config.multipart.concurrency) { try await uploadPart(uploadId, $0 + 1) }
            let parts = etags.enumerated().map { index, etag in
                "<Part><PartNumber>\(index + 1)</PartNumber><ETag>\(XMLNode.escape(ETag.quote(etag)))</ETag></Part>"
            }
            var completeHeaders = condition?.headers ?? [:]
            completeHeaders["content-type"] = "application/xml"
            let response = try await execute(S3Request(
                method: "POST", key: key, query: ["uploadId": uploadId], headers: completeHeaders,
                body: .data(Data("<CompleteMultipartUpload>\(parts.joined())</CompleteMultipartUpload>".utf8)),
                timing: .serverWork
            ))
            return ETag.strip(try XMLNode.parse(response.body).value("ETag") ?? "")
        } catch {
            await abortMultipartUpload(key, uploadId: uploadId)
            throw error
        }
    }

    /// Runs in an unstructured task so it still goes out when the caller was cancelled.
    private func abortMultipartUpload(_ key: String, uploadId: String) async {
        let request = S3Request(method: "DELETE", key: key, query: ["uploadId": uploadId])
        await Task { _ = try? await self.execute(request) }.value
    }

    /// Grows the part size if needed to stay within S3's 10 000-part limit.
    static func partRanges(size: Int64, partSize: Int64) -> [ClosedRange<Int64>] {
        let partSize = max(partSize, (size + 9_999) / 10_000)
        return stride(from: 0, to: size, by: Int(partSize)).map { $0...(min($0 + partSize, size) - 1) }
    }
}

/// One open descriptor for the whole upload, so an atomic save mid-upload cannot mix two file versions.
final class FileReader: Sendable {
    let url: URL
    let size: Int64
    private let descriptor: Int32

    init(_ url: URL) throws {
        descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSURLErrorKey: url]) }
        var info = stat()
        fstat(descriptor, &info)
        self.url = url
        size = Int64(info.st_size)
    }

    deinit {
        close(descriptor)
    }

    /// `pread` keeps concurrent part reads independent of a shared file offset.
    func read(_ range: ClosedRange<Int64>) throws -> Data {
        var data = Data(count: range.count)
        let count = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, range.count, off_t(range.lowerBound)) }
        guard count == range.count else { throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url]) }
        return data
    }
}

func parallelMap<T: Sendable>(
    _ count: Int, limit: Int, _ transform: @escaping @Sendable (Int) async throws -> T
) async throws -> [T] {
    try await withThrowingTaskGroup(of: (Int, T).self) { group in
        var results = [T?](repeating: nil, count: count)
        var next = 0
        func addNext() {
            let index = next
            group.addTask { (index, try await transform(index)) }
            next += 1
        }
        while next < min(max(limit, 1), count) { addNext() }
        for try await (index, value) in group {
            results[index] = value
            if next < count { addNext() }
        }
        return results.map { $0! }
    }
}
