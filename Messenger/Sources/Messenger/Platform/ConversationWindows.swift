import AppKit
import SwiftUI

/// One AppKit window per conversation, so incoming messages can open windows
/// without stealing focus and nudges can shake the frame (as WLM does).
@MainActor
final class ConversationWindows: NSObject, NSWindowDelegate {
	private unowned let app: AppModel
	private var windows: [String: NSWindow] = [:]

	init(app: AppModel) {
		self.app = app
	}

	func isOpen(_ peer: String) -> Bool { windows[peer] != nil }
	func isKey(_ peer: String) -> Bool { windows[peer]?.isKeyWindow == true && NSApp.isActive }

	func show(_ convo: ConversationModel, activate: Bool) {
		if let w = windows[convo.peer] {
			if activate {
				w.makeKeyAndOrderFront(nil)
				NSApp.activate(ignoringOtherApps: true)
			} else if !w.isVisible || w.isMiniaturized {
				w.orderFront(nil)
			}
			return
		}
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
			styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
			backing: .buffered, defer: false
		)
		window.contentView = NSHostingView(rootView: ConversationView(convo: convo).environmentObject(app))
		window.minSize = NSSize(width: 430, height: 420)
		window.titleVisibility = .hidden
		window.titlebarAppearsTransparent = true
		window.title = app.name(of: convo.peer)
		window.isReleasedWhenClosed = false
		window.delegate = self
		window.identifier = NSUserInterfaceItemIdentifier(convo.peer)
		window.setFrameAutosaveName("Conversation")
		if windows.isEmpty == false, let last = windows.values.first {
			window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
		} else if window.frame.origin == .zero {
			window.center()
		}
		windows[convo.peer] = window
		if activate {
			window.makeKeyAndOrderFront(nil)
			NSApp.activate(ignoringOtherApps: true)
		} else {
			window.orderFront(nil)
		}
	}

	func updateTitle(_ peer: String) {
		windows[peer]?.title = app.name(of: peer)
	}

	/// Nudge: a quick horizontal/vertical jitter of the window frame.
	func shake(_ peer: String) {
		guard let window = windows[peer] else { return }
		let origin = window.frame.origin
		let offsets: [(CGFloat, CGFloat)] = [(-8, 4), (8, -4), (-7, -5), (7, 5), (-5, 3), (5, -3), (-3, 2), (3, -2), (0, 0)]
		Task {
			for (dx, dy) in offsets {
				window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
				try? await Task.sleep(nanoseconds: 35_000_000)
			}
			window.setFrameOrigin(origin)
		}
	}

	func closeAll() {
		for w in windows.values { w.delegate = nil; w.close() }
		windows.removeAll()
	}

	func windowWillClose(_ notification: Notification) {
		guard let w = notification.object as? NSWindow, let peer = w.identifier?.rawValue else { return }
		windows[peer] = nil
		app.conversationClosed(peer)
	}
}
