import Foundation
import Testing
@testable import RcloneCrypt

/// A throwaway rclone config with crypt remotes over local temp folders and random test passwords.
enum CLIFixture {
    static let root = FileManager.default.temporaryDirectory.appending(path: "rclone-crypt-tests-\(UUID().uuidString)")
    static let password = "test-\(UUID().uuidString)-lösen ✓"
    static let password2 = "salt-\(UUID().uuidString)"
    static let obscuredPassword2 = try! String(decoding: Rclone.run(["obscure", password2]), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    static let rclone: Rclone = {
        let remotes: [(String, String)] = [
            ("std", ""), ("b64", "filename_encoding = base64"), ("obf", "filename_encryption = obfuscate"),
            ("off", "filename_encryption = off"), ("nodir", "directory_name_encryption = false"),
        ]
        // password is obscured by Swift, password2 by rclone: both directions of obscure/reveal get exercised.
        let config = remotes.map { name, option in
            """
            [\(name)]
            type = crypt
            remote = \(root.appending(path: name).path)
            password = \(RcloneObscure.obscure(password))
            password2 = \(obscuredPassword2)
            \(option)

            """
        }.joined()
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "rclone.conf")
        try! config.write(to: url, atomically: true, encoding: .utf8)
        return Rclone(config: url)
    }()

    static let std = RcloneCipher(password: password, password2: password2)
    static let b64 = RcloneCipher(password: password, password2: password2, filenameEncoding: .base64)
    static let obf = RcloneCipher(password: password, password2: password2, filenameEncryption: .obfuscate)
    static let off = RcloneCipher(password: password, password2: password2, filenameEncryption: .off)
    static let nodir = RcloneCipher(password: password, password2: password2, directoryNameEncryption: false)

    static func cipher(_ remote: String) -> RcloneCipher {
        ["std": std, "b64": b64, "obf": obf, "off": off, "nodir": nodir][remote]!
    }

    static let names = [
        "a", "hello.txt", "with space", "  leading and trailing  ", "ünïcødé ñåmé.pdf", "e\u{301} decomposed",
        "日本語のファイル名.txt", "emoji 🎉🚀👩‍👩‍👧", "Ελληνικά", "עברית", ".hidden", "trailing.", "..dots..",
        "!bang!", "!", "a.b.c.d", "UPPER lower 0123456789", "tab-free#$%&'()+,;=@[]^`{}~",
        String(repeating: "x", count: 15), String(repeating: "y", count: 16), String(repeating: "z", count: 17),
        String(repeating: "long name ", count: 14), String(repeating: "ö", count: 120),
        "file-v2001-02-03-040506-123.txt", "file-v2001-02-03-040506-123", "bad-v2023-13-01-000000-000.txt",
        "-v2001-02-03-040506-123.txt", "\u{a1}\u{ff}\u{100}\u{3a0}", "Ø-v2024-02-29-235959-999",
        "dir/sub dir/file.txt", "a/b/c/d/e", "photos/2024/IMG_0001.HEIC",
    ]
}

@Suite(.enabled(if: Rclone.isAvailable, "rclone binary not found"))
struct RcloneCLITests {
    @Test func `reveal reads rclone-obscured password`() throws {
        #expect(try RcloneObscure.reveal(CLIFixture.obscuredPassword2) == CLIFixture.password2)
    }

    @Test(arguments: ["std", "b64", "obf", "off", "nodir"])
    func `names match rclone backend encode and decode`(remote: String) throws {
        let cipher = CLIFixture.cipher(remote)
        let encoded = try CLIFixture.rclone.lines(["backend", "encode", "\(remote):", "--"] + CLIFixture.names)
        try #require(encoded.count == CLIFixture.names.count)
        // rclone itself does not round-trip "-v…-123.txt" (it decodes to ".txt-v…-123"), so
        // compare decryption with rclone's decode rather than with the input.
        let decoded = try CLIFixture.rclone.lines(["backend", "decode", "\(remote):", "--"] + encoded)
        try #require(decoded.count == CLIFixture.names.count)
        for (plain, (rcloneEncrypted, rcloneDecoded)) in zip(CLIFixture.names, zip(encoded, decoded)) {
            #expect(Array(cipher.encryptPath(plain).utf8) == Array(rcloneEncrypted.utf8), "\(remote): \(plain)")
            #expect(Array(try cipher.decryptPath(rcloneEncrypted).utf8) == Array(rcloneDecoded.utf8), "\(remote): \(plain)")
        }
    }

