import AppKit
import MSNKit
import SwiftUI

/// Palette sampled from the WLM 8.1 default (blue) theme.
enum WLM {
	static let titleTop = Color(red: 0.29, green: 0.52, blue: 0.80)
	static let titleBottom = Color(red: 0.13, green: 0.36, blue: 0.66)
	static let bannerTop = Color(red: 0.84, green: 0.91, blue: 0.98)
	static let bannerBottom = Color(red: 0.64, green: 0.78, blue: 0.94)
	static let paleBlue = Color(red: 0.91, green: 0.95, blue: 0.99)
	static let selection = Color(red: 0.79, green: 0.87, blue: 0.97)
	static let border = Color(red: 0.55, green: 0.67, blue: 0.82)
	static let ink = Color(red: 0.12, green: 0.22, blue: 0.36)
	static let groupInk = Color(red: 0.12, green: 0.26, blue: 0.47)
	static let muted = Color(red: 0.45, green: 0.50, blue: 0.58)
	static let link = Color(red: 0.0, green: 0.36, blue: 0.75)

	static var banner: LinearGradient {
		LinearGradient(colors: [bannerTop, bannerBottom], startPoint: .top, endPoint: .bottom)
	}

	static var window: LinearGradient {
		LinearGradient(colors: [Color(red: 0.95, green: 0.97, blue: 1.0), paleBlue], startPoint: .top, endPoint: .bottom)
	}
}

extension Presence.Tint {
	var colors: [Color] {
		switch self {
		case .green: return [Color(red: 0.55, green: 0.86, blue: 0.27), Color(red: 0.19, green: 0.60, blue: 0.10)]
		case .red: return [Color(red: 0.98, green: 0.42, blue: 0.36), Color(red: 0.75, green: 0.10, blue: 0.08)]
		case .orange: return [Color(red: 1.0, green: 0.78, blue: 0.30), Color(red: 0.90, green: 0.52, blue: 0.05)]
		case .gray: return [Color(red: 0.80, green: 0.82, blue: 0.85), Color(red: 0.52, green: 0.55, blue: 0.60)]
		}
	}
}

/// The Messenger "buddy": a glossy figure tinted by status, with a small
/// badge for Busy/Away as in WLM 8.x.
struct BuddyGlyph: View {
	let presence: Presence
	var size: CGFloat = 16

	var body: some View {
		ZStack(alignment: .bottomTrailing) {
			Image(systemName: "person.fill")
				.resizable()
				.scaledToFit()
				.foregroundStyle(LinearGradient(colors: presence.tint.colors, startPoint: .top, endPoint: .bottom))
				.shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
				.frame(width: size, height: size)
			if let badge {
				Image(systemName: badge)
					.resizable()
					.scaledToFit()
					.foregroundStyle(.white, presence.tint.colors[1])
					.frame(width: size * 0.5, height: size * 0.5)
					.offset(x: size * 0.12, y: size * 0.08)
			}
		}
		.frame(width: size, height: size)
		.accessibilityLabel(presence.displayName)
	}

	private var badge: String? {
		switch presence {
		case .busy, .onThePhone: return "minus.circle.fill"
		case .away, .beRightBack, .outToLunch, .idle: return "clock.fill"
		case .appearOffline, .offline: return nil
		case .online: return nil
		}
	}
}

/// Default display picture: WLM shipped stock tiles; this draws an original
/// tile whose colour is derived from the contact's address.
struct DisplayPicture: View {
	let seed: String
	var size: CGFloat = 48
	var presence: Presence? = nil

