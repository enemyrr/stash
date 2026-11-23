import Foundation
import Testing
@testable import RcloneCrypt

struct PrimitiveVectorTests {
    @Test func `scrypt RFC 7914 vectors`() {
        #expect(Scrypt.derive(password: [], salt: [], n: 16, r: 1, p: 1, length: 64) == hex("""
            77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442
            fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906
            """))
        #expect(Scrypt.derive(password: Array("password".utf8), salt: Array("NaCl".utf8), n: 1024, r: 8, p: 16, length: 64) == hex("""
            fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b373162
            2eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640
            """))
        // rclone's parameters (N=16384, r=8, p=1).
        #expect(Scrypt.derive(password: Array("pleaseletmein".utf8), salt: Array("SodiumChloride".utf8), n: 16384, r: 8, p: 1, length: 64) == hex("""
            7023bdcb3afd7348461c06cd81fd38ebfda8fbba904f8e3ea9b543f6545da1f2
            d5432955613f0fcf62d49705242a9af9e61e85dc0d651e40dfcf017b45575887
            """))
    }

    @Test func `poly1305 RFC 8439 vector`() {
        let key = hex("85:d6:be:78:57:55:6d:33:7f:44:52:fe:42:d5:06:a8:01:03:80:8a:fb:0d:b2:fd:4a:bf:f6:af:41:49:f5:1b")
        let tag = Poly1305.mac(Array("Cryptographic Forum Research Group".utf8)[...], key: key)
        #expect(tag == hex("a8:06:1d:c1:30:51:36:c6:c2:2b:8b:af:0c:01:27:a9"))
    }

    @Test func `hsalsa20 NaCl core vector`() {
        let shared = hex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
        #expect(Salsa20.hsalsa20(key: shared, nonce: [UInt8](repeating: 0, count: 16))
            == hex("1b27556473e985d462cd51197a9a46c76009549eac6474f206c4ee0844f68389"))
    }

    @Test func `secretbox matches Go x crypto vector`() throws {
        let key = [UInt8](repeating: 1, count: 32), nonce = [UInt8](repeating: 2, count: 24)
        let message = [UInt8](repeating: 3, count: 64)
        let box = SecretBox.seal(message[...], nonce: nonce, key: key)
        #expect(box == hex("""
            8442bc313f4626f1359e3b50122b6ce6fe66ddfe7d39d14e637eb4fd5b45bead
            ab55198df6ab5368439792a23c87db70acb6156dc5ef957ac04f6276cf6093b8
            4be77ff0849cc33e34b7254d5a8f65ad
            """))
        #expect(SecretBox.open(box[...], nonce: nonce, key: key) == message)
        var tampered = box
        tampered[40] ^= 1
        #expect(SecretBox.open(tampered[...], nonce: nonce, key: key) == nil)
    }

    @Test(arguments: [0, 1, 31, 32, 33, 63, 64, 65, 200])
    func `secretbox round trips across keystream block edges`(length: Int) throws {
        let key = Array(randomData(32)), nonce = Array(randomData(24)), message = Array(randomData(length))
        let box = SecretBox.seal(message[...], nonce: nonce, key: key)
        #expect(box.count == length + 16)
        #expect(SecretBox.open(box[...], nonce: nonce, key: key) == message)
    }

    @Test func `EME round trips 1 to 128 blocks`() {
        let key = Array(randomData(32)), tweak = Array(randomData(16))
        for blocks in [1, 2, 3, 16, 127, 128] {
            let plain = Array(randomData(blocks * 16))
            let cipher = EME.transform(key: key, tweak: tweak, plain, encrypt: true)
            #expect(cipher != plain)
            #expect(EME.transform(key: key, tweak: tweak, cipher, encrypt: false) == plain)
        }
    }

    @Test func `base32hex matches RFC 4648 vectors without padding`() {
        let vectors = ["": "", "f": "co", "fo": "cpng", "foo": "cpnmu", "foob": "cpnmuog", "fooba": "cpnmuoj1", "foobar": "cpnmuoj1e8"]
        for (plain, encoded) in vectors {
            #expect(Base32Hex.encode(Array(plain.utf8)) == encoded)
            #expect(Base32Hex.decode(encoded) == Array(plain.utf8))
            #expect(Base32Hex.decode(encoded.uppercased()) == Array(plain.utf8))
        }
        #expect(Base32Hex.decode("c") == nil)
        #expect(Base32Hex.decode("cw") == nil)
    }
}
