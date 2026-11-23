import Foundation
import Security

/// Non-secret drive settings, stored as JSON in the shared app group container.
struct DriveConfig: Codable, Identifiable, Hashable {
	var id = UUID()
	var name: String
	var endpoint: String
	/// Signing region. `nil` uses the endpoint's first host label, as in hel1.your-objectstorage.com.
	var region: String?
	var bucket: String
	var encrypted: Bool
	var filenameEncryption = "standard"
	var directoryNameEncryption = true
}

/// Drive credentials, stored in the Keychain access group shared with the FSKit module.
struct DriveSecrets: Codable, Equatable {
	var accessKey: String
	var secretKey: String
	var password: String?
	/// rclone crypt's salt password. `nil` uses rclone's built-in salt.
	var password2: String?
}

/// `STASH_BUNDLE_ID` from the build settings. The module's bundle ID adds `.fsmodule`.
let stashBundleID = Bundle.main.object(forInfoDictionaryKey: "StashBundleID") as! String
/// Both the app group and the Keychain access group use this identifier.
let sharedGroup = Bundle.main.object(forInfoDictionaryKey: "StashAppGroup") as! String

enum DriveConfigFile {
	static var url: URL {
		guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sharedGroup) else {
			preconditionFailure("Missing app group entitlement \(sharedGroup)")
		}
		return container.appending(path: "drives.json")
	}

	static func load() -> [DriveConfig] {
		guard let data = try? Data(contentsOf: url) else { return [] }
		return (try? JSONDecoder().decode([DriveConfig].self, from: data)) ?? []
	}

	static func save(_ drives: [DriveConfig]) throws {
		try JSONEncoder().encode(drives).write(to: url, options: .atomic)
	}
}

enum Keychain {
	struct Failure: LocalizedError {
		let status: OSStatus
		var errorDescription: String? { SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)" }
	}

	private static func query(_ id: UUID) -> [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: "\(stashBundleID).drive",
			kSecAttrAccount as String: id.uuidString,
			kSecAttrAccessGroup as String: sharedGroup,
			kSecUseDataProtectionKeychain as String: true,
		]
	}

	static func save(_ secrets: DriveSecrets, for id: UUID) throws {
		delete(for: id)
		var item = query(id)
		item[kSecValueData as String] = try JSONEncoder().encode(secrets)
		item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
		let status = SecItemAdd(item as CFDictionary, nil)
		guard status == errSecSuccess else { throw Failure(status: status) }
	}

	static func load(for id: UUID) throws -> DriveSecrets {
		var item = query(id)
		item[kSecReturnData as String] = true
		item[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: CFTypeRef?
		let status = SecItemCopyMatching(item as CFDictionary, &result)
		guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
		return try JSONDecoder().decode(DriveSecrets.self, from: data)
	}

	static func delete(for id: UUID) {
		SecItemDelete(query(id) as CFDictionary)
	}
}
