/// NaCl `crypto_secretbox` (XSalsa20-Poly1305). Box layout: tag(16) || ciphertext.
enum SecretBox {
    static let overhead = 16

    static func seal(_ message: ArraySlice<UInt8>, nonce: [UInt8], key: [UInt8]) -> [UInt8] {
        var stream = XSalsa20(key: key, nonce: nonce)
        let first = stream.nextBlock()
        var box = [UInt8](repeating: 0, count: overhead) + message
        let head = min(32, message.count)
        for i in 0..<head { box[overhead + i] ^= first[32 + i] }
        stream.xor(&box, from: overhead + head)
        box.replaceSubrange(0..<overhead, with: Poly1305.mac(box[overhead...], key: Array(first[0..<32])))
        return box
    }

    /// Returns nil when the box is too short or fails authentication.
    static func open(_ box: ArraySlice<UInt8>, nonce: [UInt8], key: [UInt8]) -> [UInt8]? {
        guard box.count >= overhead else { return nil }
        var stream = XSalsa20(key: key, nonce: nonce)
        let first = stream.nextBlock()
        let tagEnd = box.startIndex + overhead
        let tag = Poly1305.mac(box[tagEnd...], key: Array(first[0..<32]))
        var diff: UInt8 = 0
        for i in 0..<overhead { diff |= tag[i] ^ box[box.startIndex + i] }
        guard diff == 0 else { return nil }
        var message = Array(box[tagEnd...])
        let head = min(32, message.count)
        for i in 0..<head { message[i] ^= first[32 + i] }
        stream.xor(&message, from: head)
        return message
    }
}
