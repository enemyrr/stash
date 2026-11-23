import Foundation

/// File content format: "RCLONE\0\0" + 24-byte nonce, then 64 KiB plaintext blocks, each
/// sealed with secretbox (16-byte tag + data) under the nonce incremented once per block.
extension RcloneCipher {
    public static let headerSize = 32
    public static let blockDataSize = 64 * 1024
    public static let blockOverhead = SecretBox.overhead
    public static let blockSize = blockDataSize + blockOverhead
    static let magic = Array("RCLONE\0\0".utf8)

    // MARK: Sizes

    public static func encryptedSize(plainSize: Int64) -> Int64 {
        let blocks = plainSize / Int64(blockDataSize), residue = plainSize % Int64(blockDataSize)
        return Int64(headerSize) + blocks * Int64(blockSize) + (residue == 0 ? 0 : Int64(blockOverhead) + residue)
    }

    public static func plainSize(encryptedSize: Int64) throws(RcloneCryptError) -> Int64 {
        let size = encryptedSize - Int64(headerSize)
        guard size >= 0 else { throw .fileTooShort }
        let blocks = size / Int64(blockSize), residue = size % Int64(blockSize)
        guard residue == 0 || residue > Int64(blockOverhead) else { throw .truncatedBlock }
        return blocks * Int64(blockDataSize) + (residue == 0 ? 0 : residue - Int64(blockOverhead))
    }

    // MARK: Whole buffers

    public func encrypt(_ plaintext: Data) -> Data {
        var encryptor = makeEncryptor()
        return encryptor.update(plaintext) + encryptor.finish()
    }

    public func decrypt(_ encrypted: Data) throws(RcloneCryptError) -> Data {
        var decryptor = makeDecryptor()
        let head = try decryptor.update(encrypted)
        return head + (try decryptor.finish())
    }

    // MARK: Streams

    /// Starts an encryption stream with a random nonce. `nonce` is for tests only.
    public func makeEncryptor(nonce: [UInt8]? = nil) -> RcloneEncryptor {
        RcloneEncryptor(key: dataKey, nonce: nonce ?? randomBytes(24))
    }

    /// Starts a decryption stream that expects the file header first.
    public func makeDecryptor() -> RcloneDecryptor {
        RcloneDecryptor(key: dataKey, nonce: nil)
    }

    /// Encrypts `input` into `output`, streaming 1 MiB at a time.
    public func encrypt(from input: FileHandle, to output: FileHandle) throws {
        var encryptor = makeEncryptor()
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: encryptor.update(chunk))
        }
        try output.write(contentsOf: encryptor.finish())
    }

    /// Decrypts `input` into `output`, streaming 1 MiB at a time.
    public func decrypt(from input: FileHandle, to output: FileHandle) throws {
        var decryptor = makeDecryptor()
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: decryptor.update(chunk))
        }
        try output.write(contentsOf: decryptor.finish())
    }

    public func encryptFile(at source: URL, to destination: URL) throws {
        try withFiles(source, destination) { try encrypt(from: $0, to: $1) }
    }

    public func decryptFile(at source: URL, to destination: URL) throws {
        try withFiles(source, destination) { try decrypt(from: $0, to: $1) }
    }

    private func withFiles(_ source: URL, _ destination: URL, _ body: (FileHandle, FileHandle) throws -> Void) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.truncate(atOffset: 0)
        try body(input, output)
    }

    // MARK: Random access

    /// Maps a plaintext byte range to the whole encrypted blocks that hold it. Returns nil
    /// when the range is empty or starts at or past `plainSize`.
    public static func contentRange(plainOffset: Int64, length: Int64, plainSize: Int64) -> RcloneContentRange? {
        let end = min(plainOffset + length, plainSize)
        guard plainOffset >= 0, length > 0, plainOffset < end else { return nil }
        let block = Int64(blockDataSize)
        let firstBlock = plainOffset / block, lastBlock = (end - 1) / block
        let encryptedOffset = Int64(headerSize) + firstBlock * Int64(blockSize)
        let encryptedEnd = min(Int64(headerSize) + (lastBlock + 1) * Int64(blockSize), encryptedSize(plainSize: plainSize))
        return RcloneContentRange(
            plainOffset: plainOffset, plainLength: end - plainOffset, firstBlock: firstBlock,
            encryptedOffset: encryptedOffset, encryptedLength: encryptedEnd - encryptedOffset)
    }

    /// Decrypts the bytes of `range` from `blocks`, the encrypted bytes at
    /// `range.encryptedOffset..<range.encryptedOffset + range.encryptedLength`.
    /// `header` is the file's first 32 bytes (fetch once per file and cache).
    public func decrypt(range: RcloneContentRange, header: Data, blocks: Data) throws(RcloneCryptError) -> Data {
        let nonce = try RcloneDecryptor.parseHeader(Array(header))
        var decryptor = RcloneDecryptor(key: dataKey, nonce: RcloneNonce.adding(range.firstBlock, to: nonce))
        guard blocks.count == range.encryptedLength else { throw .truncatedBlock }
        let plain = try decryptor.update(blocks) + decryptor.finish()
        let start = Int(range.plainOffset - range.firstBlock * Int64(Self.blockDataSize))
        guard plain.count >= start + Int(range.plainLength) else { throw .truncatedBlock }
        return plain.subdata(in: start..<start + Int(range.plainLength))
    }
}