	var body: some View {
		// FNV-1a: String.hashValue is randomised per launch.
		let hash = seed.lowercased().utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
		let hue = Double(hash % 360) / 360
		ZStack {
			RoundedRectangle(cornerRadius: size * 0.12)
				.fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.35, brightness: 0.98), Color(hue: hue, saturation: 0.65, brightness: 0.78)],
				                     startPoint: .topLeading, endPoint: .bottomTrailing))
			Image(systemName: "person.fill")
				.resizable()
				.scaledToFit()
				.foregroundStyle(.white.opacity(0.92))
				.padding(size * 0.2)
				.offset(y: size * 0.08)
				.clipShape(RoundedRectangle(cornerRadius: size * 0.12))
		}
		.frame(width: size, height: size)
		.padding(3)
		.background(
			RoundedRectangle(cornerRadius: size * 0.16)
				.fill(LinearGradient(colors: frameColors, startPoint: .top, endPoint: .bottom))
		)
		.overlay(RoundedRectangle(cornerRadius: size * 0.16).stroke(.white.opacity(0.7), lineWidth: 1))
		.shadow(color: .black.opacity(0.18), radius: 2, y: 1)
	}

	private var frameColors: [Color] {
		guard let presence else { return [.white, Color(white: 0.85)] }
		return presence.tint.colors
	}
}

/// Status picker used in the sign-in window and the contact list header.
/// SwiftUI's `Menu` flattens custom labels on macOS, so this pops a real NSMenu.
struct StatusMenu<Label: View>: View {
	let current: Presence
	let pick: (Presence) -> Void
	@ViewBuilder let label: () -> Label

	var body: some View {
		Button {
			let menu = NSMenu()
			for p in Presence.selectable {
				let item = ClosureMenuItem(title: p.displayName) { pick(p) }
				item.state = p == current ? .on : .off
				item.image = Skin.shared.image(R.statusPill, frame: StatusIcon(presence: p).frame)
					?? NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)?
						.withSymbolConfiguration(.init(paletteColors: [NSColor(p.tint.colors[1])]))
				menu.addItem(item)
			}
			let mouse = NSEvent.mouseLocation
			menu.popUp(positioning: nil, at: NSPoint(x: mouse.x - 8, y: mouse.y - 6), in: nil)
		} label: {
			label().contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}
}

final class ClosureMenuItem: NSMenuItem {
	private let handler: () -> Void

	init(title: String, handler: @escaping () -> Void) {
		self.handler = handler
		super.init(title: title, action: #selector(fire), keyEquivalent: "")
		target = self
	}

	@available(*, unavailable)
	required init(coder: NSCoder) { fatalError() }

	@objc private func fire() { handler() }
}

/// Click-to-edit text, used for the display name and personal message.
struct InlineEditable: View {
	let text: String
	let placeholder: String
	var font: Font = .system(size: 12)
	var color: Color = WLM.ink
	let commit: (String) -> Void
	@State private var editing = false
	@State private var draft = ""
	@FocusState private var focused: Bool

	var body: some View {
		if editing {
			TextField(placeholder, text: $draft)
				.textFieldStyle(.plain)
				.font(font)
				.padding(.horizontal, 3)
				.background(RoundedRectangle(cornerRadius: 2).fill(.white).overlay(RoundedRectangle(cornerRadius: 2).stroke(WLM.border)))
				.focused($focused)
				.onSubmit { finish() }
				.onExitCommand { editing = false }
				.onChange(of: focused) { _, f in if !f { finish() } }
				.onAppear { draft = text; focused = true }
		} else {
			(text.isEmpty ? Text(placeholder) : Emoticons.text(text, enabled: AppModel.shared.settings.convertEmoticons))
				.font(text.isEmpty ? font.italic() : font)
				.foregroundStyle(text.isEmpty ? WLM.muted : color)
				.lineLimit(1)
				.truncationMode(.tail)
				.contentShape(Rectangle())
				.onTapGesture { editing = true }
				.help("Click to edit")
		}
	}

	private func finish() {
		guard editing else { return }
		editing = false
		commit(draft.trimmingCharacters(in: .whitespaces))
	}
}

struct WLMButtonStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.font(.system(size: 12))
			.foregroundStyle(WLM.ink)
			.padding(.horizontal, 14)
			.padding(.vertical, 4)
			.background(
				RoundedRectangle(cornerRadius: 3)
					.fill(LinearGradient(colors: configuration.isPressed ? [WLM.bannerBottom, WLM.bannerTop] : [.white, WLM.bannerTop],
					                     startPoint: .top, endPoint: .bottom))
			)
			.overlay(RoundedRectangle(cornerRadius: 3).stroke(WLM.border, lineWidth: 1))
	}
}
