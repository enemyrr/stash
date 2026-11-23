/// rclone's `lib/version`: a `-vYYYY-MM-DD-HHMMSS-mmm` suffix before the extension
/// (from `--b2-versions`) stays in plain text on file names.
enum VersionSuffix {
    /// Splits `name` into (name without version, version suffix) if it carries a valid one.
    static func split(_ name: String) -> (name: String, version: String)? {
        let bytes = Array(name.utf8)
        let (base, ext) = splitExtension(bytes)
        guard base.count >= 23 else { return nil }
        let suffix = Array(base.suffix(23))
        guard isValid(suffix) else { return nil }
        return (String(decoding: base.dropLast(23) + ext, as: UTF8.self), String(decoding: suffix, as: UTF8.self))
    }

    /// Inserts a version suffix before the extension.
    static func add(_ version: String, to name: String) -> String {
        let (base, ext) = splitExtension(Array(name.utf8))
        return String(decoding: base + Array(version.utf8) + ext, as: UTF8.self)
    }

    /// Matches the regex only (no date validation), as `version.Match`.
    static func matches(_ name: String) -> Bool {
        let base = splitExtension(Array(name.utf8)).base
        return base.count >= 23 && digitsMatch(Array(base.suffix(23)))
    }

    /// Go's `path.Ext` with rclone's dot-file rule: ".bashrc" has no extension.
    private static func splitExtension(_ bytes: [UInt8]) -> (base: [UInt8], ext: [UInt8]) {
        guard let dot = bytes.lastIndex(of: UInt8(ascii: ".")), dot > 0 else { return (bytes, []) }
        return (Array(bytes[..<dot]), Array(bytes[dot...]))
    }

    private static func digitsMatch(_ s: [UInt8]) -> Bool {
        let pattern = Array("-v0000-00-00-000000-000".utf8)
        return zip(s, pattern).allSatisfy { char, p in
            p == UInt8(ascii: "0") ? (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(char) : char == p
        }
    }

    /// Regex match plus the range checks Go's `time.Parse` applies.
    private static func isValid(_ s: [UInt8]) -> Bool {
        guard digitsMatch(s) else { return false }
        func number(_ start: Int, _ length: Int) -> Int {
            s[start..<start + length].reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) }
        }
        let year = number(2, 4), month = number(7, 2), day = number(10, 2)
        let hour = number(13, 2), minute = number(15, 2), second = number(17, 2)
        guard (1...12).contains(month), hour < 24, minute < 60, second < 60 else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        return (1...days).contains(day)
    }
}
