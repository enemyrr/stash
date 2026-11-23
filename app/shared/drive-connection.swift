import Foundation
import RcloneCrypt
import S3Client
import SyncEngine

extension DriveConfig {
	struct InvalidEndpoint: LocalizedError {
		var errorDescription: String? { "Enter the endpoint as a URL, like https://hel1.your-objectstorage.com." }
	}

	func s3Config(_ secrets: DriveSecrets) throws -> S3Config {
		guard let url = URL(string: endpoint), ["https", "http"].contains(url.scheme), let host = url.host() else {
			throw InvalidEndpoint()
		}
		return S3Config(
			endpoint: url, region: region ?? String(host.split(separator: ".").first ?? ""), bucket: bucket,
			accessKeyId: secrets.accessKey, secretAccessKey: secrets.secretKey)
	}

	/// Builds the rclone crypt cipher (scrypt, tens of milliseconds) when the drive is encrypted.
	func keyMapper(_ secrets: DriveSecrets) -> KeyMapper {
		guard encrypted else { return KeyMapper(cipher: nil) }
		return KeyMapper(cipher: RcloneCipher(
			password: secrets.password ?? "", password2: secrets.password2 ?? "",
			filenameEncryption: RcloneCipher.FilenameEncryption(rawValue: filenameEncryption) ?? .standard,
			directoryNameEncryption: directoryNameEncryption))
	}

	/// The drive's local metadata and file cache, in the shared app group container.
	var storeURL: URL {
		DriveConfigFile.url.deletingLastPathComponent()
			.appending(path: "Library/Application Support/Drives/\(id.uuidString)", directoryHint: .isDirectory)
	}
}
