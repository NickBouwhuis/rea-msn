import CGtk
import Foundation
import MSNKit

/// convframe (UIFILE 920): WLM frame titled with the contact, activity
/// toolbar, history, formatting toolbar + input + Send/Search, display pictures.
@MainActor
final class ConversationWindow {
	let peer: String
	var peerName: String?
	private let window: Ptr
	private var titleBox: Ptr?
	private let history: Ptr
	private let buffer: UnsafeMutablePointer<GtkTextBuffer>
	private let input: Ptr
	private let status: Ptr
	private let content: Ptr
	private var typingUntil = Date.distantPast
	private var lastTypingSent = Date.distantPast
	private let skin = Skin.shared
	private let state = AppState.shared
	private var format = TextFormat()

	init(peer: String) {
		self.peer = peer
		let name = AppState.shared.name(of: peer)
		let (w, t) = Chrome.window(app: AppState.shared.app, width: 560, height: 520, title: name, subtitle: "<\(peer)>")
		window = w
		titleBox = t

		content = vbox(0)

		let activities = hbox(2)
		margins(activities, top: 2, start: 8, bottom: 2, end: 8)
		for (id, tip) in R.activity { append(activities, button(picture(Skin.shared.image(id)), css: ["wlm-flat"], tooltip: tip) {}) }
		append(activities, spacer())
		append(content, activities)

		let body = hbox(8)
		margins(body, top: 4, start: 8, end: 8)
		expand(body, v: true)
		let left = vbox(0)
		expand(left, h: true)

		history = raw(gtk_text_view_new())
		gtk_text_view_set_editable(c(history), 0)
		gtk_text_view_set_cursor_visible(c(history), 0)
		gtk_text_view_set_wrap_mode(c(history), GTK_WRAP_WORD_CHAR)
		gtk_text_view_set_left_margin(c(history), 6)
		gtk_text_view_set_top_margin(c(history), 6)
		buffer = gtk_text_view_get_buffer(c(history))!
		let historyScroll = scrolled(history, css: ["wlm-history"])
		append(left, historyScroll)

		status = label(" ", css: ["wlm-status"])
		append(left, status)

		let formatBar = hbox(0, css: ["wlm-formatbar"])
		append(left, formatBar)

		let inputRow = hbox(6)
		margins(inputRow, top: 0)
		input = raw(gtk_text_view_new())
		gtk_text_view_set_wrap_mode(c(input), GTK_WRAP_WORD_CHAR)
		let inputScroll = scrolled(input, css: ["wlm-composer"])
		gtk_widget_set_size_request(c(inputScroll), -1, 70)
		gtk_widget_set_vexpand(c(inputScroll), 0)
		append(inputRow, inputScroll)
		let sendCol = vbox(4)
		append(inputRow, sendCol)
		append(left, inputRow)
		append(body, left)

		let pictures = vbox(0)
		append(pictures, Self.tile(Skin.shared))
		append(pictures, spacer(v: true))
		let me = Self.tile(Skin.shared)
		margins(me, bottom: 4)
		append(pictures, me)
		append(body, pictures)
		append(content, body)

		let footer = hbox(0)
		append(footer, spacer())
		append(footer, picture(Skin.shared.image(R.gripper)))
		margins(footer, top: 4, start: 4, bottom: 4, end: 4)
		append(content, footer)
		gtk_window_set_child(c(window), c(content))

		// Wiring that needs self.
		for (id, tip) in R.format {
			append(formatBar, button(picture(skin.image(id)), css: ["wlm-flat"], tooltip: tip) { [weak self] in
				guard let self else { return }
				switch id {
				case 414: AppState.shared.nudge(self.peer)
				case 412: self.showEmoticons(anchor: formatBar)
				default: break
				}
			})
		}
		append(sendCol, button(label: skin.string(60014, "Send"), css: ["wlm-push", "default"]) { [weak self] in self?.send() })
		append(sendCol, button(label: skin.string(39703, "Search"), css: ["wlm-push"]) {})
		keyController(input) { [weak self] keyval, state in
			guard let self else { return false }
			let enter = keyval == 0xff0d || keyval == 0xff8d
			if enter, state & 1 == 0 {  // GDK_SHIFT_MASK
				self.send()
				return true
			}
			return false
		}
		on(raw(gtk_text_view_get_buffer(c(input))), "changed") { [weak self] in self?.typed() }
		onBool(window, "close-request") { [weak self] in
			if let self { AppState.shared.conversationClosed(self.peer) }
			return false
		}
		every(1000) { [weak self] in
			guard let self else { return false }
			if Date() > self.typingUntil, gtk_label_get_text(c(self.status)).map({ String(cString: $0) })?.hasSuffix("is typing a message.") == true {
				setText(self.status, " ")
			}
			return true
		}
		insert("Never give out your password or credit card number in an instant message conversation.\n", markup: false, muted: true)
	}

