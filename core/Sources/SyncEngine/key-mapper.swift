import Foundation
import LocalStore
import RcloneCrypt
import S3Client

/// Maps the store's plain keys to bucket keys, through rclone crypt when the drive is encrypted.
public struct KeyMapper: Sendable {
	public let cipher: RcloneCipher?

	public init(cipher: RcloneCipher?) {
		self.cipher = cipher
	}

	/// Directory keys keep their trailing `/`. The root key `""` stays empty.
	public func remoteKey(_ key: String) -> String {
		guard let cipher, !key.isEmpty else { return key }
		if key.hasSuffix("/") { return cipher.encryptPath(String(key.dropLast()), isDirectory: true) + "/" }
		return cipher.encryptPath(key)
	}

	/// Converts a delimited listing of the directory with plain key `prefix`.
	/// Skips the directory's own marker and names that don't decrypt, such as objects written without rclone crypt.
	public func entries(_ listing: ListResult, prefix: String, listedAt: Date) -> [RemoteEntry] {
		let remotePrefix = remoteKey(prefix)
		var entries: [RemoteEntry] = []
		for object in listing.objects where object.key != remotePrefix {
			guard let name = plainName(object.key, remotePrefix: remotePrefix, isDirectory: false),
				let size = plainSize(object.size)
			else { continue }
			entries.append(RemoteEntry(key: prefix + name, size: size, etag: object.etag, mtime: object.lastModified))
		}
		for commonPrefix in listing.commonPrefixes {
			guard let name = plainName(String(commonPrefix.dropLast()), remotePrefix: remotePrefix, isDirectory: true)
			else { continue }
			entries.append(RemoteEntry(key: prefix + name + "/", mtime: listedAt))
		}
		return entries
	}

	private func plainName(_ key: String, remotePrefix: String, isDirectory: Bool) -> String? {
		guard key.utf8.starts(with: remotePrefix.utf8) else { return nil }
		let name = String(decoding: key.utf8.dropFirst(remotePrefix.utf8.count), as: UTF8.self)
		guard !name.isEmpty, !name.contains("/") else { return nil }
		guard let cipher else { return name }
		return try? cipher.decryptName(name, isDirectory: isDirectory)
	}

	private func plainSize(_ size: Int64) -> Int64? {
		cipher == nil ? size : try? RcloneCipher.plainSize(encryptedSize: size)
	}
}
