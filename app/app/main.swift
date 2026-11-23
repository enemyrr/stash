import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	let store = DriveStore()
	private var statusItem: StatusItem?

	lazy var window: NSWindow = {
		let window = NSWindow(contentViewController: NSHostingController(rootView: DrivesView(store: store)))
		window.title = "Stash"
		window.isReleasedWhenClosed = false
		window.center()
		return window
	}()

	func applicationDidFinishLaunching(_ notification: Notification) {
		statusItem = StatusItem(store: store) { [unowned self] in showWindow() }
		if store.drives.isEmpty { showWindow() }
		store.mountAll()
		// Opens Stash at login, once. Turning it off in Login Items sticks.
		if !UserDefaults.standard.bool(forKey: "loginItemRegistered") {
			try? SMAppService.mainApp.register()
			UserDefaults.standard.set(true, forKey: "loginItemRegistered")
		}
	}

	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		showWindow()
		return false
	}

	private func showWindow() {
		NSApp.activate()
		window.makeKeyAndOrderFront(nil)
	}
}

if let index = CommandLine.arguments.firstIndex(of: "--import-rclone") {
	exit(RcloneImport.run(Array(CommandLine.arguments.dropFirst(index + 1))))
}

MainActor.assumeIsolated {
	let delegate = AppDelegate()
	NSApplication.shared.delegate = delegate
	NSApplication.shared.run()
}
