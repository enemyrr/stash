/// Poly1305 one-time authenticator (poly1305-donna, 26-bit limbs).
enum Poly1305 {
    static func mac(_ message: ArraySlice<UInt8>, key: [UInt8]) -> [UInt8] {
        precondition(key.count == 32)
        let mask: UInt32 = 0x3ff_ffff
        let r0 = le32(key, 0) & 0x3ff_ffff
        let r1 = (le32(key, 3) >> 2) & 0x3ff_ff03
        let r2 = (le32(key, 6) >> 4) & 0x3ff_c0ff
        let r3 = (le32(key, 9) >> 6) & 0x3f0_3fff
        let r4 = (le32(key, 12) >> 8) & 0x00f_ffff
        let s1 = UInt64(r1 * 5), s2 = UInt64(r2 * 5), s3 = UInt64(r3 * 5), s4 = UInt64(r4 * 5)
        let (R0, R1, R2, R3, R4) = (UInt64(r0), UInt64(r1), UInt64(r2), UInt64(r3), UInt64(r4))
        var h0: UInt32 = 0, h1: UInt32 = 0, h2: UInt32 = 0, h3: UInt32 = 0, h4: UInt32 = 0

        func absorb(_ t0: UInt32, _ t1: UInt32, _ t2: UInt32, _ t3: UInt32, hibit: UInt32) {
            h0 &+= t0 & mask
            h1 &+= ((t0 >> 26) | (t1 << 6)) & mask
            h2 &+= ((t1 >> 20) | (t2 << 12)) & mask
            h3 &+= ((t2 >> 14) | (t3 << 18)) & mask
            h4 &+= (t3 >> 8) | hibit

            let H0 = UInt64(h0), H1 = UInt64(h1), H2 = UInt64(h2), H3 = UInt64(h3), H4 = UInt64(h4)
            let d0 = H0 * R0 + H1 * s4 + H2 * s3 + H3 * s2 + H4 * s1
            var d1 = H0 * R1 + H1 * R0 + H2 * s4 + H3 * s3 + H4 * s2
            var d2 = H0 * R2 + H1 * R1 + H2 * R0 + H3 * s4 + H4 * s3
            var d3 = H0 * R3 + H1 * R2 + H2 * R1 + H3 * R0 + H4 * s4
            var d4 = H0 * R4 + H1 * R3 + H2 * R2 + H3 * R1 + H4 * R0

            var c = d0 >> 26; h0 = UInt32(d0 & 0x3ff_ffff)
            d1 += c; c = d1 >> 26; h1 = UInt32(d1 & 0x3ff_ffff)
            d2 += c; c = d2 >> 26; h2 = UInt32(d2 & 0x3ff_ffff)
            d3 += c; c = d3 >> 26; h3 = UInt32(d3 & 0x3ff_ffff)
            d4 += c; c = d4 >> 26; h4 = UInt32(d4 & 0x3ff_ffff)
            h0 &+= UInt32(c) * 5
            let carry = h0 >> 26; h0 &= mask; h1 &+= carry
        }

        message.withUnsafeBytes { raw in
            func word(_ i: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: i, as: UInt32.self).littleEndian }
            var offset = 0
            while raw.count - offset >= 16 {
                absorb(word(offset), word(offset + 4), word(offset + 8), word(offset + 12), hibit: 1 << 24)
                offset += 16
            }
            if offset < raw.count {
                // Final partial block: append 0x01, zero-pad, no high bit.
                var last = [UInt8](repeating: 0, count: 16)
                for i in offset..<raw.count { last[i - offset] = raw[i] }
                last[raw.count - offset] = 1
                let t = Salsa20.words(last)
                absorb(t[0], t[1], t[2], t[3], hibit: 0)
            }
        }

        // Full carry, then compute h - p and select.
        var c = h1 >> 26; h1 &= mask
        h2 &+= c; c = h2 >> 26; h2 &= mask
        h3 &+= c; c = h3 >> 26; h3 &= mask
        h4 &+= c; c = h4 >> 26; h4 &= mask
        h0 &+= c * 5; c = h0 >> 26; h0 &= mask
        h1 &+= c

        var g0 = h0 &+ 5; c = g0 >> 26; g0 &= mask
        var g1 = h1 &+ c; c = g1 >> 26; g1 &= mask
        var g2 = h2 &+ c; c = g2 >> 26; g2 &= mask
        var g3 = h3 &+ c; c = g3 >> 26; g3 &= mask
        var g4 = h4 &+ c &- (1 << 26)

        var select = (g4 >> 31) &- 1
        g0 &= select; g1 &= select; g2 &= select; g3 &= select; g4 &= select
        select = ~select
        h0 = (h0 & select) | g0
        h1 = (h1 & select) | g1
        h2 = (h2 & select) | g2
        h3 = (h3 & select) | g3
        h4 = (h4 & select) | g4

        let w0 = h0 | (h1 << 26)
        let w1 = (h1 >> 6) | (h2 << 20)
        let w2 = (h2 >> 12) | (h3 << 14)
        let w3 = (h3 >> 18) | (h4 << 8)

        var f = UInt64(w0) + UInt64(le32(key, 16))
        let t0 = UInt32(truncatingIfNeeded: f)
        f = UInt64(w1) + UInt64(le32(key, 20)) + (f >> 32)
        let t1 = UInt32(truncatingIfNeeded: f)
        f = UInt64(w2) + UInt64(le32(key, 24)) + (f >> 32)
        let t2 = UInt32(truncatingIfNeeded: f)
        f = UInt64(w3) + UInt64(le32(key, 28)) + (f >> 32)
        let t3 = UInt32(truncatingIfNeeded: f)
        return Salsa20.bytes([t0, t1, t2, t3])
    }

    @inline(__always)
    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
