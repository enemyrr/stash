import CommonCrypto
import Foundation

/// rclone's reversible obscuring of passwords in `rclone.conf` (`rclone obscure` / `reveal`).
public enum RcloneObscure {
    private static let key: [UInt8] = [
        0x9c, 0x93, 0x5b, 0x48, 0x73, 0x0a, 0x55, 0x4d, 0x6b, 0xfd, 0x7c, 0x63, 0xc8, 0x86, 0xa9, 0x2b,
        0xd3, 0x90, 0x19, 0x8e, 0xb8, 0x12, 0x8a, 0xfb, 0xf4, 0xde, 0x16, 0x2b, 0x8b, 0x95, 0xf6, 0x38,
    ]

    public static func reveal(_ obscured: String) throws(RcloneCryptError) -> String {
        guard let data = Base64URL.decode(obscured), data.count >= 16 else { throw .badObscuredValue }
        let plain = AES.ctr(key: key, iv: Array(data[0..<16]), Array(data[16...]))
        return String(decoding: plain, as: UTF8.self)
    }

    public static func obscure(_ value: String) -> String {
        let iv = randomBytes(16)
        return Base64URL.encode(iv + AES.ctr(key: key, iv: iv, Array(value.utf8)))
    }
}

func randomBytes(_ count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    precondition(CCRandomGenerateBytes(&bytes, count) == kCCSuccess)
    return bytes
}
