import Foundation

/// WLM 8.1's own UI resources, compiled from your installer by
/// linux/scripts/import-wlm-assets.sh into $XDG_DATA_HOME/messenger-wlm/Skin
/// (see re/scripts/wlm_skin.py). IDs are those the DirectUI stylesheets use.
final class Skin {
	static let shared = Skin()

	let root: URL
	private(set) var isLoaded = false
	private var images: [Int: [String: Any]] = [:]
	private var values: [Int: [String: Any]] = [:]
	private var strings: [Int: String] = [:]
	/// Shortcut → emoticon index: a cell of msgsres.dll PNG 202, or 108–118 animated.
	private(set) var emoticons: [String: Int] = [:]
	private(set) var emoticonAnimations: [Int: EmoticonAnimation] = [:]
	private(set) var emoticonNames: [Int: String] = [:]

	/// An animated emoticon (108–118): msnmsgr.exe steps through the strip every
	/// `interval`, looping, or once and back to frame 0 (FUN_006dd19a).
	struct EmoticonAnimation {
		let frames: Int
		let once: Bool
		let interval: Double
		let still: Int?

		/// The frame shown `elapsed` seconds after the emoticon appeared.
		func frame(at elapsed: Double) -> Int {
			guard elapsed.isFinite, elapsed >= 0 else { return 0 }
			let tick = Int(elapsed / interval)
			return once ? (tick < frames ? tick : 0) : tick % frames
		}

		var duration: Double { interval * Double(frames) }
	}

	init() {
		let data = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
			?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
		root = data.appendingPathComponent("messenger-wlm/Skin")
		guard let d = try? Data(contentsOf: root.appendingPathComponent("skin.json")),
		      let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
		func ints<T>(_ key: String, _ f: (Any) -> T?) -> [Int: T] {
			var out: [Int: T] = [:]
			for (k, v) in json[key] as? [String: Any] ?? [:] { if let i = Int(k), let t = f(v) { out[i] = t } }
			return out
		}
		images = ints("images") { $0 as? [String: Any] }
		values = ints("values") { $0 as? [String: Any] }
		strings = ints("strings") { $0 as? String }
		emoticons = json["emoticons"] as? [String: Int] ?? [:]
		emoticonAnimations = ints("emoticonAnimations") { v in
			guard let d = v as? [String: Any], let frames = d["frames"] as? Int else { return nil }
			return EmoticonAnimation(frames: frames, once: d["once"] as? Bool ?? false,
			                         interval: Double(d["interval"] as? Int ?? 250) / 1000, still: d["still"] as? Int)
		}
		emoticonNames = ints("emoticonNames") { $0 as? String }
		isLoaded = !images.isEmpty
	}

	/// Path of a resource image (a state/animation frame for frame > 0).
	func image(_ id: Int, frame: Int = 0) -> String? {
		guard let info = images[id], let file = info["file"] as? String else {
			if let alias = values[id]?["alias"] as? Int { return image(alias, frame: frame) }
			return nil
		}
		let frames = info["frames"] as? Int ?? 1
		let name = frame == 0 ? file : "\(id)_\(min(frame, frames - 1)).png"
		let path = root.appendingPathComponent("img/\(name)").path
		return FileManager.default.fileExists(atPath: path) ? path : nil
	}

	/// Nine-slice cap insets (left, top, right, bottom).
	func insets(_ id: Int) -> [Int]? { images[id]?["insets"] as? [Int] }

	/// The still image for a shortcut (animated emoticons show their strip cell).
	func emoticon(_ code: String) -> String? { emoticons[code].flatMap { emoticonStill($0) } }

	func emoticonStill(_ index: Int) -> String? { emoticonFile(emoticonAnimations[index]?.still ?? index) }

	func emoticonFile(_ index: Int, frame: Int = 0) -> String? {
		let p = root.appendingPathComponent(frame == 0 ? "emoticons/\(index).png" : "emoticons/\(index)_\(frame).png").path
		return FileManager.default.fileExists(atPath: p) ? p : nil
	}

	var appIcon: String? {
		let p = root.appendingPathComponent("icon/256.png").path
		return FileManager.default.fileExists(atPath: p) ? p : nil
	}

	func string(_ id: Int, _ fallback: String) -> String {
		guard let s = strings[id] else { return fallback }
		return s.replacingOccurrences(of: "&&", with: "\u{0}").replacingOccurrences(of: "&", with: "").replacingOccurrences(of: "\u{0}", with: "&")
	}

	// MARK: - Stylesheet

	private func url(_ id: Int, frame: Int = 0) -> String? {
		image(id, frame: frame).map { "url(\"file://\($0)\")" }
	}

	private func nineSlice(_ id: Int) -> String {
		guard let u = url(id), let i = insets(id) else { return "" }
		return "border-image: \(u) \(i[1]) \(i[2]) \(i[3]) \(i[0]) stretch; border-width: \(i[1])px \(i[2])px \(i[3])px \(i[0])px;"
	}

