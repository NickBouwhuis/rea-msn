import AppKit
import MSNKit
import SwiftUI

/// A skin resource image at its natural size, or `fallback` without a skin.
struct SkinImage<Fallback: View>: View {
	let id: Int
	var frame = 0
	@ViewBuilder var fallback: () -> Fallback

	init(_ id: Int, frame: Int = 0, @ViewBuilder fallback: @escaping () -> Fallback) {
		self.id = id
		self.frame = frame
		self.fallback = fallback
	}

	var body: some View {
		if let img = Skin.shared.image(id, frame: frame) {
			Image(nsImage: img).interpolation(.none)
		} else {
			fallback()
		}
	}
}

extension SkinImage where Fallback == EmptyView {
	init(_ id: Int, frame: Int = 0) {
		self.init(id, frame: frame) { EmptyView() }
	}
}

/// Stretches a skin image (nine-slice when it has cap insets) to fill.
struct SkinFill: View {
	let id: Int
	var fallback: AnyShapeStyle = AnyShapeStyle(Color.clear)

	var body: some View {
		if let img = Skin.shared.image(id) {
			Image(nsImage: img)
				.resizable(capInsets: Skin.shared.insets(id) ?? EdgeInsets(), resizingMode: .stretch)
				.interpolation(.none)
		} else if let fill = Skin.shared.fill(id) {
			Rectangle().fill(fill)
		} else {
			Rectangle().fill(fallback)
		}
	}
}

// MARK: - Window chrome

/// WLM's own frame (logonFrame/mainwnd "header" + "vapor" + window bar with
/// FLW frame buttons). The macOS title bar and traffic lights are hidden.
struct WLMChrome<Content: View>: View {
	var showLogo = true
	/// Conversation windows show WindowText/WindowSubText instead of the logo.
	var title: String? = nil
	var subtitle: String? = nil
	@ViewBuilder var content: () -> Content
	@State private var window: NSWindow?

	var body: some View {
		ZStack(alignment: .top) {
			R.windowBackground
			SkinFill(id: R.header, fallback: AnyShapeStyle(LinearGradient(
				colors: [Color(rgb: 0x063878), Color(rgb: 0x347FA2), Color(rgb: 0xA6C8D4), R.windowBackground],
				startPoint: .top, endPoint: .bottom)))
				.frame(height: R.headerHeight)
			HStack {
				Spacer()
				SkinImage(R.vapor)
			}
			.allowsHitTesting(false)
			VStack(spacing: 0) {
				windowBar
				content()
			}
		}
		.background(WindowAccessor { w in
			window = w
			configure(w)
		})
		.ignoresSafeArea()
	}

	private var windowBar: some View {
		HStack(alignment: .top, spacing: 0) {
			SkinImage(R.windowIcon) { BuddyGlyph(presence: .online, size: 16) }
				.padding(EdgeInsets(top: 8, leading: 7, bottom: 4, trailing: 4))
			if let title {
				HStack(spacing: 4) {
					Emoticons.text(title).font(WLMFont.bold()).foregroundStyle(.white).lineLimit(1)
					if let subtitle {
						Text(subtitle).font(WLMFont.regular()).foregroundStyle(Color.white.opacity(0.75)).lineLimit(1)
					}
				}
				.padding(EdgeInsets(top: 10, leading: 0, bottom: 6, trailing: 4))
			} else if showLogo {
				SkinImage(R.logo) {
					Text("Windows Live Messenger").font(WLMFont.regular(12)).foregroundStyle(.white)
				}
				.padding(EdgeInsets(top: 9, leading: 0, bottom: 2, trailing: 4))
			}
			Spacer(minLength: 0)
			HStack(spacing: 0) {
				FrameButton(id: R.minBtn, symbol: "minus") { window?.miniaturize(nil) }
				FrameButton(id: R.maxBtn, symbol: "square") { window?.zoom(nil) }
				FrameButton(id: R.closeBtn, symbol: "xmark") { window?.performClose(nil) }
			}
			.padding(EdgeInsets(top: 5, leading: 0, bottom: 0, trailing: 5))
		}
		.frame(height: 30)
		.contentShape(Rectangle())
		.gesture(TapGesture(count: 2).onEnded { window?.zoom(nil) })
	}

	private func configure(_ w: NSWindow) {
		w.titleVisibility = .hidden
		w.titlebarAppearsTransparent = true
		w.styleMask.insert(.fullSizeContentView)
		w.isMovableByWindowBackground = true
		for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
			w.standardWindowButton(b)?.isHidden = true
		}
		w.backgroundColor = NSColor(R.windowBackground)
	}
}

/// FLWMinBtn/FLWMaxBtn/FLWCloseBtn: three-frame images (normal, hover, pressed),
/// half transparent when the window is inactive.
struct FrameButton: View {
	let id: Int
	let symbol: String
	let action: () -> Void
	@State private var hover = false
	@State private var pressed = false
	@Environment(\.controlActiveState) private var active

