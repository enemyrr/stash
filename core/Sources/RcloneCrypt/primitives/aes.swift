import CommonCrypto

/// AES via CommonCrypto. Only ECB over whole blocks; modes are built on top.
enum AES {
    static func encrypt(key: [UInt8], _ blocks: [UInt8]) -> [UInt8] {
        ecb(CCOperation(kCCEncrypt), key: key, blocks)
    }

    static func decrypt(key: [UInt8], _ blocks: [UInt8]) -> [UInt8] {
        ecb(CCOperation(kCCDecrypt), key: key, blocks)
    }

    /// AES-CTR as in Go's `cipher.NewCTR`: the whole 16-byte IV is a big-endian counter.
    static func ctr(key: [UInt8], iv: [UInt8], _ input: [UInt8]) -> [UInt8] {
        let blockCount = (input.count + 15) / 16
        var counters = [UInt8]()
        counters.reserveCapacity(blockCount * 16)
        var counter = iv
        for _ in 0..<blockCount {
            counters += counter
            for i in stride(from: 15, through: 0, by: -1) {
                counter[i] &+= 1
                if counter[i] != 0 { break }
            }
        }
        let keystream = encrypt(key: key, counters)
        return zip(input, keystream).map { $0 ^ $1 }
    }

    private static func ecb(_ operation: CCOperation, key: [UInt8], _ input: [UInt8]) -> [UInt8] {
        precondition(input.count % 16 == 0 && [16, 24, 32].contains(key.count))
        let count = input.count
        var output = [UInt8](repeating: 0, count: count)
        var moved = 0
        let status = CCCrypt(
            operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
            key, key.count, nil, input, count, &output, count, &moved)
        precondition(status == kCCSuccess && moved == count, "CCCrypt failed: \(status)")
        return output
    }
}
