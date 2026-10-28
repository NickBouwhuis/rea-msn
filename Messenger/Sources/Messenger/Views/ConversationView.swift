import AppKit
import MSNKit
import SwiftUI

/// convframe (msgsres.dll UIFILE 920 / convframess): WLM frame titled with the
/// contact, a toolbar of activities, the history pane, the input area
/// (formatting toolbar + box + Send/Search) and display pictures at the right.
struct ConversationView: View {
	@ObservedObject var convo: ConversationModel
	@EnvironmentObject var app: AppModel
	@State private var showFormat = false
	@State private var showEmoticons = false
	@State private var showInvite = false
	@State private var lastTypingSent = Date.distantPast
	private let s = Skin.shared

	private var contact: Contact? { app.contacts.first { $0.email == convo.peer } ?? app.contact(convo.peer) }
	private var peerName: String { app.name(of: convo.peer) }
	/// "Alice" or, in a group conversation, "Alice, Carol".
	private var title: String {
		convo.participants.count > 1 ? convo.participants.map { app.name(of: $0) }.joined(separator: ", ") : peerName
	}

	var body: some View {
		WLMChrome(title: title, subtitle: convo.participants.count > 1 ? nil : "<\(convo.peer)>") {
			VStack(spacing: 0) {
				activityToolbar
				HStack(alignment: .top, spacing: 8) {
					VStack(spacing: 0) {
						transcript
						statusLine
						composer
					}
					pictures
				}
				.padding(EdgeInsets(top: 4, leading: 8, bottom: 0, trailing: 8))
				HStack {
					Spacer()
					SkinImage(R.gripper)
				}
				.padding(4)
			}
		}
		.onChange(of: title) { _, _ in app.windows.updateTitle(convo.peer) }
	}