    @Test(arguments: ["std", "nodir", "obf"])
    func `uploaded paths match on disk`(remote: String) throws {
        let cipher = CLIFixture.cipher(remote)
        let source = CLIFixture.root.appending(path: "upload-\(remote).txt")
        try Data("x".utf8).write(to: source)
        let path = "dir-v2001-02-03-040506-123/sub dir/ünï-v2001-02-03-040506-123.txt"
        try CLIFixture.rclone.run(["copyto", source.path, "\(remote):\(path)"])

        let encryptedPath = cipher.encryptPath(path)
        let onDisk = CLIFixture.root.appending(path: remote).appending(path: encryptedPath)
        #expect(FileManager.default.fileExists(atPath: onDisk.path), "\(remote)")
        let encryptedDir = cipher.encryptPath("dir-v2001-02-03-040506-123/sub dir", isDirectory: true)
        #expect(encryptedPath.hasPrefix(encryptedDir + "/"))
        #expect(try cipher.decryptPath(encryptedDir, isDirectory: true) == "dir-v2001-02-03-040506-123/sub dir")
    }

    @Test(arguments: [0, 1, 65535, 65536, 65537, (1 << 20) + 3])
    func `content round trips with rclone`(size: Int) throws {
        let cipher = CLIFixture.std
        let rclone = CLIFixture.rclone
        let plain = randomData(size)
        let plainFile = CLIFixture.root.appending(path: "plain-\(size)")
        try plain.write(to: plainFile)

        // rclone encrypts -> Swift decrypts (whole file, file API and ranges).
        let path = "content/size-\(size).bin"
        try rclone.run(["copyto", plainFile.path, "std:\(path)"])
        let encryptedFile = CLIFixture.root.appending(path: "std").appending(path: cipher.encryptPath(path))
        let encrypted = try Data(contentsOf: encryptedFile)
        #expect(Int64(encrypted.count) == RcloneCipher.encryptedSize(plainSize: Int64(size)))
        #expect(try RcloneCipher.plainSize(encryptedSize: Int64(encrypted.count)) == Int64(size))
        #expect(try cipher.decrypt(encrypted) == plain)
        let decryptedFile = CLIFixture.root.appending(path: "decrypted-\(size)")
        try cipher.decryptFile(at: encryptedFile, to: decryptedFile)
        #expect(try Data(contentsOf: decryptedFile) == plain)

        let ranges: [(Int, Int)] = [(0, 1), (0, 100), (65530, 20), (65536, 65536), (size / 2, 70_000), (max(size - 3, 0), 10)]
        for (offset, length) in ranges where offset < size {
            let range = try #require(RcloneCipher.contentRange(plainOffset: Int64(offset), length: Int64(length), plainSize: Int64(size)))
            let lo = Int(range.encryptedOffset)
            let got = try cipher.decrypt(range: range, header: encrypted.prefix(32), blocks: encrypted.subdata(in: lo..<lo + Int(range.encryptedLength)))
            let expected = plain.subdata(in: offset..<min(offset + length, size))
            #expect(got == expected, "range \(offset)+\(length)")
            let viaRclone = try rclone.run(["cat", "--offset", "\(offset)", "--count", "\(length)", "std:\(path)"])
            #expect(got == viaRclone, "rclone cat range \(offset)+\(length)")
        }

        // Swift encrypts -> rclone decrypts.
        let swiftPath = "swift/size-\(size).bin"
        let target = CLIFixture.root.appending(path: "std").appending(path: cipher.encryptPath(swiftPath))
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try cipher.encryptFile(at: plainFile, to: target)
        #expect(try rclone.run(["cat", "std:\(swiftPath)"]) == plain)
        let listed = try rclone.lines(["lsf", "std:swift"])
        #expect(listed.contains("size-\(size).bin"))
    }
}