	var body: some View {
		SkinImage(id, frame: pressed ? 2 : (hover ? 1 : 0)) {
			Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
		}
		.padding(3)
		.opacity(active == .inactive && !hover ? 0.5 : 1)
		.contentShape(Rectangle())
		.onHover { hover = $0 }
		.gesture(DragGesture(minimumDistance: 0)
			.onChanged { _ in pressed = true }
			.onEnded { _ in pressed = false; action() })
	}
}

/// Gives SwiftUI content access to its hosting NSWindow.
struct WindowAccessor: NSViewRepresentable {
	let callback: (NSWindow) -> Void

	func makeNSView(context: Context) -> NSView {
		let v = HookView()
		v.callback = callback
		return v
	}

	func updateNSView(_ nsView: NSView, context: Context) {}

	final class HookView: NSView {
		var callback: ((NSWindow) -> Void)?

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if let window { callback?(window) }
		}
	}
}

// MARK: - Controls

/// Button[Class="PushButton"]: nine-slice backgrounds 20093–20096,
/// padding (6,5,6,6), min width 72, text #001563.
struct WLMPushButtonStyle: ButtonStyle {
	var isDefault = false
	@State private var hover = false

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.font(WLMFont.regular())
			.foregroundStyle(R.buttonText)
			.padding(EdgeInsets(top: 5, leading: 6, bottom: 6, trailing: 6))
			.frame(minWidth: 72)
			.background(Hovering(
				id: configuration.isPressed ? R.pushButtonPressed : (isDefault ? R.pushButtonDefault : R.pushButton),
				hoverID: configuration.isPressed ? R.pushButtonPressed : R.pushButtonHover))
	}

	private struct Hovering: View {
		let id: Int
		let hoverID: Int
		@State private var hover = false

		var body: some View {
			SkinFill(id: hover ? hoverID : id, fallback: AnyShapeStyle(LinearGradient(colors: [.white, Color(rgb: 0xDCE7F2)], startPoint: .top, endPoint: .bottom)))
				.overlay {
					if Skin.shared.image(id) == nil { RoundedRectangle(cornerRadius: 3).stroke(Color(rgb: 0x7F9DB9)) }
				}
				.onHover { hover = $0 }
		}
	}
}

/// Checkbox[Class="CheckBox"] with icons 20031 (off) / 20035 (on).
struct WLMCheckbox: View {
	let title: String
	@Binding var isOn: Bool
	var enabled = true

	var body: some View {
		Button {
			isOn.toggle()
		} label: {
			HStack(spacing: 3) {
				SkinImage(isOn ? R.checkboxChecked : R.checkbox) {
					Image(systemName: isOn ? "checkmark.square" : "square").font(.system(size: 12))
				}
				Text(title).font(WLMFont.regular()).foregroundStyle(enabled ? R.text : Color(rgb: 0xC1C1C1))
			}
			.padding(.vertical, 2)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.disabled(!enabled)
	}
}

/// urlelem[class="CommonLink"]: #0088E4, underlined on hover.
struct WLMLink: View {
	let title: String
	let action: () -> Void
	@State private var hover = false

	var body: some View {
		Button(action: action) {
			Text(title).font(WLMFont.regular()).foregroundStyle(Color(rgb: 0x0088E4)).underline(hover)
		}
		.buttonStyle(.plain)
		.onHover { hover = $0 }
		.padding(2)
	}
}

/// CBInput: white, 1px #AAB7C7 border, padding (4,3,4,3).
struct WLMTextFieldStyle: TextFieldStyle {
	func _body(configuration: TextField<Self._Label>) -> some View {
		configuration
			.textFieldStyle(.plain)
			.font(WLMFont.regular(13))
			.padding(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
			.background(Color.white)
			.overlay(Rectangle().stroke(Color(rgb: 0xAAB7C7), lineWidth: 1))
	}
}

/// Status pill strip 46611: 0 online, 1 offline, 2 busy, 3 away, 11/12 blocked.
struct StatusIcon: View {
	let presence: Presence
	var blocked = false

	var frame: Int {
		if blocked { return presence.isOnline ? 11 : 12 }
		switch presence.tint {
		case .green: return 0
		case .gray: return 1
		case .red: return 2
		case .orange: return 3
		}
	}

	var body: some View {
		SkinImage(R.statusPill, frame: frame) { BuddyGlyph(presence: presence, size: 15) }
	}
}

/// usertileview inside idUserTileBorder: 1px #D8D9D9 border, 2px white padding.
struct UserTile: View {
	let seed: String
	var size: CGFloat = 96

	var body: some View {
		Group {
			if let img = Skin.shared.image(size > 64 ? R.defaultTileLarge : R.defaultTileSmall) {
				Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
			} else {
				DisplayPicture(seed: seed, size: size - 6)
			}
		}
		.padding(2)
		.background(Color.white)
		.overlay(Rectangle().stroke(R.tileBorder, lineWidth: 1))
	}
}

/// TransparentDropdownButton: no chrome until hovered (20201) / pressed (20202).
struct TransparentHover<Content: View>: View {
	@ViewBuilder var content: () -> Content
	@State private var hover = false

	var body: some View {
		content()
			.background { if hover { SkinFill(id: R.hoverBackground, fallback: AnyShapeStyle(Color.white.opacity(0.5))) } }
			.onHover { hover = $0 }
	}
}