	/// Invite / Share Files / Video / Call / Activities / Games / Block.
	private var activityToolbar: some View {
		HStack(spacing: 2) {
			ToolbarIconButton(id: 1441, symbol: "person.badge.plus", help: s.string(60032, "Invite").replacingOccurrences(of: "&", with: "")) {
				showInvite.toggle()
			}
			.popover(isPresented: $showInvite) {
				InvitePicker(candidates: inviteCandidates) { email in
					showInvite = false
					app.invite(email, into: convo.peer)
				}
			}
			ToolbarIconButton(id: 1444, symbol: "folder", help: s.string(60033, "Share files").replacingOccurrences(of: "&", with: "")) {
				shareFiles()
			}
			ToolbarIconButton(id: 1445, symbol: "video", help: s.string(46584, "Video")) {}
			ToolbarIconButton(id: 1447, symbol: "phone", help: s.string(46586, "Call")) {}
			ToolbarIconButton(id: 1442, symbol: "film", help: s.string(61345, "Activities")) {}
			ToolbarIconButton(id: 1443, symbol: "gamecontroller", help: s.string(61346, "Games")) {}
			Spacer(minLength: 0)
			ToolbarIconButton(id: 326, symbol: "nosign", help: s.string(426, "Block")) {
				if let c = contact { app.setBlocked(c.email, !c.isBlocked) }
			}
		}
		.padding(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
	}

	private var transcript: some View {
		ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 4) {
					if convo.lines.isEmpty {
						Text("Never give out your password or credit card number in an instant message conversation.")
							.font(WLMFont.regular()).foregroundStyle(Color(rgb: 0x777777))
					}
					ForEach(convo.lines) { line in
						LineView(line: line).environmentObject(convo).id(line.id)
					}
				}
				.padding(6)
				.frame(maxWidth: .infinity, alignment: .leading)
				.textSelection(.enabled)
			}
			.background(Color.white)
			.overlay(Rectangle().stroke(R.listBorder, lineWidth: 1))
			.onChange(of: convo.lines.count) { _, _ in
				if let last = convo.lines.last { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) } }
			}
		}
	}

	private var statusLine: some View {
		HStack(spacing: 4) {
			if let typing = convo.typingNames.first {
				Text("\(typing) is typing a message.")
			} else if let date = convo.lastReceived {
				Text("Last message received at \(date.formatted(date: .omitted, time: .shortened)) on \(date.formatted(date: .numeric, time: .omitted)).")
			} else {
				Text(" ")
			}
			Spacer()
		}
		.font(WLMFont.regular())
		.foregroundStyle(Color(rgb: 0x777777))
		.padding(.vertical, 3)
	}

	/// inputarea: toolbar (font, emoticons, winks, nudge, voice clip, backgrounds,
	/// colour scheme) above the input box, Send and Search to its right.
	private var composer: some View {
		VStack(spacing: 0) {
			HStack(spacing: 0) {
				ToolbarIconButton(id: 411, symbol: "textformat", help: s.string(60250, "Font")) { showFormat.toggle() }
					.popover(isPresented: $showFormat) { FormatPopover(format: $convo.format) }
				ToolbarIconButton(id: 412, symbol: "face.smiling", help: "Select an emoticon") { showEmoticons.toggle() }
					.popover(isPresented: $showEmoticons) {
						EmoticonPicker { code in
							convo.draft += code
							showEmoticons = false
						}
					}
				ToolbarIconButton(id: 1487, symbol: "sparkles", help: s.string(35598, "Wink")) {}
				ToolbarIconButton(id: 414, symbol: "waveform.path", help: s.string(2195, "Nudge")) { app.nudge(convo.peer) }
				ToolbarIconButton(id: 992, symbol: "mic", help: s.string(41108, "Voice Clip")) {}
				ToolbarIconButton(id: 410, symbol: "photo", help: s.string(60253, "Backgrounds")) {}
				ToolbarIconButton(id: 329, symbol: "paintbrush", help: "Change your color scheme") {}
				Spacer(minLength: 0)
			}
			.padding(1)
			.overlay(Rectangle().stroke(R.listBorder, lineWidth: 1))
			.background(LinearGradient(colors: [.white, Color(rgb: 0xE9F1F5)], startPoint: .top, endPoint: .bottom))

			HStack(alignment: .top, spacing: 6) {
				MessageInput(text: $convo.draft, format: convo.format, onSend: send, onEdit: typed)
					.frame(minHeight: 64, maxHeight: 100)
					.background(Color.white)
					.overlay(Rectangle().stroke(R.listBorder, lineWidth: 1))
				VStack(spacing: 4) {
					Button(s.string(60014, "Send"), action: send)
						.buttonStyle(WLMPushButtonStyle(isDefault: true))
						.disabled(convo.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
					Button(s.string(39703, "Search")) {
						let q = convo.draft.trimmingCharacters(in: .whitespacesAndNewlines)
						if !q.isEmpty, let url = URL(string: "https://duckduckgo.com/?q=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
							NSWorkspace.shared.open(url)
						}
					}
					.buttonStyle(WLMPushButtonStyle())
				}
			}
			.padding(.top, 4)
		}
	}

	/// youusertile (top) and meusertile (bottom), 96pt with the tile border.
	private var pictures: some View {
		VStack {
			if convo.participants.count <= 1 {
				UserTile(seed: convo.peer, picture: app.displayPicture(of: convo.peer))
			}
			Spacer()
			UserTile(seed: app.myEmail, picture: app.displayPicture(of: app.myEmail))
				.padding(.bottom, 4)
		}
		.frame(width: 104)
	}

	/// Online contacts not yet in the conversation.
	private var inviteCandidates: [Contact] {
		app.contacts.filter { $0.status.isOnline && !convo.participants.contains($0.email) }
	}

	private func shareFiles() {
		let panel = NSOpenPanel()
		panel.title = s.string(2110, "Send a File to %1").replacingOccurrences(of: "%1", with: title)
		panel.allowsMultipleSelection = true
		panel.canChooseDirectories = false
		guard panel.runModal() == .OK else { return }
		app.sendFiles(panel.urls, to: convo.peer)
	}

	private func send() {
		let text = convo.draft
		convo.draft = ""
		app.send(text, to: convo.peer)
		lastTypingSent = .distantPast
	}

	/// WLM re-sends the TypingUser control message about every 5 seconds while typing.
	private func typed() {
		guard !convo.draft.isEmpty, Date().timeIntervalSince(lastTypingSent) > 4.5 else { return }
		lastTypingSent = Date()
		app.userIsTyping(to: convo.peer)
	}
}

private struct LineView: View {
	let line: ChatLine
	@EnvironmentObject var app: AppModel
	@EnvironmentObject var convo: ConversationModel

