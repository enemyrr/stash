/// Errors thrown when decoding or decrypting rclone crypt data.
public enum RcloneCryptError: Error, Equatable, Sendable {
    /// An obscured config value is not valid base64url or is too short.
    case badObscuredValue
    /// An encrypted name is not valid base32/base64.
    case badNameEncoding
    /// A decoded name is empty, not a whole number of AES blocks, or longer than 2048 bytes.
    case badNameLength
    /// A decrypted name has bad PKCS#7 padding (wrong key or corrupt name).
    case badNamePadding
    /// A decrypted name is not valid UTF-8.
    case nameNotUTF8
    /// The name lacks the suffix or obfuscation prefix that marks an encrypted name.
    case notAnEncryptedName
    /// The data is shorter than the 32-byte file header.
    case fileTooShort
    /// The data does not start with `RCLONE\0\0`.
    case badMagic
    /// A block is 16 bytes or shorter, so it has no payload.
    case truncatedBlock
    /// A block failed authentication (wrong password or corrupt data).
    case badBlock
}
