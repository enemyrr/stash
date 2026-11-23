import Foundation
import Testing
@testable import RcloneCrypt

/// Vectors copied from rclone's own unit tests (backend/crypt/cipher_test.go, fs/config/obscure/obscure_test.go).
struct RcloneVectorTests {
    @Test func `reveal matches rclone obscure vectors`() throws {
        #expect(try RcloneObscure.reveal("YWFhYWFhYWFhYWFhYWFhYQ") == "")
        #expect(try RcloneObscure.reveal("YWFhYWFhYWFhYWFhYWFhYXMaGgIlEQ") == "potato")
        #expect(try RcloneObscure.reveal("YmJiYmJiYmJiYmJiYmJiYp3gcEWbAw") == "potato")
        #expect(try RcloneObscure.reveal(RcloneObscure.obscure("lösenord 🔑")) == "lösenord 🔑")
        #expect(throws: RcloneCryptError.badObscuredValue) { try RcloneObscure.reveal("YmJiYmJiYmJiYmJiYmJiYp*gcEWbAw") }
        #expect(throws: RcloneCryptError.badObscuredValue) { try RcloneObscure.reveal("aGVsbG8") }
        #expect(throws: RcloneCryptError.badObscuredValue) { try RcloneObscure.reveal("") }
    }

    @Test func `key derivation matches rclone`() {
        let potato = RcloneCipher(password: "potato")
        #expect(potato.dataKey == hex("7455C71AB17C865B8471F47B79ACB07EB31D5678B80C7E2EAF4FC8066A9EE468"))
        #expect(potato.nameKey == hex("765DA27AB15D77F95796711F7B93AD63BBB484072E7180A8D17A9BBEC14270D0"))
        #expect(potato.nameTweak == hex("C18D5932F55B2828C5E1E87215520310"))
        let salted = RcloneCipher(password: "potato", password2: "sausage")
        #expect(salted.dataKey == hex("8e9b6b99f8690467a071f9cb92d0aa787f8ff178bec96f999fd5206e644a1b50"))
        #expect(salted.nameKey == hex("3ea95ef681782dc9d9955d225bfd442c6f5d6897b029015c6f462e2a9dae2ce3"))
        #expect(salted.nameTweak == hex("f17fd7141d65274f363fc2a04dd2148a"))
        #expect(SharedCiphers.zeroKey.dataKey == [UInt8](repeating: 0, count: 32))
    }

    static let base32Segments = [
        ("1", "p0e52nreeaj0a5ea7s64m4j72s"), ("12", "l42g6771hnv3an9cgc8cr2n1ng"),
        ("123", "qgm4avr35m5loi1th53ato71v0"), ("1234", "8ivr2e9plj3c3esisjpdisikos"),
        ("12345", "rh9vu63q3o29eqmj4bg6gg7s44"), ("123456", "bn717l3alepn75b2fb2ejmi4b4"),
        ("1234567", "n6bo9jmb1qe3b1ogtj5qkf19k8"), ("12345678", "u9t24j7uaq94dh5q53m3s4t9ok"),
        ("123456789", "37hn305g6j12d1g0kkrl7ekbs4"), ("1234567890", "ot8d91eplaglb62k2b1trm2qv0"),
        ("12345678901", "h168vvrgb53qnrtvvmb378qrcs"), ("123456789012", "s3hsdf9e29ithrqbjqu01t8q2s"),
        ("1234567890123", "cf3jimlv1q2oc553mv7s3mh3eo"), ("12345678901234", "moq0uqdlqrblrc5pa5u5c7hq9g"),
        ("123456789012345", "eeam3li4rnommi3a762h5n7meg"),
        ("1234567890123456", "mijbj0frqf6ms7frcr6bd9h0env53jv96pjaaoirk7forcgpt70g"),
    ]

    @Test(arguments: base32Segments)
    func `standard base32 segment`(plain: String, encrypted: String) throws {
        let cipher = SharedCiphers.zeroKey
        #expect(cipher.encryptName(plain) == encrypted)
        #expect(try cipher.decryptName(encrypted) == plain)
        #expect(try cipher.decryptName(encrypted.uppercased()) == plain)
    }

    @Test func `standard base64 segments`() throws {
        let cipher = SharedCiphers.zeroKeyBase64
        for (plain, encrypted) in [("1", "yBxRX25ypgUVyj8MSxJnFw"), ("123", "1CxFf2Mti1xIPYlGruDh-A"),
                                   ("1234567890123456", "tKa5gfvTzW4d-2bMtqYgdf5Rz-k2ZqViW6HfjbIZ6cE")] {
            #expect(cipher.encryptName(plain) == encrypted)
            #expect(try cipher.decryptName(encrypted) == plain)
        }
    }

