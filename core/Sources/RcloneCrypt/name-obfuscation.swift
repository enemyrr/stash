/// rclone's "obfuscate" filename mode: a key-dependent rotation of each character.
enum NameObfuscation {
    private static let quote: Unicode.Scalar = "!"

    static func obfuscate(_ plain: String, nameKey: [UInt8]) -> String {
        if plain.isEmpty { return "" }
        let scalars = plain.unicodeScalars
        var dir = scalars.reduce(0) { $0 + Int($1.value) } % 256
        var result = String.UnicodeScalarView()
        result.append(contentsOf: "\(dir).".unicodeScalars)
        dir += nameKey.reduce(0) { $0 + Int($1) }

        for scalar in scalars {
            let r = Int(scalar.value)
            switch r {
            case Int(quote.value):
                result.append(quote)
                result.append(quote)
            case 0x30...0x39:
                result.append(Unicode.Scalar(0x30 + (r - 0x30 + dir % 9 + 1) % 10)!)
            case 0x41...0x5a, 0x61...0x7a:
                var pos = r - 0x41
                if pos >= 26 { pos -= 6 }
                pos = (pos + dir % 25 + 1) % 52
                if pos >= 26 { pos += 6 }
                result.append(Unicode.Scalar(0x41 + pos)!)
            case 0xa0...0xff:
                result.append(Unicode.Scalar(0xa0 + (r - 0xa0 + dir % 95 + 1) % 96)!)
            case 0x100...:
                let base = r - r % 256
                if let rotated = Unicode.Scalar(base + (r - base + dir % 127 + 1) % 256) {
                    result.append(rotated)
                } else {
                    result.append(quote)
                    result.append(scalar)
                }
            default:
                result.append(scalar)
            }
        }
        return String(result)
    }

    static func deobfuscate(_ cipher: String, nameKey: [UInt8]) throws(RcloneCryptError) -> String {
        if cipher.isEmpty { return "" }
        guard let dot = cipher.firstIndex(of: ".") else { throw .notAnEncryptedName }
        let prefix = cipher[..<dot], body = cipher[cipher.index(after: dot)...]
        if prefix == "!" { return String(body) }
        guard var dir = Int(prefix) else { throw .notAnEncryptedName }
        dir += nameKey.reduce(0) { $0 + Int($1) }

        var result = String.UnicodeScalarView()
        var inQuote = false
        for scalar in body.unicodeScalars {
            let r = Int(scalar.value)
            if inQuote {
                result.append(scalar)
                inQuote = false
                continue
            }
            var out: Int
            switch r {
            case Int(quote.value):
                inQuote = true
                continue
            case 0x30...0x39:
                out = r - (dir % 9 + 1)
                if out < 0x30 { out += 10 }
            case 0x41...0x5a, 0x61...0x7a:
                var pos = r - 0x41
                if pos >= 26 { pos -= 6 }
                pos -= dir % 25 + 1
                if pos < 0 { pos += 52 }
                if pos >= 26 { pos += 6 }
                out = 0x41 + pos
            case 0xa0...0xff:
                out = r - (dir % 95 + 1)
                if out < 0xa0 { out += 96 }
            case 0x100...:
                let base = r - r % 256
                out = r - (dir % 127 + 1)
                if out < base { out += 256 }
            default:
                out = r
            }
            result.append(Unicode.Scalar(UInt32(clamping: max(out, 0))) ?? "\u{FFFD}")
        }
        return String(result)
    }
}
