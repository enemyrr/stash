import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	let store = DriveStore()

	lazy var window: NSWindow = {
		let window = NSWindow(contentViewController: NSHostingController(rootView: DrivesView(store: store)))
		window.title = "Stash"
		window.isReleasedWhenClosed = false
		window.center()
		return window
	}()

	func applicationDidFinishLaunching(_ notification: Notification) {
		let launch = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)
		if store.drives.isEmpty || launch?.enumCodeValue != keyAELaunchedAsLogInItem { showWindow() }
		Task { await store.mountAll() }
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