	private static func tile(_ skin: Skin) -> Ptr {
		let p = picture(skin.image(R.defaultTileLarge), size: (96, 96))
		expand(p)
		let frame = hbox(0, [p], css: ["wlm-tile"])
		expand(frame)
		return frame
	}

	var isActive: Bool { gtk_window_is_active(c(window)) != 0 }

	func present() { gtk_window_present(c(window)) }
	func close() { gtk_window_destroy(c(window)) }

	func refreshHeader() {
		let name = state.name(of: peer)
		gtk_window_set_title(c(window), name)
		if let titleBox, let first = gtk_widget_get_first_child(c(titleBox)) {
			gtk_box_remove(c(titleBox), first)
			gtk_box_prepend(c(titleBox), c(RichText.line(name, css: ["wlm-title"])))
		}
	}

	// MARK: Transcript

	func post(_ kind: ChatLine.Kind) {
		switch kind {
		case let .message(sender, text, fmt, outgoing):
			insertEmoticonText("\(sender) says:", style: "foreground=\"#777777\"")
			insert("\n", markup: false)
			var attrs = "foreground=\"#\(String(format: "%06X", fmt.color))\""
			if fmt.bold { attrs += " weight=\"bold\"" }
			if fmt.italic { attrs += " style=\"italic\"" }
			if fmt.underline { attrs += " underline=\"single\"" }
			insert("    ", markup: false)
			insertEmoticonText(text, style: attrs)
			insert("\n", markup: false)
			if !outgoing { setText(status, "Last message received at \(Self.time.string(from: Date())).") }
		case let .nudge(name, outgoing):
			insert("<b>\(pangoEscape(outgoing ? "You have just sent a nudge." : "\(name) just sent you a nudge."))</b>\n", markup: true)
		case let .notice(text):
			insert(text + "\n", markup: false, muted: true)
		case let .failed(text, reason):
			insert("<span foreground=\"#CC0000\">The following message could not be delivered to all recipients:</span>\n", markup: true)
			insert("    \(text)\n    \(reason)\n", markup: false, muted: true)
		}
		scrollToEnd()
	}

	private static let time: DateFormatter = {
		let f = DateFormatter()
		f.dateFormat = "HH:mm 'on' dd/MM/yyyy"
		return f
	}()

	private func insert(_ s: String, markup: Bool, muted: Bool = false) {
		var end = GtkTextIter()
		gtk_text_buffer_get_end_iter(buffer, &end)
		if markup {
			gtk_text_buffer_insert_markup(buffer, &end, s, -1)
		} else if muted {
			gtk_text_buffer_insert_markup(buffer, &end, "<span foreground=\"#777777\">\(pangoEscape(s))</span>", -1)
		} else {
			gtk_text_buffer_insert(buffer, &end, s, -1)
		}
	}

	/// Inserts text with WLM emoticons as inline images: stills as paintables,
	/// animated ones as pictures that play from when they're first shown.
	private func insertEmoticonText(_ s: String, style: String) {
		for (piece, index) in RichText.tokens(s) {
			var end = GtkTextIter()
			gtk_text_buffer_get_end_iter(buffer, &end)
			if let index, let anim = skin.emoticonAnimations[index], let frames = Self.frames(index, anim) {
				let anchor = gtk_text_buffer_create_child_anchor(buffer, &end)
				let pic = raw(gtk_picture_new_for_paintable(frames[0]))
				gtk_picture_set_can_shrink(c(pic), 0)
				gtk_text_view_add_child_at_anchor(c(history), c(pic), anchor)
				var start: Int64 = 0, shown = 0
				onTick(pic) { now in
					if start == 0 { start = now }
					let elapsed = Double(now - start) / 1_000_000
					let frame = anim.frame(at: elapsed)
					if frame != shown {
						gtk_picture_set_paintable(c(pic), frames[frame])
						shown = frame
					}
					return !anim.once || elapsed < anim.duration
				}
			} else if let image = index.flatMap({ skin.emoticonStill($0) }), let texture = gdk_texture_new_from_filename(image, nil) {
				gtk_text_buffer_insert_paintable(buffer, &end, texture)
				g_object_unref(UnsafeMutableRawPointer(texture))
			} else {
				gtk_text_buffer_insert_markup(buffer, &end, "<span \(style)>\(pangoEscape(piece))</span>", -1)
			}
		}
	}

