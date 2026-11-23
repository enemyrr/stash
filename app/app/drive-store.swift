import Foundation
import Observation

@MainActor @Observable
final class DriveStore {
	private(set) var drives = DriveConfigFile.load()
	private(set) var mounted: Set<UUID> = []
	private(set) var mountError: Error?
	private let engine: DriveEngine = S3DriveEngine()

	/// FSKit returns EPERM when the module is switched off in System Settings.
	var isExtensionDisabled: Bool {
		guard let error = mountError as NSError? else { return false }
		let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
		return [error, underlying].contains { $0?.domain == NSPOSIXErrorDomain && $0?.code == Int(EPERM) }
	}

	func refresh() {
		mounted = Set(drives.filter(engine.isMounted).map(\.id))
	}

	func add(_ config: DriveConfig, secrets: DriveSecrets) async throws {
		try await engine.validate(config, secrets: secrets)
		try Keychain.save(secrets, for: config.id)
		drives.append(config)
		try DriveConfigFile.save(drives)
		await mount(config)
	}

	func remove(_ config: DriveConfig) async {
		do {
			try await engine.unmount(config)
		} catch {
			mountError = error
			return
		}
		Keychain.delete(for: config.id)
		drives.removeAll { $0.id == config.id }
		try? DriveConfigFile.save(drives)
		if drives.isEmpty { mountError = nil }
		refresh()
	}

	func mountAll() async {
		for drive in drives where !engine.isMounted(drive) { await mount(drive) }
		refresh()
	}

	/// Right after an update, ExtensionKit can fail to start the new module for a few seconds, so that error is retried.
	private func mount(_ config: DriveConfig) async {
		for attempt in 1...4 {
			do {
				try await engine.mount(config)
				mountError = nil
				break
			} catch {
				mountError = error
				guard (error as NSError).domain == "com.apple.extensionKit.errorDomain", attempt < 4 else { break }
				try? await Task.sleep(for: .seconds(3))
			}
		}
		refresh()
	}
}
