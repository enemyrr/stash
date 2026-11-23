/// rclone `crypt` backend: key derivation and name encryption, byte-compatible with rclone.
///
/// Content encryption lives in `content-cipher.swift`. Building a cipher runs scrypt
/// (about 16 MiB and tens of milliseconds), so build one per remote and reuse it.
public struct RcloneCipher: Sendable {
    /// rclone's `filename_encryption`.
    public enum FilenameEncryption: String, Sendable {
        case standard, obfuscate, off
    }

    /// rclone's `filename_encoding` for the "standard" mode.
    public enum FilenameEncoding: String, Sendable {
        case base32, base64
    }

    static let defaultSalt: [UInt8] = [
        0xA8, 0x0D, 0xF4, 0x3A, 0x8F, 0xBD, 0x03, 0x08, 0xA7, 0xCA, 0xB8, 0x3E, 0x58, 0x1F, 0x86, 0xB1,
    ]

    public let filenameEncryption: FilenameEncryption
    public let directoryNameEncryption: Bool
    public let filenameEncoding: FilenameEncoding
    /// File suffix for the "off" mode; rclone's default is ".bin", "none" in the config means "".
    public let suffix: String

    let dataKey: [UInt8]
    let nameKey: [UInt8]
    let nameTweak: [UInt8]

    /// Takes plain-text passwords; pass rclone.conf values through `RcloneObscure.reveal` first.
    /// An empty `password2` selects rclone's built-in salt. An empty `password` gives all-zero
    /// keys, as rclone's `Cipher.Key` does (the rclone backend itself refuses an empty password).
    public init(
        password: String,
        password2: String = "",
        filenameEncryption: FilenameEncryption = .standard,
        directoryNameEncryption: Bool = true,
        filenameEncoding: FilenameEncoding = .base32,
        suffix: String = ".bin"
    ) {
        let key = password.isEmpty
            ? [UInt8](repeating: 0, count: 80)
            : Scrypt.derive(
                password: Array(password.utf8),
                salt: password2.isEmpty ? Self.defaultSalt : Array(password2.utf8),
                n: 16384, r: 8, p: 1, length: 80)
        dataKey = Array(key[0..<32])
        nameKey = Array(key[32..<64])
        nameTweak = Array(key[64..<80])
        self.filenameEncryption = filenameEncryption
        self.directoryNameEncryption = directoryNameEncryption
        self.filenameEncoding = filenameEncoding
        self.suffix = suffix
    }

    // MARK: Paths

    /// Encrypts a "/"-separated path, as rclone's `EncryptFileName` / `EncryptDirName`.
    public func encryptPath(_ path: String, isDirectory: Bool = false) -> String {
        if isDirectory {
            guard filenameEncryption != .off, directoryNameEncryption else { return path }
            return transformSegments(path, stripVersion: false) { encryptSegment($0) }
        }
        if filenameEncryption == .off { return path + suffix }
        return transformSegments(path, stripVersion: true) { encryptSegment($0) }
    }

    /// Decrypts a "/"-separated path, as rclone's `DecryptFileName` / `DecryptDirName`.
    public func decryptPath(_ path: String, isDirectory: Bool = false) throws(RcloneCryptError) -> String {
        if isDirectory {
            guard filenameEncryption != .off, directoryNameEncryption else { return path }
            do {
                return try transformSegments(path, stripVersion: false) { s throws(RcloneCryptError) in try decryptSegment(s) }
            } catch {
                // Directories written by older rclone versions kept a version suffix in plain text.
                guard VersionSuffix.matches(lastSegment(path)),
                      let legacy = try? transformSegments(path, stripVersion: true, { s throws(RcloneCryptError) in try decryptSegment(s) })
                else { throw error }
                return legacy
            }
        }
        if filenameEncryption == .off {
            let bytes = Array(path.utf8), suffixBytes = Array(suffix.utf8)
            guard bytes.count > suffixBytes.count, bytes.suffix(suffixBytes.count).elementsEqual(suffixBytes)
            else { throw .notAnEncryptedName }
            let plain = String(decoding: bytes.dropLast(suffixBytes.count), as: UTF8.self)
            if VersionSuffix.matches(plain), let split = VersionSuffix.split(plain), split.name.isEmpty {
                throw .notAnEncryptedName
            }
            return plain
        }
        return try transformSegments(path, stripVersion: true) { s throws(RcloneCryptError) in try decryptSegment(s) }
    }

    /// Encrypts a single path component (no "/").
    public func encryptName(_ name: String, isDirectory: Bool = false) -> String {
        encryptPath(name, isDirectory: isDirectory)
    }

    /// Decrypts a single path component (no "/").
    public func decryptName(_ name: String, isDirectory: Bool = false) throws(RcloneCryptError) -> String {
        try decryptPath(name, isDirectory: isDirectory)
    }

    // MARK: Segments

    private func transformSegments<E: Error>(
        _ path: String, stripVersion: Bool, _ transform: (String) throws(E) -> String
    ) throws(E) -> String {
        var segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for i in segments.indices {
            let isLast = i == segments.count - 1
            if !directoryNameEncryption && !isLast { continue }
            if stripVersion && isLast, let split = VersionSuffix.split(segments[i]) {
                segments[i] = VersionSuffix.add(split.version, to: try transform(split.name))
            } else {
                segments[i] = try transform(segments[i])
            }
        }
        return segments.joined(separator: "/")
    }

    private func lastSegment(_ path: String) -> String {
        String(path.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
    }

    func encryptSegment(_ plain: String) -> String {
        if plain.isEmpty { return "" }
        if filenameEncryption == .obfuscate { return NameObfuscation.obfuscate(plain, nameKey: nameKey) }
        let encrypted = EME.transform(key: nameKey, tweak: nameTweak, PKCS7.pad(Array(plain.utf8)), encrypt: true)
        return filenameEncoding == .base32 ? Base32Hex.encode(encrypted) : Base64URL.encode(encrypted)
    }

    func decryptSegment(_ cipher: String) throws(RcloneCryptError) -> String {
        if cipher.isEmpty { return "" }
        if filenameEncryption == .obfuscate { return try NameObfuscation.deobfuscate(cipher, nameKey: nameKey) }
        if filenameEncoding == .base32 && cipher.hasSuffix("=") { throw .badNameEncoding }
        let decoded = filenameEncoding == .base32 ? Base32Hex.decode(cipher) : Base64URL.decode(cipher)
        guard let raw = decoded else { throw .badNameEncoding }
        guard !raw.isEmpty, raw.count % 16 == 0, raw.count <= 2048 else { throw .badNameLength }
        let padded = EME.transform(key: nameKey, tweak: nameTweak, raw, encrypt: false)
        guard let plain = PKCS7.unpad(padded) else { throw .badNamePadding }
        guard let name = String(validating: plain, as: UTF8.self) else { throw .nameNotUTF8 }
        return name
    }
}
