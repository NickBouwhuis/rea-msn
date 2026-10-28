import AppKit
import SwiftUI

/// The "Verify this session" dialog as its own small window (the contact
/// list is too narrow for a sheet), shown while AppModel.verification is set.
@MainActor
final class VerificationWindow: NSObject, NSWindowDelegate {
	private unowned let app: AppModel
	private var window: NSWindow?

	init(app: AppModel) {
		self.app = app
	}

	func update() {
		guard app.verification != nil else {
			window?.delegate = nil
			window?.close()
			window = nil
			return
		}
		if let window {
			window.orderFront(nil)
			return
		}
		let controller = NSHostingController(rootView: VerificationView().environmentObject(app))
		controller.sizingOptions = [.preferredContentSize]
		let w = NSWindow(contentViewController: controller)
		w.styleMask = [.titled, .closable]
		w.title = "Windows Live Messenger"
		w.isReleasedWhenClosed = false
		w.delegate = self
		w.center()
		window = w
		w.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
	}

	func windowWillClose(_ notification: Notification) {
		window = nil
		app.closeVerification()
	}
}
