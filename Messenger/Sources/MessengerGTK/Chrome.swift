import CGtk
import Foundation
import MSNKit

/// WLM's own frame as a GTK client-side titlebar: window icon, the Messenger
/// logo (or a conversation's title), and the FLW minimise/maximise/close
/// buttons, inside a GtkWindowHandle so the bar drags the window. The header
/// gradient and "vapor" are the window's CSS background (Skin.css).
enum Chrome {
	static func titlebar(for window: Ptr, title: String? = nil, subtitle: String? = nil) -> (bar: Ptr, title: Ptr?) {
		let skin = Skin.shared
		let row = hbox(4, css: ["wlm-titlebar"])
		let icon = picture(skin.image(R.windowIcon))
		margins(icon, top: 6, start: 7, bottom: 4, end: 2)
		append(row, icon)
		var titleBox: Ptr?
		if let title {
			let box = hbox(4)
			append(box, RichText.line(title, css: ["wlm-title"]))
			if let subtitle { append(box, label(subtitle, css: ["wlm-subtitle"])) }
			align(box, v: GTK_ALIGN_CENTER)
			append(row, box)
			titleBox = box
		} else if let logo = skin.image(R.logo) {
			let p = picture(logo)
			align(p, v: GTK_ALIGN_CENTER)
			append(row, p)
		} else {
			append(row, label("Windows Live Messenger", css: ["wlm-title"]))
		}
		append(row, spacer())
		let buttons = hbox(0)
		margins(buttons, top: 5, end: 5)
		align(buttons, v: GTK_ALIGN_START)
		append(buttons, frameButton(R.minBtn, "Minimize") { gtk_window_minimize(c(window)) })
		append(buttons, frameButton(R.maxBtn, "Maximize") {
			if gtk_window_is_maximized(c(window)) != 0 { gtk_window_unmaximize(c(window)) } else { gtk_window_maximize(c(window)) }
		})
		append(buttons, frameButton(R.closeBtn, "Close") { gtk_window_close(c(window)) })
		append(row, buttons)

		let handle = raw(gtk_window_handle_new())
		gtk_window_handle_set_child(c(handle), c(row))
		return (handle, titleBox)
	}

	/// Three-frame images: normal, hover, pressed.
	private static func frameButton(_ id: Int, _ tooltip: String, _ action: @escaping () -> Void) -> Ptr {
		let skin = Skin.shared
		let pic = picture(skin.image(id))
		let b = button(pic, css: ["wlm-framebtn"], tooltip: tooltip, action)
		let motion = raw(gtk_event_controller_motion_new())
		on(motion, "enter") { setPicture(pic, skin.image(id, frame: 1)) }
		on(motion, "leave") { setPicture(pic, skin.image(id)) }
		gtk_widget_add_controller(c(b), c(motion))
		return b
	}

	/// A top-level window with the WLM frame.
	static func window(app: Ptr?, width: Int32, height: Int32, title: String? = nil, subtitle: String? = nil) -> (window: Ptr, title: Ptr?) {
		let w = app.map { raw(gtk_application_window_new(c($0))) } ?? raw(gtk_window_new())
		gtk_window_set_default_size(c(w), width, height)
		gtk_window_set_title(c(w), title ?? "Windows Live Messenger")
		addClass(w, "wlm")
		let (bar, t) = titlebar(for: w, title: title, subtitle: subtitle)
		gtk_window_set_titlebar(c(w), c(bar))
		return (w, t)
	}
}

/// Text with WLM emoticons inline, as a row of labels and 19×19 pictures.
enum RichText {
	static func line(_ text: String, css: [String] = []) -> Ptr {
		let row = hbox(0)
		for (piece, index) in tokens(text) {
			if let image = index.flatMap({ Skin.shared.emoticonStill($0) }) {
				let p = picture(image)
				align(p, v: GTK_ALIGN_CENTER)
				append(row, p)
			} else {
				append(row, label(piece, css: css))
			}
		}
		return row
	}

	/// Splits on the skin's emoticon shortcuts, longest first; shortcuts come
	/// with their emoticon index.
	static func tokens(_ text: String) -> [(String, Int?)] {
		let skin = Skin.shared
		guard !skin.emoticons.isEmpty else { return [(text, nil)] }
		let codes = skin.emoticons.keys.sorted { $0.count > $1.count }
		var out: [(String, Int?)] = []
		var plain = ""
		var i = text.startIndex
		outer: while i < text.endIndex {
			for code in codes where text[i...].hasPrefix(code) {
				if let index = skin.emoticons[code], skin.emoticonStill(index) != nil {
					if !plain.isEmpty { out.append((plain, nil)); plain = "" }
					out.append((code, index))
					i = text.index(i, offsetBy: code.count)
					continue outer
				}
			}
			plain.append(text[i])
			i = text.index(after: i)
		}
		if !plain.isEmpty { out.append((plain, nil)) }
		return out
	}
}

/// Small modal dialogs in the WLM frame (GtkAlertDialog is variadic, so not importable).
enum Dialog {
	static func alert(_ message: String, parent: Ptr? = nil) {
		let (w, _) = Chrome.window(app: nil, width: 340, height: 150)
		let body = vbox(10)
		margins(body, top: 12, start: 16, bottom: 12, end: 16)
		append(body, label(message, css: ["wlm-label"], wrap: true))
		append(body, spacer(v: true))
		let ok = button(label: "OK", css: ["wlm-push", "default"]) { gtk_window_destroy(c(w)) }
		align(ok, h: GTK_ALIGN_END)
		append(body, ok)
		gtk_window_set_child(c(w), c(body))
		present(w, modalTo: parent)
	}

	static func prompt(title: String, message: String, placeholder: String, text initial: String = "", ok: String, parent: Ptr?, _ done: @escaping (String) -> Void) {
		let (w, _) = Chrome.window(app: nil, width: 340, height: 170)
		let body = vbox(6)
		margins(body, top: 12, start: 16, bottom: 12, end: 16)
		append(body, label(title, css: ["wlm-bold"]))
		append(body, label(message, css: ["wlm-label"], wrap: true))
		let e = entry(placeholder: placeholder)
		setText(editable: e, initial)
		append(body, e)
		append(body, spacer(v: true))
		let row = hbox(6)
		append(row, spacer())
		append(row, button(label: "Cancel", css: ["wlm-push"]) { gtk_window_destroy(c(w)) })
		let submit = { done(text(of: e)); gtk_window_destroy(c(w)) }
		append(row, button(label: ok, css: ["wlm-push", "default"], submit))
		on(e, "activate", submit)
		append(body, row)
		gtk_window_set_child(c(w), c(body))
		present(w, modalTo: parent)
	}

	static func present(_ w: Ptr, modalTo parent: Ptr?) {
		if let parent {
			gtk_window_set_transient_for(c(w), c(parent))
			gtk_window_set_modal(c(w), 1)
		}
		gtk_window_present(c(w))
	}
}