	/// An animated emoticon's frames as textures, loaded once per app run.
	private static var frameCache: [Int: [OpaquePointer]] = [:]

	private static func frames(_ index: Int, _ anim: Skin.EmoticonAnimation) -> [OpaquePointer]? {
		if let hit = frameCache[index] { return hit }
		var textures: [OpaquePointer] = []
		for f in 0..<anim.frames {
			guard let path = Skin.shared.emoticonFile(index, frame: f), let t = gdk_texture_new_from_filename(path, nil) else { return nil }
			textures.append(t)
		}
		frameCache[index] = textures
		return textures
	}

	private func scrollToEnd() {
		var end = GtkTextIter()
		gtk_text_buffer_get_end_iter(buffer, &end)
		let mark = gtk_text_buffer_create_mark(buffer, nil, &end, 0)
		gtk_text_view_scroll_mark_onscreen(c(history), mark)
		gtk_text_buffer_delete_mark(buffer, mark)
	}

	func typing(_ name: String) {
		typingUntil = Date().addingTimeInterval(6)
		setText(status, "\(name) is typing a message.")
	}

	/// Nudge: jiggle the content (Wayland doesn't let clients move windows).
	func shake() {
		let offsets: [Int32] = [8, -8, 7, -7, 5, -5, 3, -3, 0]
		var i = 0
		every(35) { [weak self] in
			guard let self else { return false }
			let o = offsets[i]
			gtk_widget_set_margin_start(c(self.content), max(0, o))
			gtk_widget_set_margin_end(c(self.content), max(0, -o))
			i += 1
			return i < offsets.count
		}
	}

	// MARK: Input

	private func inputText() -> String {
		let b = gtk_text_view_get_buffer(c(input))
		var start = GtkTextIter(), end = GtkTextIter()
		gtk_text_buffer_get_start_iter(b, &start)
		gtk_text_buffer_get_end_iter(b, &end)
		let p = gtk_text_buffer_get_text(b, &start, &end, 0)!
		defer { g_free(p) }
		return String(cString: p)
	}

	private func send() {
		let text = inputText()
		gtk_text_buffer_set_text(gtk_text_view_get_buffer(c(input)), "", 0)
		lastTypingSent = .distantPast
		state.send(text, to: peer, format: format)
	}

	private func typed() {
		guard !inputText().isEmpty, Date().timeIntervalSince(lastTypingSent) > 4.5 else { return }
		lastTypingSent = Date()
		state.typing(to: peer)
	}

	private func showEmoticons(anchor: Ptr) {
		let grid = raw(gtk_grid_new())
		let pop = raw(gtk_popover_new())
		var byIndex: [Int: String] = [:]
		for (code, index) in skin.emoticons where byIndex[index].map({ code.count < $0.count }) ?? true {
			byIndex[index] = code
		}
		// Strip order, with each animated emoticon at its still's place.
		let place = { (index: Int) in self.skin.emoticonAnimations[index]?.still ?? index }
		for (i, index) in byIndex.keys.sorted(by: { place($0) < place($1) }).enumerated() {
			let code = byIndex[index]!
			let tip = skin.emoticonNames[index].map { "\($0) \(code)" } ?? code
			let b = button(picture(skin.emoticonStill(index)), css: ["wlm-flat"], tooltip: tip) { [weak self] in
				guard let self else { return }
				let buf = gtk_text_view_get_buffer(c(self.input))
				gtk_text_buffer_insert_at_cursor(buf, code, -1)
				popdown(pop)
			}
			gtk_grid_attach(c(grid), c(b), Int32(i % 10), Int32(i / 10), 1, 1)
		}
		gtk_popover_set_child(c(pop), c(grid))
		gtk_widget_set_parent(c(pop), c(anchor))
		on(pop, "closed") { gtk_widget_unparent(c(pop)) }
		gtk_popover_popup(c(pop))
	}
}