	var body: some View {
		switch line.kind {
		case let .message(_, senderName, text, format, _):
			VStack(alignment: .leading, spacing: 1) {
				(Emoticons.text(senderName, enabled: app.settings.convertEmoticons) + Text(" says:"))
					.font(WLMFont.regular())
					.foregroundStyle(Color(rgb: 0x777777))
				AnimatedEmoticonText(text: text, enabled: app.settings.convertEmoticons)
					.font(font(format))
					.foregroundStyle(color(format))
					.underline(format.underline)
					.strikethrough(format.strikethrough)
					.padding(.leading, 12)
					.fixedSize(horizontal: false, vertical: true)
			}
		case let .nudge(name, outgoing):
			Text(outgoing ? "You have just sent a nudge." : "\(name) just sent you a nudge.")
				.font(WLMFont.bold())
				.foregroundStyle(R.text)
				.padding(.vertical, 2)
		case let .notice(text):
			Text(text).font(WLMFont.regular()).foregroundStyle(Color(rgb: 0x777777))
		case let .failed(text, reason):
			VStack(alignment: .leading, spacing: 1) {
				Text("The following message could not be delivered to all recipients:")
					.font(.system(size: 11)).foregroundStyle(.red)
				Text(text).font(.system(size: 12)).foregroundStyle(WLM.muted).padding(.leading, 12)
				Text(reason).font(.system(size: 10)).foregroundStyle(WLM.muted).padding(.leading, 12)
			}
		case let .offline(_, senderName, text, sent):
			VStack(alignment: .leading, spacing: 1) {
				(Emoticons.text(senderName, enabled: app.settings.convertEmoticons) + Text(saysWhen(sent)))
					.font(WLMFont.regular())
					.foregroundStyle(Color(rgb: 0x777777))
				AnimatedEmoticonText(text: text, enabled: app.settings.convertEmoticons)
					.font(.system(size: 13))
					.padding(.leading, 12)
					.fixedSize(horizontal: false, vertical: true)
			}
		case let .file(id):
			if let t = convo.transfers[id] { TransferRow(transfer: t) }
		case let .wink(senderName, image):
			VStack(alignment: .leading, spacing: 2) {
				Text(Skin.shared.string(2345, "%1 winks:").replacingOccurrences(of: "%1", with: senderName))
					.font(WLMFont.regular()).foregroundStyle(Color(rgb: 0x777777))
				if let image, let ns = NSImage(data: image) {
					Image(nsImage: ns).interpolation(.high).resizable().aspectRatio(contentMode: .fit)
						.frame(maxWidth: 120, maxHeight: 120, alignment: .leading)
						.padding(.leading, 12)
				}
			}
		}
	}

	/// "%1 says (%3):" with the time it was sent, for offline messages.
	private func saysWhen(_ sent: Date?) -> String {
		let template = Skin.shared.string(2042, "%1 says (%3):")
		let when = sent.map { "\($0.formatted(date: .numeric, time: .shortened))" } ?? "offline"
		return String(template.replacingOccurrences(of: "%3", with: when).drop { $0 != " " })
	}

	private func font(_ f: TextFormat) -> Font {
		var font = Font.custom(f.fontName == "Segoe UI" ? NSFont.systemFont(ofSize: 13).fontName : f.fontName, size: 13)
		if NSFont(name: f.fontName, size: 13) == nil { font = .system(size: 13) }
		if f.bold { font = font.bold() }
		if f.italic { font = font.italic() }
		return font
	}

	private func color(_ f: TextFormat) -> Color {
		Color(red: Double((f.color >> 16) & 0xFF) / 255, green: Double((f.color >> 8) & 0xFF) / 255, blue: Double(f.color & 0xFF) / 255)
	}
}

private struct FormatPopover: View {
	@Binding var format: TextFormat
	private let fonts = ["Segoe UI", "Arial", "Comic Sans MS", "Courier New", "Georgia", "Tahoma", "Times New Roman", "Trebuchet MS", "Verdana"]
	private let colors: [UInt32] = [0x000000, 0x1F3864, 0x0070C0, 0x00B050, 0xC00000, 0xFF6600, 0x7030A0, 0xFF0099, 0x808080]

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Picker("Font", selection: $format.fontName) {
				ForEach(fonts, id: \.self) { Text($0).tag($0) }
			}
			HStack {
				Toggle("Bold", isOn: $format.bold)
				Toggle("Italic", isOn: $format.italic)
				Toggle("Underline", isOn: $format.underline)
			}
			.toggleStyle(.checkbox)
			HStack(spacing: 6) {
				ForEach(colors, id: \.self) { c in
					Circle()
						.fill(Color(red: Double(c >> 16) / 255, green: Double((c >> 8) & 0xFF) / 255, blue: Double(c & 0xFF) / 255))
						.frame(width: 16, height: 16)
						.overlay(Circle().stroke(format.color == c ? Color.accentColor : .clear, lineWidth: 2))
						.onTapGesture { format.color = c }
				}
			}
		}
		.font(.system(size: 11))
		.padding(12)
		.onChange(of: format) { _, f in ConversationModel.savedFormat = f }
	}
}

private struct EmoticonPicker: View {
	let pick: (String) -> Void
	private let columns = Array(repeating: GridItem(.fixed(26), spacing: 4), count: 8)

	var body: some View {
		LazyVGrid(columns: columns, spacing: 4) {
			if Skin.shared.emoticons.isEmpty {
				ForEach(Emoticons.picker, id: \.0) { code, emoji in
					Button { pick(code) } label: { Text(emoji).font(.system(size: 18)) }
						.buttonStyle(.plain)
						.help(code)
				}
			} else {
				ForEach(Emoticons.skinPicker, id: \.code) { item in
					Button { pick(item.code) } label: { Image(nsImage: item.image).interpolation(.none).frame(width: 22, height: 22) }
						.buttonStyle(.plain)
						.help(item.name.map { "\($0) \(item.code)" } ?? item.code)
				}
			}
		}
		.padding(8)
	}
}