    @Test func `paths, version suffixes and directory modes`() throws {
        let cipher = SharedCiphers.zeroKey
        let p1 = "p0e52nreeaj0a5ea7s64m4j72s", p12 = "l42g6771hnv3an9cgc8cr2n1ng", p123 = "qgm4avr35m5loi1th53ato71v0"
        #expect(cipher.encryptPath("1/12/123") == "\(p1)/\(p12)/\(p123)")
        #expect(cipher.encryptPath("1/12-v2001-02-03-040506-123") == "\(p1)/\(p12)-v2001-02-03-040506-123")
        #expect(try cipher.decryptPath("\(p1)/\(p12)-v2001-02-03-040506-123") == "1/12-v2001-02-03-040506-123")
        #expect(cipher.encryptPath("1/12/123", isDirectory: true) == "\(p1)/\(p12)/\(p123)")

        let plainDirs = RcloneCipher(password: "", directoryNameEncryption: false)
        #expect(plainDirs.encryptPath("1/12/123") == "1/12/\(p123)")
        #expect(plainDirs.encryptPath("1/12", isDirectory: true) == "1/12")
        #expect(try plainDirs.decryptPath("1/12/\(p123)") == "1/12/123")

        // Directories encrypt the version string, files keep it in plain text; legacy dir names still decrypt.
        let dir = "dir-v2001-02-03-040506-123"
        let encryptedDir = cipher.encryptPath(dir, isDirectory: true)
        let encryptedFile = cipher.encryptPath(dir)
        #expect(cipher.encryptPath(dir + "/file.txt").hasPrefix(encryptedDir + "/"))
        #expect(encryptedFile.hasSuffix("-v2001-02-03-040506-123") && encryptedFile != encryptedDir)
        #expect(try cipher.decryptPath(encryptedDir, isDirectory: true) == dir)
        #expect(try cipher.decryptPath(encryptedFile, isDirectory: true) == dir)
        #expect(throws: RcloneCryptError.self) { try cipher.decryptPath("!!!-v2001-02-03-040506-123", isDirectory: true) }
    }

    @Test func `segment decryption errors`() {
        let cipher = SharedCiphers.zeroKey
        #expect(throws: RcloneCryptError.badNameEncoding) { try cipher.decryptName("64=") }
        #expect(throws: RcloneCryptError.badNameEncoding) { try cipher.decryptName("!") }
        #expect(throws: RcloneCryptError.badNameLength) { try cipher.decryptName(String(repeating: "a", count: 3328)) }
        #expect(throws: RcloneCryptError.badNameLength) { try cipher.decryptName(Base32Hex.encode(Array("a".utf8))) }
        #expect(throws: RcloneCryptError.badNamePadding) { try cipher.decryptName(Base32Hex.encode(Array("123456789abcdef0".utf8))) }
        #expect(throws: RcloneCryptError.badNameLength) { try cipher.decryptPath("\(Base32Hex.encode([0x31]))p0e52nreeaj0a5ea7s64m4j72s") }
    }

    @Test func `obfuscate and off modes`() throws {
        let obfuscate = SharedCiphers.zeroKeyObfuscate
        #expect(obfuscate.encryptPath("1/12/123/!hello") == "49.6/99.23/150.890/53.!!lipps")
        #expect(obfuscate.encryptPath("1/12/123/!hello-v2001-02-03-040506-123") == "49.6/99.23/150.890/53-v2001-02-03-040506-123.!!lipps")
        #expect(obfuscate.encryptPath("1/12/123/hello-v2001-02-03-040506-123.txt") == "49.6/99.23/150.890/162.uryyB-v2001-02-03-040506-123.GKG")
        #expect(obfuscate.encryptName("\u{a1}") == "161.\u{e4}")
        #expect(obfuscate.encryptName("\u{3a0}") == "160.\u{3c2}")
        #expect(try obfuscate.decryptName("!.hello") == "hello")
        #expect(try obfuscate.decryptName("161.\u{e4}") == "\u{a1}")
        #expect(try obfuscate.decryptPath("49.6/99.23/150.890/53.!!lipps") == "1/12/123/!hello")
        #expect(throws: RcloneCryptError.notAnEncryptedName) { try obfuscate.decryptName("hello") }

        let off = RcloneCipher(password: "", filenameEncryption: .off)
        #expect(off.encryptPath("1/12/123") == "1/12/123.bin")
        #expect(off.encryptPath("1/12/123", isDirectory: true) == "1/12/123")
        #expect(try off.decryptPath("1/12/123.bin") == "1/12/123")
        #expect(try off.decryptPath("1/12/123-v2001-02-03-040506-123.bin") == "1/12/123-v2001-02-03-040506-123")
        #expect(throws: RcloneCryptError.notAnEncryptedName) { try off.decryptPath("1/12/123.bix") }
        #expect(throws: RcloneCryptError.notAnEncryptedName) { try off.decryptPath(".bin") }
        #expect(try RcloneCipher(password: "", filenameEncryption: .off, suffix: "").decryptPath("1/12/123") == "1/12/123")
    }

