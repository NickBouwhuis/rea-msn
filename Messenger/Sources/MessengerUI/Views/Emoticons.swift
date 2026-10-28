import Foundation

import AppKit
import SwiftUI

/// WLM 8.1 emoticons. With an imported skin they render as the real 19×19
/// images from msgsres.dll (shortcut table recovered from msnmsgr.exe);
/// otherwise as the Unicode stand-ins below.
enum Emoticons {
	static let table: [(String, String)] = [
		(":-)", "🙂"), (":)", "🙂"), (":-D", "😃"), (":d", "😃"), (":D", "😃"), (";-)", "😉"), (";)", "😉"),
		(":-O", "😮"), (":o", "😮"), (":O", "😮"), (":-P", "😛"), (":p", "😛"), (":P", "😛"), ("(H)", "😎"), ("(h)", "😎"),
		(":-@", "😠"), (":@", "😠"), (":-$", "😳"), (":$", "😳"), (":-S", "😕"), (":s", "😕"), (":S", "😕"),
		(":-(", "🙁"), (":(", "🙁"), (":'(", "😢"), (":-|", "😐"), (":|", "😐"), ("(A)", "😇"), ("(a)", "😇"),
		("8o|", "😬"), ("8-|", "🤓"), ("+o(", "🤢"), ("<:o)", "🥳"), ("|-)", "😴"), ("*-)", "🤔"), (":-#", "🤐"),
		(":-*", "🤫"), ("^o)", "🤨"), ("8-)", "🙄"), ("(L)", "❤️"), ("(l)", "❤️"), ("(U)", "💔"), ("(u)", "💔"),
		("(K)", "💋"), ("(k)", "💋"), ("(G)", "🎁"), ("(g)", "🎁"), ("(F)", "🌹"), ("(f)", "🌹"), ("(W)", "🥀"), ("(w)", "🥀"),
		("(P)", "📷"), ("(p)", "📷"), ("(~)", "🎞️"), ("(@)", "🐱"), ("(&)", "🐶"), ("(T)", "📞"), ("(t)", "📞"),
		("(I)", "💡"), ("(i)", "💡"), ("(8)", "🎵"), ("(S)", "🌙"), ("(*)", "⭐️"), ("(E)", "✉️"), ("(e)", "✉️"),
		("(^)", "🎂"), ("(O)", "🕒"), ("(o)", "🕒"), ("(M)", "💬"), ("(m)", "💬"), ("(C)", "☕️"), ("(c)", "☕️"),
		("(B)", "🍺"), ("(b)", "🍺"), ("(D)", "🍸"), ("(d)", "🍸"), ("(Z)", "👦"), ("(z)", "👦"), ("(X)", "👧"), ("(x)", "👧"),
		("(Y)", "👍"), ("(y)", "👍"), ("(N)", "👎"), ("(n)", "👎"), ("({)", "🤝"), ("(})", "🤗"), ("(pl)", "🍽️"),
		("(||)", "🥣"), ("(so)", "⚽️"), ("(st)", "🌧️"), ("(sn)", "🐌"), ("(mp)", "📱"), ("(ip)", "🏝️"), ("(au)", "🚗"),
		("(um)", "☂️"), ("(ap)", "✈️"), ("(co)", "💻"), ("(mo)", "💰"), ("(h5)", "🙌"), ("(xx)", "🎮"), ("(brb)", "🔙"),
		("(yn)", "🤞"), ("(nah)", "🐐"), ("(bah)", "🐑"), ("(lol)", "😂"),
	]

	/// Longest-match replacement so ":-)" wins over ":)" etc.
	static func render(_ text: String, enabled: Bool = true) -> String {
		guard enabled else { return text }
		let sorted = table.sorted { $0.0.count > $1.0.count }
		var out = ""
		var i = text.startIndex
		outer: while i < text.endIndex {
			for (code, emoji) in sorted where text[i...].hasPrefix(code) {
				out += emoji
				i = text.index(i, offsetBy: code.count)
				continue outer
			}
			out.append(text[i])
			i = text.index(after: i)
		}
		return out
	}

