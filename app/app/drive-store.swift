import AppKit
import Observation

@MainActor @Observable
final class DriveStore {
	private(set) var drives = DriveConfigFile.load()
	/// Where each mounted drive is mounted, read from the mount table.
	private(set) var mountPoints: [UUID: URL] = [:]
	private(set) var mountError: Error?
	private let engine: DriveEngine = S3DriveEngine()
	/// Drives the user ejected, in Stash or in Finder. They stay unmounted until the user mounts them or Stash restarts.
	@ObservationIgnored private var ejected: Set<UUID> = []
	@ObservationIgnored private var mounting: [UUID: Task<Void, Never>] = [:]

	/// FSKit returns EPERM when the module is switched off in System Settings.
	var isExtensionDisabled: Bool {
		guard let error = mountError as NSError? else { return false }
		let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
		return [error, underlying].contains { $0?.domain == NSPOSIXErrorDomain && $0?.code == Int(EPERM) }
	}

	init() {
		let center = NSWorkspace.shared.notificationCenter
		// Finder's Eject and diskutil post willUnmount first. A volume that drops because the module died doesn't.
		center.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { [weak self] note in
			let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
			MainActor.assumeIsolated { self?.willUnmount(url) }
		}
		for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
			center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.refresh() }
			}
		}
		Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.refresh() }
		}
	}

	/// Reads the mount table and remounts drives that dropped without an eject.
	func refresh() {
		let mountPoints = drives.reduce(into: [UUID: URL]()) { $0[$1.id] = engine.mountPoint($1) }
		if mountPoints != self.mountPoints { self.mountPoints = mountPoints }
		ejected.subtract(mountPoints.keys)
		for drive in drives where mountPoints[drive.id] == nil && !ejected.contains(drive.id) {
			keepMounted(drive, immediately: false)
		}
	}

	func add(_ config: DriveConfig, secrets: DriveSecrets) async throws {
		try await engine.validate(config, secrets: secrets)
		try Keychain.save(secrets, for: config.id)
		drives.append(config)
		try DriveConfigFile.save(drives)
		mount(config)
	}

	func remove(_ config: DriveConfig) async {
		await eject(config)
		guard mountPoints[config.id] == nil else { return }
		Keychain.delete(for: config.id)
		drives.removeAll { $0.id == config.id }
		try? DriveConfigFile.save(drives)
		if drives.isEmpty { mountError = nil }
		refresh()
	}

	func mountAll() {
		for drive in drives { keepMounted(drive, immediately: true) }
		refresh()
	}

	func mount(_ config: DriveConfig) {
		ejected.remove(config.id)
		mounting.removeValue(forKey: config.id)?.cancel()
		keepMounted(config, immediately: true)
	}

	func eject(_ config: DriveConfig) async {
		ejected.insert(config.id)
		mounting.removeValue(forKey: config.id)?.cancel()
		do {
			try await engine.unmount(config)
		} catch {
			mountError = error
		}
		refresh()
	}

	private func willUnmount(_ url: URL?) {
		guard let id = mountPoints.first(where: { $0.value.path == url?.path })?.key else { return }
		ejected.insert(id)
		mounting.removeValue(forKey: id)?.cancel()
	}

	/// Mounts the drive, retrying after 2 s, 10 s, 60 s, then every 5 minutes. Retries also cover ExtensionKit failing to
	/// start the module for a few seconds after an update.
	private func keepMounted(_ config: DriveConfig, immediately: Bool) {
		guard mounting[config.id] == nil else { return }
		mounting[config.id] = Task {
			var delays = immediately ? [0, 2, 10, 60] : [2, 10, 60]
			while true {
				try? await Task.sleep(for: .seconds(delays.isEmpty ? 300 : delays.removeFirst()))
				guard !Task.isCancelled, drives.contains(where: { $0.id == config.id }), engine.mountPoint(config) == nil else { break }
				do {
					try await engine.mount(config)
					mountError = nil
					break
				} catch {
					mountError = error
				}
			}
			guard !Task.isCancelled else { return }
			mounting[config.id] = nil
			refresh()
		}
	}
}