/// NSTextView wrapper: Return sends, Shift/Option-Return inserts a newline.
private struct MessageInput: NSViewRepresentable {
	@Binding var text: String
	let format: TextFormat
	let onSend: () -> Void
	let onEdit: () -> Void

	func makeNSView(context: Context) -> NSScrollView {
		let scroll = NSTextView.scrollableTextView()
		scroll.drawsBackground = false
		scroll.hasVerticalScroller = true
		let tv = scroll.documentView as! NSTextView
		tv.delegate = context.coordinator
		tv.isRichText = false
		tv.allowsUndo = true
		tv.drawsBackground = false
		tv.textContainerInset = NSSize(width: 2, height: 4)
		tv.isAutomaticQuoteSubstitutionEnabled = false
		tv.isAutomaticDashSubstitutionEnabled = false
		DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
		return scroll
	}

	func updateNSView(_ scroll: NSScrollView, context: Context) {
		context.coordinator.parent = self
		guard let tv = scroll.documentView as? NSTextView else { return }
		if tv.string != text { tv.string = text }
		var font = NSFont(name: format.fontName, size: 13) ?? .systemFont(ofSize: 13)
		if format.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
		if format.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
		tv.font = font
		tv.textColor = NSColor(red: CGFloat((format.color >> 16) & 0xFF) / 255, green: CGFloat((format.color >> 8) & 0xFF) / 255,
		                       blue: CGFloat(format.color & 0xFF) / 255, alpha: 1)
	}

	func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

	final class Coordinator: NSObject, NSTextViewDelegate {
		var parent: MessageInput
		init(parent: MessageInput) { self.parent = parent }

		func textDidChange(_ notification: Notification) {
			guard let tv = notification.object as? NSTextView else { return }
			parent.text = tv.string
			parent.onEdit()
		}

		func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
			if selector == #selector(NSResponder.insertNewline(_:)) {
				let flags = NSApp.currentEvent?.modifierFlags ?? []
				if flags.contains(.shift) || flags.contains(.option) {
					textView.insertNewlineIgnoringFieldEditor(nil)
				} else {
					parent.onSend()
				}
				return true
			}
			return false
		}
	}
}

/// A file transfer in the transcript: WLM's invitation text, progress, and its
/// Accept/Decline/Cancel (or Open) links.
private struct TransferRow: View {
	let transfer: FileTransfer
	@EnvironmentObject var app: AppModel

	var body: some View {
		VStack(alignment: .leading, spacing: 3) {
			Text(transfer.text(peerName: app.name(of: transfer.peer)) { Skin.shared.string($0, $1) })
				.font(WLMFont.regular())
				.foregroundStyle(R.text)
				.fixedSize(horizontal: false, vertical: true)
			if transfer.state == .transferring {
				ProgressView(value: transfer.progress).frame(maxWidth: 220)
			}
			HStack(spacing: 10) {
				switch transfer.state {
				case .offered:
					link(Skin.shared.string(2052, "Accept")) { app.acceptFile(transfer) }
					link(Skin.shared.string(2053, "Decline")) { app.declineFile(transfer) }
				case .waiting, .transferring:
					link(Skin.shared.string(2054, "Cancel")) { app.cancelFile(transfer) }
				case .completed where transfer.incoming:
					link("Open") { app.openFile(transfer) }
					link("Show in Finder") { app.revealFile(transfer) }
				default:
					EmptyView()
				}
			}
		}
		.padding(.vertical, 2)
	}

	private func link(_ title: String, _ action: @escaping () -> Void) -> some View {
		Button(title, action: action).buttonStyle(.link).font(WLMFont.regular())
	}
}

/// The Invite button's list: online contacts who aren't in the conversation yet.
private struct InvitePicker: View {
	let candidates: [Contact]
	let pick: (String) -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text("Invite someone to this conversation:").font(WLMFont.bold()).padding(.bottom, 4)
			if candidates.isEmpty {
				Text("None of your other contacts are online.").font(WLMFont.regular()).foregroundStyle(WLM.muted)
			}
			ForEach(candidates) { c in
				Button { pick(c.email) } label: {
					HStack(spacing: 6) {
						StatusIcon(presence: c.status)
						Text(c.displayName).font(WLMFont.regular()).lineLimit(1)
					}
					.frame(maxWidth: .infinity, alignment: .leading)
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.padding(.vertical, 2)
			}
		}
		.padding(10)
		.frame(minWidth: 220, alignment: .leading)
	}
}
