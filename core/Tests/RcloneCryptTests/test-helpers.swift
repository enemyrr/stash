import Foundation
@testable import RcloneCrypt

func hex(_ string: String) -> [UInt8] {
    let chars = Array(string.filter { !$0.isWhitespace && $0 != ":" })
    return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0 + 1]), radix: 16)! }
}

func randomData(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
}

/// Ciphers are expensive (scrypt), so tests share them.
enum SharedCiphers {
    static let zeroKey = RcloneCipher(password: "")
    static let zeroKeyBase64 = RcloneCipher(password: "", filenameEncoding: .base64)
    static let zeroKeyObfuscate = RcloneCipher(password: "", filenameEncryption: .obfuscate)
}

/// Runs the rclone binary against a throwaway config. Uses `STASH_TEST_RCLONE`, else the first `rclone` on `PATH`.
struct Rclone: Sendable {
    static let binary: URL? = {
        let env = ProcessInfo.processInfo.environment
        let candidates = env["STASH_TEST_RCLONE"].map { [$0] }
            ?? (env["PATH"] ?? "").split(separator: ":").map { "\($0)/rclone" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(filePath: $0) }
    }()
    static var isAvailable: Bool { binary != nil }

    let config: URL

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @discardableResult
    func run(_ arguments: [String]) throws -> Data {
        try Self.run(["--config", config.path] + arguments)
    }

    func lines(_ arguments: [String]) throws -> [String] {
        String(decoding: try run(arguments), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast().map(String.init)
    }

    /// Uses posix_spawn: Foundation's `Process` converts arguments to NFD, which changes names.
    @discardableResult
    static func run(_ arguments: [String]) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory
        let stdout = tmp.appending(path: "rclone-out-\(UUID().uuidString)")
        let stderr = tmp.appending(path: "rclone-err-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: stdout)
            try? FileManager.default.removeItem(at: stderr)
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, stdout.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_addopen(&actions, 2, stderr.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)

        guard let binary else { throw Failure(description: "rclone binary not found") }
        let argv = ([binary.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, binary.path, &actions, nil, argv, environ)
        guard spawned == 0 else { throw Failure(description: "posix_spawn failed: \(spawned)") }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        guard status == 0 else {
            throw Failure(description: "rclone \(arguments.dropFirst(2).first ?? ""): " + (try String(contentsOf: stderr, encoding: .utf8)))
        }
        return try Data(contentsOf: stdout)
    }
}
