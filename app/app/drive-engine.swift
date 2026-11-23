import AppKit
import FSKit
import S3Client

/// The seam the S3 engine implements.
protocol DriveEngine {
	/// Throws if the bucket can't be reached with these credentials.
	func validate(_ config: DriveConfig, secrets: DriveSecrets) async throws
	func mount(_ config: DriveConfig) async throws
	func unmount(_ config: DriveConfig) async throws
	/// Where the drive is mounted, read from the mount table.
	func mountPoint(_ config: DriveConfig) -> URL?
}

/// Checks credentials against the bucket and mounts drives through the FSKit module, which runs the sync engine.
struct S3DriveEngine: DriveEngine {
	struct Invalid: LocalizedError {
		let errorDescription: String?
	}

	/// Lists one object with the given keys.
	func validate(_ config: DriveConfig, secrets: DriveSecrets) async throws {
		if config.encrypted, secrets.password?.isEmpty ?? true {
			throw Invalid(errorDescription: "Enter a password to encrypt files.")
		}
		do {
			_ = try await S3Client(config: config.s3Config(secrets)).listObjectsV2(maxKeys: 1)
		} catch let error as S3Error {
			let message = switch error {
			case .network: "Can’t reach \(config.endpoint)."
			case .accessDenied: "The bucket rejected these keys."
			case .http(404, _, _): "There’s no bucket named “\(config.bucket)”."
			default: "The bucket returned an error: \(error)."
			}
			throw Invalid(errorDescription: message)
		}
	}

	func mount(_ config: DriveConfig) async throws {
		let url = resourceURL(config)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		let resource = FSPathURLResource(url: url, writable: true)
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			FSClient.shared.mountSingleVolume(resource: resource, bundleID: "\(stashBundleID).fsmodule", options: []) { _, error in
				if let error { continuation.resume(throwing: error) } else { continuation.resume() }
			}
		}
	}

	func unmount(_ config: DriveConfig) async throws {
		// unmount(2) returns EPERM for FSKit volumes; NSWorkspace goes through Disk Arbitration like Finder's Eject.
		guard let url = mountPoint(config) else { return }
		try NSWorkspace.shared.unmountAndEjectDevice(at: url)
	}

	private func resourceURL(_ config: DriveConfig) -> URL {
		URL.applicationSupportDirectory.appending(path: "\(stashBundleID)/\(config.id.uuidString)", directoryHint: .isDirectory)
	}

	func mountPoint(_ config: DriveConfig) -> URL? {
		// FSKit records the resource as a file URL, e.g. file:///…/<bundle id>/<id>/.
		let resource = resourceURL(config).absoluteString
		var mounts: UnsafeMutablePointer<statfs>?
		let count = Int(getmntinfo(&mounts, MNT_NOWAIT))
		return UnsafeBufferPointer(start: mounts, count: count).lazy
			.first { withUnsafeBytes(of: $0.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } == resource }
			.map { withUnsafeBytes(of: $0.f_mntonname) { URL(filePath: String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self), directoryHint: .isDirectory) } }
	}
}
