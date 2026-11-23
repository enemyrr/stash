import Foundation
import RcloneCrypt

/// `Stash --import-rclone <rclone.conf> <remote> <name>` adds an S3 or crypt-over-S3 remote as a drive,
/// or updates the drive with that name. Prints no secrets.
enum RcloneImport {
	struct Failure: Error, CustomStringConvertible {
		let description: String
	}

	static func run(_ arguments: [String]) -> Int32 {
		do {
			guard arguments.count == 3 else { throw Failure(description: "usage: --import-rclone <rclone.conf> <remote> <name>") }
			let drive = try importDrive(config: URL(filePath: arguments[0]), remote: arguments[1], name: arguments[2])
			print("Saved drive \(drive.name) (\(drive.id.uuidString)): \(drive.bucket), encrypted: \(drive.encrypted)")
			return 0
		} catch {
			FileHandle.standardError.write(Data("Import failed: \(error)\n".utf8))
			return 1
		}
	}

	private static func importDrive(config: URL, remote: String, name: String) throws -> DriveConfig {
		let sections = try parse(String(contentsOf: config, encoding: .utf8))
		guard var section = sections[remote] else { throw Failure(description: "No remote [\(remote)]") }
		var crypt: [String: String]?
		var bucket = ""
		if section["type"] == "crypt" {
			crypt = section
			let target = section["remote", default: ""].split(separator: ":", maxSplits: 1).map(String.init)
			guard target.count == 2, let s3 = sections[target[0]], !target[1].isEmpty, !target[1].contains("/") else {
				throw Failure(description: "The crypt remote must point at the root of an S3 bucket")
			}
			section = s3
			bucket = target[1]
		}
		guard section["type"] == "s3", let endpoint = section["endpoint"], let accessKey = section["access_key_id"],
			let secretKey = section["secret_access_key"]
		else { throw Failure(description: "The remote needs an S3 endpoint and keys") }
		guard !bucket.isEmpty else { throw Failure(description: "Name a crypt remote over an S3 bucket; plain S3 remotes aren’t supported") }

		var drives = DriveConfigFile.load()
		var drive = drives.first { $0.name == name } ?? DriveConfig(name: name, endpoint: "", bucket: "", encrypted: false)
		drive.endpoint = endpoint.contains("://") ? endpoint : "https://\(endpoint)"
		drive.region = section["region"]
		drive.bucket = bucket
		drive.encrypted = crypt != nil
		drive.filenameEncryption = crypt?["filename_encryption"] ?? "standard"
		drive.directoryNameEncryption = crypt?["directory_name_encryption"] != "false"
		let secrets = DriveSecrets(
			accessKey: accessKey, secretKey: secretKey,
			password: try crypt?["password"].map(RcloneObscure.reveal),
			password2: try crypt?["password2"].map(RcloneObscure.reveal))

		try Keychain.save(secrets, for: drive.id)
		drives.removeAll { $0.id == drive.id }
		drives.append(drive)
		try DriveConfigFile.save(drives)
		return drive
	}

	private static func parse(_ text: String) -> [String: [String: String]] {
		var sections: [String: [String: String]] = [:]
		var current = ""
		for rawLine in text.split(whereSeparator: \.isNewline) {
			let line = rawLine.trimmingCharacters(in: .whitespaces)
			if line.hasPrefix("[") && line.hasSuffix("]") {
				current = String(line.dropFirst().dropLast())
			} else if let separator = line.firstIndex(of: "="), !line.hasPrefix("#"), !line.hasPrefix(";") {
				sections[current, default: [:]][line[..<separator].trimmingCharacters(in: .whitespaces)] =
					line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
			}
		}
		return sections
	}
}
