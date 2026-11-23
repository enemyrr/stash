import CommonCrypto

/// scrypt (RFC 7914) on PBKDF2-HMAC-SHA256 from CommonCrypto.
enum Scrypt {
    static func derive(password: [UInt8], salt: [UInt8], n: Int, r: Int, p: Int, length: Int) -> [UInt8] {
        precondition(n > 1 && n & (n - 1) == 0, "N must be a power of two")
        let chunkBytes = 128 * r
        var b = pbkdf2(password: password, salt: salt, length: p * chunkBytes)
        for i in 0..<p {
            let range = i * chunkBytes..<(i + 1) * chunkBytes
            b.replaceSubrange(range, with: roMix(Array(b[range]), n: n, r: r))
        }
        return pbkdf2(password: password, salt: b, length: length)
    }

    static func pbkdf2(password: [UInt8], salt: [UInt8], length: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        let status = password.withUnsafeBytes { pw in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), pw.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 1, &out, length)
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return out
    }

    private static func roMix(_ block: [UInt8], n: Int, r: Int) -> [UInt8] {
        let words = 32 * r
        var x = Salsa20.words(block)
        var v = [UInt32](repeating: 0, count: n * words)
        var y = [UInt32](repeating: 0, count: words)
        var t = [UInt32](repeating: 0, count: 16)
        x.withUnsafeMutableBufferPointer { xp in
            v.withUnsafeMutableBufferPointer { vp in
                y.withUnsafeMutableBufferPointer { yp in
                    t.withUnsafeMutableBufferPointer { tp in
                        let x = xp.baseAddress!, v = vp.baseAddress!, y = yp.baseAddress!, t = tp.baseAddress!
                        for i in 0..<n {
                            (v + i * words).update(from: x, count: words)
                            blockMix(x, y, t, r: r)
                        }
                        for _ in 0..<n {
                            let j = Int(x[(2 * r - 1) * 16] & UInt32(n - 1))
                            let vj = v + j * words
                            for k in 0..<words { x[k] ^= vj[k] }
                            blockMix(x, y, t, r: r)
                        }
                    }
                }
            }
        }
        return Salsa20.bytes(x)
    }

    /// BlockMix with Salsa20/8; `y` and `t` are scratch space.
    private static func blockMix(
        _ b: UnsafeMutablePointer<UInt32>, _ y: UnsafeMutablePointer<UInt32>,
        _ t: UnsafeMutablePointer<UInt32>, r: Int
    ) {
        var x = (0..<16).map { b[(2 * r - 1) * 16 + $0] }
        x.withUnsafeMutableBufferPointer { xp in
            let x = xp.baseAddress!
            for i in 0..<(2 * r) {
                for k in 0..<16 { x[k] ^= b[i * 16 + k] }
                t.update(from: x, count: 16)
                Salsa20.doubleRounds(t, count: 4)
                for k in 0..<16 { x[k] &+= t[k] }
                let dest = (i % 2 == 0 ? i / 2 : r + i / 2) * 16
                (y + dest).update(from: x, count: 16)
            }
        }
        b.update(from: y, count: 32 * r)
    }
}
