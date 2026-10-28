import Foundation
import MSNKit

/// How WLM concepts travel as Matrix events. Other Matrix clients see plain
/// m.room.message events; the namespaced keys let two copies of this app
/// round-trip what Matrix has no field for (fonts, nudges).
public enum MatrixMessage {
	public static let namespace = "io.github.nickbouwhuis.wlm"
	/// The `X-MMS-IM-Format` header of the sender's font, e.g. `FN=Segoe%20UI; EF=B; CO=ff; CS=0; PF=22`.
	public static let formatKey = namespace + ".format"
	public static let nudgeKey = namespace + ".nudge"

	/// An m.text message; bold/italic/underline/strikethrough/colour also go out as HTML.
	public static func content(text: String, format: TextFormat) -> JSON {
		var content: [String: JSON] = [
			"msgtype": "m.text",
			"body": .string(text),
			formatKey: .string(format.header),
		]
		if let html = html(text, format: format) {
			content["format"] = "org.matrix.custom.html"
			content["formatted_body"] = .string(html)
		}
		return .object(content)
	}

	static func html(_ text: String, format: TextFormat) -> String? {
		guard format.bold || format.italic || format.underline || format.strikethrough || format.color != 0 else { return nil }
		var html = text
			.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
			.replacingOccurrences(of: "\"", with: "&quot;")
			.replacingOccurrences(of: "\r\n", with: "<br>")
			.replacingOccurrences(of: "\n", with: "<br>")
		if format.strikethrough { html = "<del>\(html)</del>" }
		if format.underline { html = "<u>\(html)</u>" }
		if format.italic { html = "<i>\(html)</i>" }
		if format.bold { html = "<b>\(html)</b>" }
		if format.color != 0 {
			let hex = "#" + String(format: "%06x", format.color)
			html = "<font data-mx-color=\"\(hex)\" color=\"\(hex)\">\(html)</font>"
		}
		return html
	}

	/// Shown in other clients as "* Name just sent you a nudge."
	public static func nudge() -> JSON {
		["msgtype": "m.emote", "body": "just sent you a nudge.", nudgeKey: true]
	}

	public static func isNudge(_ content: JSON) -> Bool {
		content[nudgeKey].bool == true
	}

	public static func format(of content: JSON) -> TextFormat {
		content[formatKey].string.map(TextFormat.init(header:)) ?? TextFormat()
	}

	/// What a conversation window shows for an m.room.message from `senderName`.
	public static func text(of content: JSON, senderName: String) -> String {
		let body = content["body"].string ?? ""
		switch content["msgtype"].string {
		case "m.emote": return "* \(senderName) \(body)"
		case "m.image": return "[Picture: \(body)]"
		case "m.file": return "[File: \(body)]"
		case "m.video": return "[Video: \(body)]"
		case "m.audio": return "[Audio: \(body)]"
		case "m.location": return "[Location: \(body)]"
		default:
			return content["m.relates_to"]["m.in_reply_to"].isNull ? body : stripReplyFallback(body)
		}
	}

	/// Replies quote the original as "> <@user> text" lines and a blank line.
	static func stripReplyFallback(_ body: String) -> String {
		var lines = body.components(separatedBy: "\n")[...]
		guard lines.first?.hasPrefix(">") == true else { return body }
		while let first = lines.first, first.hasPrefix(">") { lines = lines.dropFirst() }
		if lines.first?.isEmpty == true { lines = lines.dropFirst() }
		return lines.joined(separator: "\n")
	}

	public static let encryptedNotice = "This message is encrypted, and this version of Messenger can't read it yet."
	public static let undecryptableNotice = "This message couldn't be decrypted. Verifying this session (Actions ▸ Verify This Session) lets your other sessions share their keys."
	public static var noticeFormat: TextFormat {
		var f = TextFormat()
		f.italic = true
		f.color = 0x808080
		return f
	}
}

public extension Presence {
	/// Matrix has three presence states (plus MSC3026's busy); WLM's away-ish
	/// statuses all become "unavailable".
	var matrixState: String {
		switch self {
		case .online: return "online"
		case .appearOffline, .offline: return "offline"
		case .busy, .beRightBack, .away, .onThePhone, .outToLunch, .idle: return "unavailable"
		}
	}

	init(matrix state: String?) {
		switch state {
		case "online": self = .online
		case "unavailable": self = .away
		case "org.matrix.msc3026.busy", "busy": self = .busy
		default: self = .offline
		}
	}
}
