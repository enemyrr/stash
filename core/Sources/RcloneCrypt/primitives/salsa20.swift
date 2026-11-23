/// Salsa20 core, HSalsa20 and the XSalsa20 keystream.
enum Salsa20 {
    static let sigma: [UInt32] = [0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574]

    @inline(__always)
    private static func rotl(_ v: UInt32, _ n: UInt32) -> UInt32 { (v << n) | (v >> (32 - n)) }

    @inline(__always)
    private static func quarter(_ x: UnsafeMutablePointer<UInt32>, _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        x[b] ^= rotl(x[a] &+ x[d], 7)
        x[c] ^= rotl(x[b] &+ x[a], 9)
        x[d] ^= rotl(x[c] &+ x[b], 13)
        x[a] ^= rotl(x[d] &+ x[c], 18)
    }

    /// Applies `count` double rounds to the 16-word state in place.
    @inline(__always)
    static func doubleRounds(_ x: UnsafeMutablePointer<UInt32>, count: Int) {
        for _ in 0..<count {
            quarter(x, 0, 4, 8, 12); quarter(x, 5, 9, 13, 1); quarter(x, 10, 14, 2, 6); quarter(x, 15, 3, 7, 11)
            quarter(x, 0, 1, 2, 3); quarter(x, 5, 6, 7, 4); quarter(x, 10, 11, 8, 9); quarter(x, 15, 12, 13, 14)
        }
    }

    /// Builds the 16-word input: constants, 32-byte key and a 16-byte input (nonce + counter).
    static func state(key: [UInt8], input: [UInt8]) -> [UInt32] {
        let k = words(key), n = words(input)
        return [sigma[0], k[0], k[1], k[2], k[3], sigma[1], n[0], n[1],
                n[2], n[3], sigma[2], k[4], k[5], k[6], k[7], sigma[3]]
    }

    /// HSalsa20: derives a 32-byte subkey from a key and a 16-byte nonce.
    static func hsalsa20(key: [UInt8], nonce: [UInt8]) -> [UInt8] {
        var x = state(key: key, input: nonce)
        x.withUnsafeMutableBufferPointer { doubleRounds($0.baseAddress!, count: 10) }
        return bytes([x[0], x[5], x[10], x[15], x[6], x[7], x[8], x[9]])
    }

    static func words(_ bytes: [UInt8]) -> [UInt32] {
        stride(from: 0, to: bytes.count, by: 4).map {
            UInt32(bytes[$0]) | UInt32(bytes[$0 + 1]) << 8 | UInt32(bytes[$0 + 2]) << 16 | UInt32(bytes[$0 + 3]) << 24
        }
    }

    static func bytes(_ words: [UInt32]) -> [UInt8] {
        words.flatMap { w in [UInt8(truncatingIfNeeded: w), UInt8(truncatingIfNeeded: w >> 8),
                              UInt8(truncatingIfNeeded: w >> 16), UInt8(truncatingIfNeeded: w >> 24)] }
    }
}

/// XSalsa20 keystream generator: 64-byte blocks from block counter 0.
struct XSalsa20 {
    private var input: [UInt32]
    private var block = [UInt32](repeating: 0, count: 16)

    init(key: [UInt8], nonce: [UInt8]) {
        precondition(key.count == 32 && nonce.count == 24)
        let subkey = Salsa20.hsalsa20(key: key, nonce: Array(nonce[0..<16]))
        input = Salsa20.state(key: subkey, input: Array(nonce[16..<24]) + [UInt8](repeating: 0, count: 8))
    }

    /// Returns the next 64 keystream bytes and advances the counter.
    mutating func nextBlock() -> [UInt8] {
        generate()
        return block.withUnsafeBytes { Array($0) }
    }

    /// XORs `buffer[start...]` with the keystream from the next block on.
    mutating func xor(_ buffer: inout [UInt8], from start: Int) {
        buffer.withUnsafeMutableBufferPointer { buffer in
            var offset = start
            while offset < buffer.count {
                generate()
                let n = min(64, buffer.count - offset)
                block.withUnsafeBytes { keystream in
                    for i in 0..<n { buffer[offset + i] ^= keystream[i] }
                }
                offset += n
            }
        }
    }

    /// Fills `block` with the next keystream block as little-endian words.
    private mutating func generate() {
        input.withUnsafeBufferPointer { inp in
            block.withUnsafeMutableBufferPointer { out in
                for i in 0..<16 { out[i] = inp[i] }
                Salsa20.doubleRounds(out.baseAddress!, count: 10)
                for i in 0..<16 { out[i] = (out[i] &+ inp[i]).littleEndian }
            }
        }
        input[8] &+= 1
        if input[8] == 0 { input[9] &+= 1 }
    }
}