	/// Splits text into plain runs and emoticon shortcuts (longest match first),
	/// each shortcut with its emoticon index.
	@MainActor
	static func tokens(_ text: String) -> [(String, Int?)] {
		let skin = Skin.shared
		let codes = skin.emoticons.isEmpty ? [] : skin.emoticons.keys.sorted { $0.count > $1.count }
		guard !codes.isEmpty else { return [(text, nil)] }
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

	/// A `Text` with emoticons inline: skin images when imported, emoji otherwise.
	/// With `elapsed`, animated emoticons show that moment's frame; without it, their still.
	@MainActor
	static func text(_ s: String, enabled: Bool = true, elapsed: TimeInterval? = nil) -> Text {
		guard enabled else { return Text(s) }
		let skin = Skin.shared
		guard !skin.emoticons.isEmpty else { return Text(render(s)) }
		return tokens(s).reduce(Text("")) { acc, tok in
			guard let index = tok.1 else { return acc + Text(tok.0) }
			var img = skin.emoticonStill(index)
			if let elapsed, let anim = skin.emoticonAnimations[index] {
				img = skin.emoticonCell(index, frame: anim.frame(at: elapsed)) ?? img
			}
			guard let img else { return acc + Text(tok.0) }
			return acc + Text(Image(nsImage: img).interpolation(.none)).baselineOffset(-4)
		}
	}

	/// The animations in `s`: nil if none, else how long they run (∞ if one loops)
	/// and their frame interval.
	@MainActor
	static func animation(in s: String) -> (length: TimeInterval, interval: TimeInterval)? {
		let anims = tokens(s).compactMap { $0.1.flatMap { Skin.shared.emoticonAnimations[$0] } }
		guard let interval = anims.map(\.interval).min() else { return nil }
		let length = anims.contains { !$0.once } ? .infinity : anims.map(\.duration).max()!
		return (length, interval)
	}

	/// The skin's emoticons in strip order, each with its shortest shortcut and
	/// WLM's name for it (animated ones sit at their still's place).
	@MainActor
	static var skinPicker: [(code: String, image: NSImage, name: String?)] {
		let skin = Skin.shared
		var byIndex: [Int: String] = [:]
		for (code, index) in skin.emoticons {
			if let have = byIndex[index], have.count < code.count || (have.count == code.count && have < code) { continue }
			byIndex[index] = code
		}
		let place = { (index: Int) in skin.emoticonAnimations[index]?.still ?? index }
		return byIndex.keys.sorted { place($0) < place($1) }.compactMap { index in
			guard let code = byIndex[index], let img = skin.emoticonStill(index) else { return nil }
			return (code, img, skin.emoticonNames[index])
		}
	}

	/// The picker in the conversation toolbar (WLM's first page of emoticons).
	static let picker: [(String, String)] = [
		(":)", "🙂"), (":D", "😃"), (";)", "😉"), (":O", "😮"), (":P", "😛"), ("(H)", "😎"), (":@", "😠"), (":$", "😳"),
		(":S", "😕"), (":(", "🙁"), (":'(", "😢"), (":|", "😐"), ("(A)", "😇"), ("8o|", "😬"), ("8-|", "🤓"), ("+o(", "🤢"),
		("<:o)", "🥳"), ("|-)", "😴"), ("*-)", "🤔"), (":-#", "🤐"), ("(L)", "❤️"), ("(U)", "💔"), ("(K)", "💋"), ("(F)", "🌹"),
		("(Y)", "👍"), ("(N)", "👎"), ("(C)", "☕️"), ("(B)", "🍺"), ("(*)", "⭐️"), ("(8)", "🎵"), ("(lol)", "😂"), ("(h5)", "🙌"),
	]
}

/// Message text whose animated emoticons play as msnmsgr.exe plays them: from
/// when the line appears, one frame per interval, looping or once and back to frame 0.
struct AnimatedEmoticonText: View {
	let text: String
	var enabled = true
	@State private var start = Date()
	@State private var finished = false

	var body: some View {
		if enabled, !finished, let anim = Emoticons.animation(in: text) {
			TimelineView(.periodic(from: start, by: anim.interval)) { context in
				Emoticons.text(text, elapsed: context.date.timeIntervalSince(start))
			}
			.task {
				guard anim.length.isFinite else { return }
				try? await Task.sleep(for: .seconds(anim.length))
				finished = true
			}
		} else {
			Emoticons.text(text, enabled: enabled, elapsed: finished ? .infinity : nil)
		}
	}
}
