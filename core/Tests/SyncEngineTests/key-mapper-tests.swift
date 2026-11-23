import Foundation
import LocalStore
import RcloneCrypt
@testable import S3Client
import SyncEngine
import Testing

struct KeyMapperTests {
	static let cipher = RcloneCipher(password: "test password", password2: "test salt")
	let keys = KeyMapper(cipher: Self.cipher)

	@Test func encryptsEachSegmentAndKeepsDirectorySlash() throws {
		#expect(keys.remoteKey("") == "")
		let dir = keys.remoteKey("Movies/2024/")
		#expect(dir.hasSuffix("/"))
		#expect(try Self.cipher.decryptPath(String(dir.dropLast()), isDirectory: true) == "Movies/2024")
		let file = keys.remoteKey("Movies/2024/clip.mov")
		#expect(file.hasPrefix(dir))
		#expect(try Self.cipher.decryptPath(file) == "Movies/2024/clip.mov")
	}

	@Test func plainKeysPassThroughWithoutCipher() {
		#expect(KeyMapper(cipher: nil).remoteKey("a/b.txt") == "a/b.txt")
	}

	@Test func listingSkipsMarkersAndForeignNamesAndReportsPlainSizes() {
		let prefix = "Movies/"
		let remote = keys.remoteKey(prefix)
		let modified = Date(timeIntervalSince1970: 1_700_000_000)
		let listing = ListResult(
			objects: [
				S3Object(key: remote, size: 0, etag: "marker", lastModified: modified),
				S3Object(
					key: keys.remoteKey("Movies/clip.mov"), size: RcloneCipher.encryptedSize(plainSize: 1000), etag: "e1",
					lastModified: modified),
				S3Object(key: remote + "juicefs_uuid", size: 36, etag: "e2", lastModified: modified),
			],
			commonPrefixes: [keys.remoteKey("Movies/2024/"), remote + "drive/"])
		let listedAt = Date()
		let entries = keys.entries(listing, prefix: prefix, listedAt: listedAt)
		#expect(entries == [
			RemoteEntry(key: "Movies/clip.mov", size: 1000, etag: "e1", mtime: modified),
			RemoteEntry(key: "Movies/2024/", mtime: listedAt),
		])
	}
}
