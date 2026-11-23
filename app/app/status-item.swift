import AppKit

/// The menu bar icon. The menu is built from the store each time it opens.
@MainActor
final class StatusItem: NSObject, NSMenuDelegate {
	private let store: DriveStore
	private let openSettings: () -> Void
	private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

	init(store: DriveStore, openSettings: @escaping () -> Void) {
		self.store = store
		self.openSettings = openSettings
		super.init()
		let menu = NSMenu()
		menu.delegate = self
		item.menu = menu
		updateIcon()
	}

	private func updateIcon() {
		let symbol = withObservationTracking {
			if store.drives.isEmpty { "externaldrive" }
			else if store.drives.allSatisfy({ store.mountPoints[$0.id] != nil }) { "externaldrive.fill" }
			else { "externaldrive.badge.xmark" }
		} onChange: { [weak self] in
			Task { @MainActor in self?.updateIcon() }
		}
		item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Stash")
	}

	func menuNeedsUpdate(_ menu: NSMenu) {
		store.refresh()
		menu.removeAllItems()
		for drive in store.drives {
			let mountPoint = store.mountPoints[drive.id]
			menu.addItem(withTitle: "\(drive.name) — \(mountPoint == nil ? "Not mounted" : "Mounted")", action: nil, keyEquivalent: "")
			if let mountPoint {
				menu.addItem(ActionItem("Eject") { Task { await self.store.eject(drive) } })
				menu.addItem(ActionItem("Open in Finder") { NSWorkspace.shared.open(mountPoint) })
			} else {
				menu.addItem(ActionItem("Mount") { self.store.mount(drive) })
			}
			menu.addItem(.separator())
		}
		if store.drives.isEmpty {
			menu.addItem(ActionItem("Add Drive…", handler: openSettings))
			menu.addItem(.separator())
		} else {
			menu.addItem(ActionItem("Settings…", key: ",", handler: openSettings))
		}
		menu.addItem(ActionItem("Quit Stash", key: "q") { NSApp.terminate(nil) })
	}
}

private final class ActionItem: NSMenuItem {
	private let handler: () -> Void

	init(_ title: String, key: String = "", handler: @escaping () -> Void) {
		self.handler = handler
		super.init(title: title, action: #selector(run), keyEquivalent: key)
		target = self
	}

	required init(coder: NSCoder) { fatalError() }

	@objc private func run() { handler() }
}
