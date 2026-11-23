/// EME (ECB-Mix-ECB) wide-block mode with AES, ported from github.com/rfjakob/eme.
enum EME {
    /// Transforms 1...128 AES blocks. The tweak must be 16 bytes.
    static func transform(key: [UInt8], tweak: [UInt8], _ input: [UInt8], encrypt: Bool) -> [UInt8] {
        let m = input.count / 16
        precondition(input.count % 16 == 0 && (1...128).contains(m) && tweak.count == 16)
        let aes: ([UInt8]) -> [UInt8] = { encrypt ? AES.encrypt(key: key, $0) : AES.decrypt(key: key, $0) }

        // L_j = 2^j * AES-enc(K, 0); always encrypt, regardless of direction.
        var lTable = [[UInt8]]()
        var l = AES.encrypt(key: key, [UInt8](repeating: 0, count: 16))
        for _ in 0..<m {
            l = double(l)
            lTable.append(l)
        }

        var pp = input
        for j in 0..<m { xor(&pp, at: j * 16, lTable[j]) }
        var c = aes(pp)

        var mp = tweak
        for j in 0..<m { xor(&mp, at: 0, Array(c[j * 16..<j * 16 + 16])) }
        let mc = aes(mp)

        var mask = mp
        xor(&mask, at: 0, mc)
        for j in 1..<m {
            mask = double(mask)
            xor(&c, at: j * 16, mask)
        }

        var ccc1 = mc
        xor(&ccc1, at: 0, tweak)
        for j in 1..<m { xor(&ccc1, at: 0, Array(c[j * 16..<j * 16 + 16])) }
        c.replaceSubrange(0..<16, with: ccc1)

        c = aes(c)
        for j in 0..<m { xor(&c, at: j * 16, lTable[j]) }
        return c
    }

    /// Multiplication by 2 in GF(2^128), little-endian as in rfjakob/eme.
    private static func double(_ block: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        out[0] = (block[0] << 1) ^ (block[15] >> 7 == 1 ? 135 : 0)
        for j in 1..<16 { out[j] = (block[j] << 1) | (block[j - 1] >> 7) }
        return out
    }

    private static func xor(_ target: inout [UInt8], at offset: Int, _ block: [UInt8]) {
        for k in 0..<16 { target[offset + k] ^= block[k] }
    }
}
