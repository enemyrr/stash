import FSKit
import LocalStore
import S3Client

/// Loads a drive's volume. The resource is the app's per-drive directory, named by the drive's id.
@objc
final class StashFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
	struct UnknownDrive: Error {}

	private var volume: StashVolume?

	func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
		guard let drive = Self.drive(for: resource) else { return replyHandler(.notRecognized, nil) }
		replyHandler(.usable(name: drive.name, containerID: FSContainerIdentifier(uuid: drive.id)), nil)
	}

	func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
		do {
			guard let drive = Self.drive(for: resource) else { throw UnknownDrive() }
			let secrets = try Keychain.load(for: drive.id)
			try FileManager.default.createDirectory(at: drive.storeURL, withIntermediateDirectories: true)
			let store = try LocalStore(directory: drive.storeURL)
			let volume = StashVolume(
				config: drive, store: store, client: S3Client(config: try drive.s3Config(secrets)), keys: drive.keyMapper(secrets))
			self.volume = volume
			containerStatus = .ready
			replyHandler(volume, nil)
		} catch {
			StashVolume.log.error("Loading the drive failed: \(String(describing: error), privacy: .public)")
			replyHandler(nil, error)
		}
	}

	func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping ((any Error)?) -> Void) {
		volume?.engine.stop()
		volume = nil
		replyHandler(nil)
	}

	private static func drive(for resource: FSResource) -> DriveConfig? {
		guard let url = (resource as? FSPathURLResource)?.url, let id = UUID(uuidString: url.lastPathComponent) else {
			return nil
		}
		return DriveConfigFile.load().first { $0.id == id }
	}
}
