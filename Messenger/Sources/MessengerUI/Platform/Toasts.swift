import AppKit
import SwiftUI

/// WLM-style "toast" popups that slide up from the bottom-right corner.
@MainActor
final class ToastCenter {
	private var panels: [NSPanel] = []

	func show(title: String, body: String, peer: String, onClick: @escaping () -> Void) {
		let size = NSSize(width: 220, height: 104)
		let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
		                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
		panel.isFloatingPanel = true
		panel.level = .statusBar
		panel.backgroundColor = .clear
		panel.isOpaque = false
		panel.hasShadow = true
		panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
		panel.contentView = NSHostingView(rootView: ToastView(title: title, message: body) { [weak self, weak panel] in
			onClick()
			if let panel { self?.dismiss(panel) }
		} close: { [weak self, weak panel] in
			if let panel { self?.dismiss(panel) }
		})

		guard let screen = NSScreen.main?.visibleFrame else { return }
		let stackOffset = CGFloat(panels.count) * (size.height + 6)
		let finalOrigin = NSPoint(x: screen.maxX - size.width - 12, y: screen.minY + 12 + stackOffset)
		panel.setFrameOrigin(NSPoint(x: finalOrigin.x, y: finalOrigin.y - 40))
		panel.alphaValue = 0
		panel.orderFrontRegardless()
		panels.append(panel)
		NSAnimationContext.runAnimationGroup { ctx in
			ctx.duration = 0.25
			panel.animator().alphaValue = 1
			panel.animator().setFrameOrigin(finalOrigin)
		}
		Task { [weak self, weak panel] in
			try? await Task.sleep(nanoseconds: 5_000_000_000)
			if let panel { self?.dismiss(panel) }
		}
	}

	private func dismiss(_ panel: NSPanel) {
		guard panels.contains(panel) else { return }
		panels.removeAll { $0 === panel }
		NSAnimationContext.runAnimationGroup({ ctx in
			ctx.duration = 0.3
			panel.animator().alphaValue = 0
		}, completionHandler: {
			panel.orderOut(nil)
		})
	}
}

/// MsgrToastRoot (UIFILE 921): the frame gradient strip, Messenger icon and
/// logo, then the contact's tile and the alert text.
private struct ToastView: View {
	let title: String
	let message: String
	let tap: () -> Void
	let close: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(spacing: 4) {
				SkinImage(R.windowIcon) { BuddyGlyph(presence: .online, size: 13) }
					.scaleEffect(0.8)
				SkinImage(R.logo) {
					Text("Windows Live Messenger").font(WLMFont.bold(10)).foregroundStyle(.white)
				}
				.scaleEffect(0.85, anchor: .leading)
				Spacer()
				Button(action: close) {
					SkinImage(R.closeBtn) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white) }
				}
				.buttonStyle(.plain)
			}
			.padding(.horizontal, 5)
			.frame(height: 24)
			.background { SkinFill(id: R.header, fallback: AnyShapeStyle(Color(rgb: 0x063878))).frame(height: 120, alignment: .top).clipped() }

			HStack(alignment: .top, spacing: 8) {
				UserTile(seed: title, size: 40)
				VStack(alignment: .leading, spacing: 2) {
					Text(title).font(WLMFont.bold()).foregroundStyle(R.text).lineLimit(1)
					Emoticons.text(message).font(WLMFont.regular()).foregroundStyle(R.text).lineLimit(3)
				}
				Spacer(minLength: 0)
			}
			.padding(8)
			.frame(maxHeight: .infinity, alignment: .top)
		}
		.background(R.windowBackground)
		.overlay(Rectangle().stroke(Color(rgb: 0x7F9DB9), lineWidth: 1))
		.contentShape(Rectangle())
		.onTapGesture(perform: tap)
	}
}
