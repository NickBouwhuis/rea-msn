import CGtk
import Foundation
import MSNKit

/// "Verify this session" for services with end-to-end encryption (Matrix):
/// compare emoji with another of your sessions (either side can start), or
/// enter your recovery key. Until it's verified, other people's clients may
/// not share message keys with it. One window, whose contents follow
/// `AppState.verification`.
@MainActor
final class VerificationDialog {
	private var window: Ptr?
	private var content: Ptr?
	private let state = AppState.shared

	func update(parent: Ptr?) {
		guard let step = state.verification else {
			if let window { gtk_window_destroy(c(window)) }
			window = nil
			content = nil
			return
		}
		if window == nil {
			let (w, _) = Chrome.window(app: nil, width: 420, height: 250)
			let body = vbox(10)
			margins(body, top: 12, start: 16, bottom: 12, end: 16)
			append(body, label("Verify this session", css: ["wlm-bold"]))
			let content = vbox(10)
			expand(content, v: true)
			append(body, content)
			gtk_window_set_child(c(w), c(body))
			// The frame's close button: the same as "Not now".
			onBool(w, "close-request") { [weak self] in
				self?.window = nil
				self?.content = nil
				AppState.shared.closeVerification()
				return false
			}
			window = w
			self.content = content
			Dialog.present(w, modalTo: parent)
		}
		guard let content else { return }
		removeAllChildren(content)
		func text(_ s: String) { append(content, label(s, css: ["wlm-label"], wrap: true)) }
		func buttons(_ list: [Ptr]) {
			append(content, spacer(v: true))
			let row = hbox(6)
			append(row, spacer())
			list.forEach { append(row, $0) }
			append(content, row)
		}
		func push(_ title: String, isDefault: Bool = false, _ action: @escaping () -> Void) -> Ptr {
			button(label: title, css: isDefault ? ["wlm-push", "default"] : ["wlm-push"], action)
		}
		let state = self.state
		switch step {
		case .prompt:
			text("Messenger is a new session on your Matrix account. Verify it, and your other sessions (such as Element) will trust it with the keys to your encrypted conversations.")
			buttons([
				push("Not now") { state.closeVerification() },
				push("Use recovery key") { state.verification = .recoveryKey },
				push("Use another session", isDefault: true) { state.verifyWithOtherSession() },
			])
		case let .waiting(message):
			text(message)
			buttons([push("Cancel") { state.closeVerification() }])
		case let .incoming(device):
			text("Your session \u{201C}\(device)\u{201D} wants to verify this one. Accept, then compare the emoji on both screens.")
			buttons([
				push("Not now") { state.closeVerification() },
				push("Accept", isDefault: true) { state.acceptIncomingVerification() },
			])
		case let .emojis(emojis):
			text("Do these appear on your other session, in the same order?")
			// Seven emoji, as Element lays them out: four, then three.
			for row in [Array(emojis.prefix(4)), Array(emojis.dropFirst(4))] where !row.isEmpty {
				let line = hbox(14)
				align(line, h: GTK_ALIGN_CENTER)
				for emoji in row {
					let symbol = raw(gtk_label_new(nil))
					gtk_label_set_markup(c(symbol), "<span size=\"xx-large\">\(g_markup_escape_text(emoji.symbol, -1).map { String(cString: $0) } ?? "")</span>")
					append(line, vbox(4, [symbol, label(emoji.name, css: ["wlm-label"], xalign: 0.5)]))
				}
				append(content, line)
			}
			buttons([
				push("They don't match") { state.confirmEmojis(false) },
				push("They match", isDefault: true) { state.confirmEmojis(true) },
			])
		case .recoveryKey:
			text("Enter the recovery key you saved when you set up secure backup (it starts with \u{201C}Es\u{201D}).")
			let key = entry(placeholder: "EsTc ...")
			append(content, key)
			let verify = {
				let typed = MessengerGTKUI.text(of: key).trimmingCharacters(in: .whitespacesAndNewlines)
				if !typed.isEmpty { state.recover(typed) }
			}
			on(key, "activate", verify)
			buttons([
				push("Back") { state.verification = .prompt },
				push("Verify", isDefault: true, verify),
			])
		case .done:
			text("This session is verified. Your other sessions can now share keys with it, and new encrypted messages will open here.")
			buttons([push("OK", isDefault: true) { state.verification = nil }])
		case let .failed(message):
			text(message)
			buttons([
				push("Close") { state.closeVerification() },
				push("Try again", isDefault: true) { state.verification = .prompt },
			])
		}
	}
}
