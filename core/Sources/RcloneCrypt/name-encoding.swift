import Foundation

/// Lowercase base32hex without padding, as rclone's `caseInsensitiveBase32Encoding`.
enum Base32Hex {
    private static let alphabet = Array("0123456789abcdefghijklmnopqrstuv".utf8)

    static func encode(_ bytes: [UInt8]) -> String {
        var out = [UInt8]()
        var buffer: UInt32 = 0, bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[Int((buffer >> UInt32(bits)) & 31)])
            }
            buffer &= (1 << UInt32(bits)) - 1
        }
        if bits > 0 { out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)]) }
        return String(decoding: out, as: UTF8.self)
    }

    /// Case-insensitive; like Go it ignores non-zero trailing bits.
    static func decode(_ string: String) -> [UInt8]? {
        guard [0, 2, 4, 5, 7].contains(string.utf8.count % 8) else { return nil }
        var out = [UInt8]()
        var buffer: UInt32 = 0, bits = 0
        for char in string.utf8 {
            let value: UInt8
            switch char {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): value = char - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "v"): value = char - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "V"): value = char - UInt8(ascii: "A") + 10
            default: return nil
            }
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bits)))
                buffer &= (1 << UInt32(bits)) - 1
            }
        }
        return out
    }
}

/// Go's `base64.RawURLEncoding`.
enum Base64URL {
    static func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> [UInt8]? {
        guard string.utf8.count % 4 != 1, !string.contains("="), !string.contains("+"), !string.contains("/")
        else { return nil }
        let padded = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - string.utf8.count % 4) % 4)
        return Data(base64Encoded: padded).map(Array.init)
    }
}

enum PKCS7 {
    static func pad(_ bytes: [UInt8]) -> [UInt8] {
        let padding = 16 - bytes.count % 16
        return bytes + [UInt8](repeating: UInt8(padding), count: padding)
    }

    static func unpad(_ bytes: [UInt8]) -> [UInt8]? {
        guard let last = bytes.last, bytes.count % 16 == 0, (1...16).contains(last),
              bytes.suffix(Int(last)).allSatisfy({ $0 == last })
        else { return nil }
        return Array(bytes.dropLast(Int(last)))
    }
}