/// Encrypted byte range to fetch (e.g. an S3 `Range: bytes=` GET) for a plaintext range.
public struct RcloneContentRange: Sendable, Equatable {
    public let plainOffset: Int64
    public let plainLength: Int64
    public let firstBlock: Int64
    public let encryptedOffset: Int64
    public let encryptedLength: Int64

    /// HTTP Range header value, e.g. "bytes=32-65583".
    public var httpRange: String { "bytes=\(encryptedOffset)-\(encryptedOffset + encryptedLength - 1)" }
}

/// Push-based encryption: feed plaintext chunks of any size, collect ciphertext.
/// The first output starts with the file header.
public struct RcloneEncryptor: Sendable {
    private let key: [UInt8]
    private var nonce: [UInt8]
    private var pending: [UInt8] = []
    private var header: [UInt8]?

    init(key: [UInt8], nonce: [UInt8]) {
        precondition(nonce.count == 24)
        self.key = key
        self.nonce = nonce
        header = RcloneCipher.magic + nonce
    }

    public mutating func update(_ plaintext: Data) -> Data {
        var out = takeHeader()
        pending += plaintext
        var offset = 0
        while pending.count - offset >= RcloneCipher.blockDataSize {
            out += seal(pending[offset..<offset + RcloneCipher.blockDataSize])
            offset += RcloneCipher.blockDataSize
        }
        pending.removeFirst(offset)
        return Data(out)
    }

    /// Seals the last partial block. An empty file is just the header.
    public mutating func finish() -> Data {
        var out = takeHeader()
        if !pending.isEmpty { out += seal(pending[...]) }
        pending = []
        return Data(out)
    }

    private mutating func takeHeader() -> [UInt8] {
        defer { header = nil }
        return header ?? []
    }

    private mutating func seal(_ block: ArraySlice<UInt8>) -> [UInt8] {
        defer { nonce = RcloneNonce.adding(1, to: nonce) }
        return SecretBox.seal(block, nonce: nonce, key: key)
    }
}

/// Push-based decryption: feed ciphertext chunks of any size, collect plaintext.
public struct RcloneDecryptor: Sendable {
    private let key: [UInt8]
    private var nonce: [UInt8]?
    private var pending: [UInt8] = []

    /// A nil nonce means the stream starts with the file header.
    init(key: [UInt8], nonce: [UInt8]?) {
        self.key = key
        self.nonce = nonce
    }

    public mutating func update(_ ciphertext: Data) throws(RcloneCryptError) -> Data {
        pending += ciphertext
        var offset = 0
        if nonce == nil {
            guard pending.count >= RcloneCipher.headerSize else { return Data() }
            nonce = try Self.parseHeader(Array(pending[0..<RcloneCipher.headerSize]))
            offset = RcloneCipher.headerSize
        }
        var out = [UInt8]()
        while pending.count - offset >= RcloneCipher.blockSize {
            out += try open(pending[offset..<offset + RcloneCipher.blockSize])
            offset += RcloneCipher.blockSize
        }
        pending.removeFirst(offset)
        return Data(out)
    }

    /// Opens the last partial block and checks the stream was complete.
    public mutating func finish() throws(RcloneCryptError) -> Data {
        guard nonce != nil else { throw .fileTooShort }
        defer { pending = [] }
        if pending.isEmpty { return Data() }
        guard pending.count > RcloneCipher.blockOverhead else { throw .truncatedBlock }
        return Data(try open(pending[...]))
    }

    static func parseHeader(_ header: [UInt8]) throws(RcloneCryptError) -> [UInt8] {
        guard header.count >= RcloneCipher.headerSize else { throw .fileTooShort }
        guard Array(header[0..<8]) == RcloneCipher.magic else { throw .badMagic }
        return Array(header[8..<RcloneCipher.headerSize])
    }

    private mutating func open(_ block: ArraySlice<UInt8>) throws(RcloneCryptError) -> [UInt8] {
        guard let current = nonce, let plain = SecretBox.open(block, nonce: current, key: key) else { throw .badBlock }
        nonce = RcloneNonce.adding(1, to: current)
        return plain
    }
}

enum RcloneNonce {
    /// Adds `value` to the nonce as a 192-bit little-endian integer, as rclone's `nonce.add`.
    static func adding(_ value: Int64, to nonce: [UInt8]) -> [UInt8] {
        var result = nonce
        var carry = UInt64(value)
        for i in result.indices where carry != 0 {
            let sum = UInt64(result[i]) + (carry & 0xff)
            result[i] = UInt8(truncatingIfNeeded: sum)
            carry = (carry >> 8) + (sum >> 8)
        }
        return result
    }
}
