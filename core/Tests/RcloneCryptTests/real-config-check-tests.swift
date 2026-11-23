import Foundation
import Testing
@testable import RcloneCrypt

enum RealRemote {
    static let configURL = ProcessInfo.processInfo.environment["STASH_TEST_RCLONE_CONFIG"].map { URL(filePath: $0) }
    static let name = ProcessInfo.processInfo.environment["STASH_TEST_RCLONE_CRYPT_REMOTE"]
}

/// Opt-in, read-only check against a real crypt remote: set `STASH_TEST_RCLONE_CONFIG` to an rclone.conf and
/// `STASH_TEST_RCLONE_CRYPT_REMOTE` to the name of a crypt remote in it. It reveals the passwords in memory, lists
/// top-level raw names of the underlying remote and compares their decryption with rclone's own listing.
/// It prints pass/fail only, never names or secrets.
@Suite(.enabled(if: RealRemote.configURL != nil && RealRemote.name != nil && Rclone.isAvailable))
struct RealConfigCheckTests {
    @Test func `decrypts top-level names of the real remote`() throws {
        let configURL = try #require(RealRemote.configURL)
        let remote = try #require(RealRemote.name)
        let section = try Self.section(remote, in: String(contentsOf: configURL, encoding: .utf8))
        let underlying = try #require(section["remote"])
        let password = try RcloneObscure.reveal(try #require(section["password"]))
        let password2 = try section["password2"].map { try RcloneObscure.reveal($0) } ?? ""
        #expect(section["filename_encryption"] ?? "standard" == "standard")
        let cipher = RcloneCipher(password: password, password2: password2)

        let rclone = Rclone(config: configURL)
        let raw = try rclone.lines(["lsf", underlying, "--max-depth", "1"])
        let plain = try rclone.lines(["lsf", "\(remote):", "--max-depth", "1"])
        let decrypted = raw.compactMap { name -> String? in
            let isDirectory = name.hasSuffix("/")
            let bare = isDirectory ? String(name.dropLast()) : name
            guard let clear = try? cipher.decryptName(bare, isDirectory: isDirectory) else { return nil }
            return isDirectory ? clear + "/" : clear
        }
        // rclone skips raw entries it cannot decrypt (e.g. stray unencrypted objects), so we compare
        // what both sides can decrypt.
        let matches = !decrypted.isEmpty && decrypted.count == plain.count && Set(decrypted.map { Array($0.utf8) }) == Set(plain.map { Array($0.utf8) })
        #expect(matches)
    }

    static func section(_ name: String, in config: String) throws -> [String: String] {
        var values: [String: String] = [:]
        var inSection = false
        for line in config.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("[") {
                inSection = line == "[\(name)]"
            } else if inSection, let eq = line.firstIndex(of: "=") {
                values[line[..<eq].trimmingCharacters(in: .whitespaces)] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return values
    }
}