    @Test func `sizes match rclone`() throws {
        let cases: [(Int64, Int64)] = [
            (0, 32), (1, 32 + 16 + 1), (65536, 32 + 16 + 65536), (65537, 32 + 16 + 65536 + 16 + 1),
            (1 << 20, 32 + 16 * (16 + 65536)), ((1 << 20) + 65535, 32 + 16 * (16 + 65536) + 16 + 65535),
            ((1 << 40) + 1, 32 + 16_777_216 * (16 + 65536) + 16 + 1),
        ]
        for (plain, encrypted) in cases {
            #expect(RcloneCipher.encryptedSize(plainSize: plain) == encrypted)
            #expect(try RcloneCipher.plainSize(encryptedSize: encrypted) == plain)
        }
        #expect(throws: RcloneCryptError.fileTooShort) { try RcloneCipher.plainSize(encryptedSize: 7) }
        #expect(throws: RcloneCryptError.truncatedBlock) { try RcloneCipher.plainSize(encryptedSize: 32 + 16) }
        #expect(throws: RcloneCryptError.truncatedBlock) { try RcloneCipher.plainSize(encryptedSize: 32 + 16 + 65536 + 16) }
    }

    @Test func `content matches rclone fixed-nonce vectors`() throws {
        let header = hex("52434c4f4e450000 0102030405060708090a0b0c0d0e0f101112131415161718")
        let cases: [([UInt8], [UInt8])] = [
            ([], header),
            ([1], header + hex("095b446cd6237bbcb08d09fb524ce565aa")),
            (Array(1...16), header + hex("b9c4552a27100629 18960a3e608c29b9 aa8a5e1e165b6d07 5de4e9bb367fd6d4")),
        ]
        for (plain, expected) in cases {
            var encryptor = SharedCiphers.zeroKey.makeEncryptor(nonce: Array(1...24))
            let encrypted = encryptor.update(Data(plain)) + encryptor.finish()
            #expect(Array(encrypted) == expected)
            #expect(try SharedCiphers.zeroKey.decrypt(encrypted) == Data(plain))
        }
    }

    @Test func `nonce add carries like rclone`() {
        let ff = [UInt8](repeating: 0xff, count: 24)
        #expect(RcloneNonce.adding(1, to: ff) == [UInt8](repeating: 0, count: 24))
        var almost = [UInt8](repeating: 0, count: 24)
        almost[0] = 0xff
        almost[1] = 0xff
        #expect(RcloneNonce.adding(2, to: almost) == [1, 0, 1] + [UInt8](repeating: 0, count: 21))
        #expect(RcloneNonce.adding(0x0102, to: [UInt8](repeating: 0, count: 24)) == [2, 1] + [UInt8](repeating: 0, count: 22))
    }

    @Test func `content errors are typed`() throws {
        let cipher = SharedCiphers.zeroKey
        let encrypted = cipher.encrypt(randomData(70_000))
        #expect(throws: RcloneCryptError.fileTooShort) { try cipher.decrypt(encrypted.prefix(31)) }
        #expect(throws: RcloneCryptError.badMagic) { try cipher.decrypt(Data(repeating: 0, count: 100)) }
        #expect(throws: RcloneCryptError.truncatedBlock) { try cipher.decrypt(encrypted.prefix(32 + 65552 + 10)) }
        var corrupt = encrypted
        corrupt[100] ^= 1
        #expect(throws: RcloneCryptError.badBlock) { try cipher.decrypt(corrupt) }
        #expect(throws: RcloneCryptError.badBlock) { try RcloneCipher(password: "wrong").decrypt(encrypted) }
    }

    @Test func `streaming with odd chunk sizes and range reads`() throws {
        let cipher = SharedCiphers.zeroKey
        let plain = randomData(3 * 65536 + 123)
        var encryptor = cipher.makeEncryptor()
        var encrypted = Data()
        for start in stride(from: 0, to: plain.count, by: 7777) {
            encrypted += encryptor.update(plain.subdata(in: start..<min(start + 7777, plain.count)))
        }
        encrypted += encryptor.finish()
        #expect(Int64(encrypted.count) == RcloneCipher.encryptedSize(plainSize: Int64(plain.count)))

        var decryptor = cipher.makeDecryptor()
        var decrypted = Data()
        for start in stride(from: 0, to: encrypted.count, by: 1000) {
            decrypted += try decryptor.update(encrypted.subdata(in: start..<min(start + 1000, encrypted.count)))
        }
        decrypted += try decryptor.finish()
        #expect(decrypted == plain)

        let size = Int64(plain.count)
        let cases: [(Int, Int)] = [(0, 1), (0, 65536), (65535, 2), (65536, 65536), (100_000, 150_000), (plain.count - 5, 100), (0, plain.count)]
        for (offset, length) in cases {
            let range = try #require(RcloneCipher.contentRange(plainOffset: Int64(offset), length: Int64(length), plainSize: size))
            let lo = Int(range.encryptedOffset)
            let blocks = encrypted.subdata(in: lo..<lo + Int(range.encryptedLength))
            let got = try cipher.decrypt(range: range, header: encrypted.prefix(32), blocks: blocks)
            #expect(got == plain.subdata(in: offset..<min(offset + length, plain.count)))
        }
        #expect(RcloneCipher.contentRange(plainOffset: size, length: 10, plainSize: size) == nil)
        #expect(RcloneCipher.contentRange(plainOffset: 70_000, length: 10, plainSize: size)?.httpRange == "bytes=65584-131135")
    }
}