	/// GTK CSS for the WLM 8.1 look. Values come from the stylesheets quoted in
	/// docs/RE-FINDINGS.md §5 (logonFrameSS, mainwndss, clss, mainss, convframess).
	var css: String {
		let header = url(R.header).map { "\($0)" } ?? "linear-gradient(#063878, #347FA2 40%, #ECF3F6)"
		let vapor = url(R.vapor) ?? "none"
		var css = """
		window.wlm, window.wlm.background {
			background-color: #ECF3F6;
			background-image: \(vapor), \(header);
			background-repeat: no-repeat, repeat-x;
			background-position: right top, left top;
			background-size: auto, 100% 121px;
			color: #333333;
			font-family: Tahoma, "DejaVu Sans", sans-serif;
			font-size: 11px;
		}
		window.wlm .wlm-titlebar { background: none; box-shadow: none; min-height: 30px; }
		window.wlm .wlm-title { color: white; font-weight: bold; }
		window.wlm .wlm-subtitle { color: rgba(255,255,255,0.8); }
		.wlm-framebtn { background: none; border: none; box-shadow: none; padding: 3px; min-width: 0; min-height: 0; }
		.wlm-framebtn:backdrop { opacity: 0.5; }
		.wlm-label { color: #333333; }
		.wlm-hint { color: #ACA899; }
		.wlm-muted { color: #777777; }
		.wlm-bold { font-weight: bold; }
		.wlm-error { color: #CC0000; }
		.wlm-input, .wlm-input:focus-within {
			background: white; color: black; border: 1px solid #AAB7C7; border-radius: 0;
			box-shadow: none; outline: none; min-height: 20px; padding: 1px 4px;
		}
		.wlm-tile { background: white; border: 1px solid #D8D9D9; padding: 2px; }
		.wlm-input entry, .wlm-input entry:focus-within, .wlm-input > text {
			background: none; border: none; box-shadow: none; outline: none; min-height: 0; padding: 0; margin: 0;
		}
		menubutton.wlm-flat > button, button.wlm-flat, .wlm-flat > button {
			background: none; border: none; box-shadow: none; padding: 2px; min-height: 0; min-width: 0; border-radius: 0; outline: none;
		}
		menubutton.wlm-flat > button:hover, menubutton.wlm-flat > button:checked { \(nineSlice(R.hoverBackground)) border-style: solid; }
		menubutton.wlm-flat > button > box > arrow { -gtk-icon-source: none; min-width: 0; min-height: 0; }
		popover > contents { padding: 2px; border-radius: 0; background: white; }
		popover, popover label { font-family: Tahoma, "DejaVu Sans", sans-serif; font-size: 11px; color: #333333; }
		popover button.wlm-flat { padding: 3px 8px; }
		.wlm-push {
			color: #001563; padding: 1px 2px; min-width: 64px; background: none; box-shadow: none; border-radius: 0;
			\(nineSlice(R.pushButton))
		}
		.wlm-push.default { \(nineSlice(R.pushButtonDefault)) }
		.wlm-push:hover { \(nineSlice(R.pushButtonHover)) }
		.wlm-push:active { \(nineSlice(R.pushButtonPressed)) }
		.wlm-flat { background: none; border: none; box-shadow: none; padding: 2px; min-height: 0; min-width: 0; border-radius: 0; }
		.wlm-flat:hover { \(nineSlice(R.hoverBackground)) border-style: solid; }
		.wlm-link { color: #0088E4; background: none; border: none; box-shadow: none; padding: 2px; min-height: 0; }
		.wlm-link:hover { text-decoration: underline; }
		.wlm-addressbook { background: white; border: 1px solid #BED6E0; }
		.wlm-searchbar { border-bottom: 1px solid #E2EAF3; padding: 7px 2px 7px 7px; }
		.wlm-group { font-weight: bold; color: #333333; padding: 2px 2px 2px 3px; }
		.wlm-buddy { padding: 2px 0; }
		.wlm-buddy.selected { background: #D2EAF6; }
		.wlm-history, .wlm-composer { background: white; border: 1px solid #BED6E0; }
		.wlm-history text, .wlm-composer text { background: white; color: black; }
		.wlm-formatbar { background: linear-gradient(white, #E9F1F5); border: 1px solid #BED6E0; border-bottom: none; padding: 1px; }
		.wlm-status { color: #777777; padding: 3px 0; }
		popover.wlm-menu contents { padding: 2px; }
		"""
		if let off = url(R.checkbox), let on = url(R.checkboxChecked) {
			css += """

			.wlm-check check { -gtk-icon-source: \(off); background: none; border: none; box-shadow: none; min-width: 13px; min-height: 13px; -gtk-icon-size: 13px; }
			.wlm-check check:checked { -gtk-icon-source: \(on); }
			.wlm-check { color: #333333; }
			"""
		}
		return css
	}
}

/// Resource IDs from the WLM 8.1 stylesheets (same as the macOS app's).
enum R {
	static let header = 20057, vapor = 20055, windowIcon = 20066, logo = 682
	static let minBtn = 20071, maxBtn = 20072, closeBtn = 20070, gripper = 20076
	static let pushButton = 20093, pushButtonDefault = 20094, pushButtonHover = 20095, pushButtonPressed = 20096
	static let checkbox = 20031, checkboxChecked = 20035, caret = 652, hoverBackground = 20201
	static let liveIDLogo = 1014, defaultTileLarge = 1529, defaultTileSmall = 597
	static let toolbarIcons = [1480, 1482, 978, 46610, 1484, 1481, 1488, 329]
	static let statusPill = 46611, expandCollapse = 1382, addContact = 1131, viewMenu = 1132, searchClear = 1133
	static let activity = [(1441, "Invite"), (1444, "Share Files"), (1445, "Video"), (1447, "Call"), (1442, "Activities"), (1443, "Games")]
	static let block = 326
	static let format = [(411, "Font"), (412, "Emoticons"), (1487, "Wink"), (414, "Nudge"), (992, "Voice Clip"), (410, "Backgrounds"), (329, "Colour scheme")]
}
