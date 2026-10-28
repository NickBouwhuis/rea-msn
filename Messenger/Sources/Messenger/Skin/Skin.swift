import AppKit
import SwiftUI

/// WLM 8.1's own UI resources, compiled from msgsres.dll/msgslang.dll by
/// re/scripts/wlm_skin.py (via scripts/import-wlm-assets.sh) into
/// ~/Library/Application Support/MessengerMac/Skin. Resource IDs used by the
/// views are the ones the original DirectUI stylesheets reference.
@MainActor
final class Skin {
	static let shared = Skin()

	/// An animated emoticon (108–118): msnmsgr.exe steps through the strip every
	/// `interval`, looping, or once and back to frame 0 (FUN_006dd19a).
	struct EmoticonAnimation {
		let frames: Int
		let once: Bool
		let interval: TimeInterval
		let still: Int?

		/// The frame shown `elapsed` seconds after the emoticon appeared.
		func frame(at elapsed: TimeInterval) -> Int {
			guard elapsed.isFinite, elapsed >= 0 else { return 0 }
			let tick = Int(elapsed / interval)
			return once ? (tick < frames ? tick : 0) : tick % frames
		}

		var duration: TimeInterval { interval * Double(frames) }
	}

	struct ImageInfo {
		let file: String
		let frames: Int
		let insets: EdgeInsets?
	}

	let root: URL
	private(set) var isLoaded = false
	private var images: [Int: ImageInfo] = [:]
	private var colors: [Int: Any] = [:]
	private var values: [Int: [String: Any]] = [:]
	private var strings: [Int: String] = [:]
	/// Shortcut → emoticon index (re/data/emoticons.json): a cell of msgsres.dll
	/// PNG 202, or 108–118 for the animated ones.
	private(set) var emoticons: [String: Int] = [:]
	private(set) var emoticonAnimations: [Int: EmoticonAnimation] = [:]
	private(set) var emoticonNames: [Int: String] = [:]
	private var cache: [String: NSImage] = [:]

	init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		.appendingPathComponent("MessengerMac/Skin", isDirectory: true)) {
		self.root = root
		reload()
	}

	func reload() {
		cache.removeAll()
		guard let data = try? Data(contentsOf: root.appendingPathComponent("skin.json")),
		      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			isLoaded = false
			return
		}
		func ints<T>(_ key: String, _ map: (Any) -> T?) -> [Int: T] {
			var out: [Int: T] = [:]
			for (k, v) in json[key] as? [String: Any] ?? [:] {
				if let id = Int(k), let t = map(v) { out[id] = t }
			}
			return out
		}
		images = ints("images") { v in
			guard let d = v as? [String: Any], let file = d["file"] as? String else { return nil }
			var insets: EdgeInsets?
			if let i = d["insets"] as? [Double], i.count == 4 {
				insets = EdgeInsets(top: i[1], leading: i[0], bottom: i[3], trailing: i[2])
			}
			return ImageInfo(file: file, frames: d["frames"] as? Int ?? 1, insets: insets)
		}
		colors = ints("colors") { $0 }
		values = ints("values") { $0 as? [String: Any] }
		strings = ints("strings") { $0 as? String }
		emoticons = (json["emoticons"] as? [String: Int]) ?? [:]
		emoticonAnimations = ints("emoticonAnimations") { v in
			guard let d = v as? [String: Any], let frames = d["frames"] as? Int else { return nil }
			return EmoticonAnimation(frames: frames, once: d["once"] as? Bool ?? false,
			                         interval: Double(d["interval"] as? Int ?? 250) / 1000, still: d["still"] as? Int)
		}
		emoticonNames = ints("emoticonNames") { $0 as? String }
		isLoaded = !images.isEmpty
	}

	// MARK: - Lookups

	func image(_ id: Int, frame: Int = 0) -> NSImage? {
		guard let info = images[id] else {
			if let alias = values[id]?["alias"] as? Int { return image(alias, frame: frame) }
			return nil
		}
		let file = frame == 0 ? info.file : "\(id)_\(min(frame, info.frames - 1)).png"
		if let hit = cache[file] { return hit }
		guard let img = NSImage(contentsOf: root.appendingPathComponent("img/\(file)")) else { return nil }
		// One resource pixel = one point, as at 96 DPI on Windows.
		if let rep = img.representations.first { img.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh) }
		cache[file] = img
		return img
	}

	func insets(_ id: Int) -> EdgeInsets? { images[id]?.insets }

	/// The still image for a shortcut (animated emoticons show their strip cell).
	func emoticon(_ shortcut: String) -> NSImage? {
		emoticons[shortcut].flatMap { emoticonStill($0) }
	}

	func emoticonStill(_ index: Int) -> NSImage? {
		emoticonCell(emoticonAnimations[index]?.still ?? index)
	}

	func emoticonCell(_ index: Int, frame: Int = 0) -> NSImage? {
		file(frame == 0 ? "emoticons/\(index).png" : "emoticons/\(index)_\(frame).png")
	}

	/// The Messenger icon from the installer (16–256 px).
	var appIcon: NSImage? {
		let img = NSImage()
		for size in [16, 32, 48, 256] {
			if let rep = NSImageRep(contentsOf: root.appendingPathComponent("icon/\(size).png")) { img.addRepresentation(rep) }
		}
		return img.representations.isEmpty ? nil : img
	}

	private func file(_ path: String) -> NSImage? {
		if let hit = cache[path] { return hit }
		guard let img = NSImage(contentsOf: root.appendingPathComponent(path)) else { return nil }
		if let rep = img.representations.first { img.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh) }
		cache[path] = img
		return img
	}

	/// `rcclr(N)`, following `J` aliases.
	func color(_ id: Int) -> Color? {
		var v: Any? = colors[id]
		for _ in 0..<4 {
			if let d = v as? [String: Any], let alias = d["alias"] as? Int { v = colors[alias] } else { break }
		}
		return (v as? String).flatMap(Color.init(hexRGBA:))
	}

	/// A non-image `rcbkd(N)` value: solid colour or two-stop gradient.
	func fill(_ id: Int) -> AnyShapeStyle? {
		guard var v = values[id] else { return nil }
		if let alias = v["alias"] as? Int, let next = values[alias] { v = next }
		if let c = v["color"] as? String, let color = Color(hexRGBA: c) { return AnyShapeStyle(color) }
		if let from = (v["from"] as? String).flatMap(Color.init(hexRGBA:)), let to = (v["to"] as? String).flatMap(Color.init(hexRGBA:)) {
			let vertical = (v["gradient"] as? String) == "vertical"
			return AnyShapeStyle(LinearGradient(colors: [from, to], startPoint: vertical ? .top : .leading, endPoint: vertical ? .bottom : .trailing))
		}
		return nil
	}

	/// `rcstr(N)` with Windows `&` accelerators removed.
	func string(_ id: Int) -> String? {
		strings[id].map { $0.replacingOccurrences(of: "&&", with: "\u{0}").replacingOccurrences(of: "&", with: "").replacingOccurrences(of: "\u{0}", with: "&") }
	}

	func string(_ id: Int, _ fallback: String) -> String { string(id) ?? fallback }
}

extension Color {
	init?(hexRGBA s: String) {
		let hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
		guard hex.count == 8, let v = UInt32(hex, radix: 16) else { return nil }
		self.init(.sRGB, red: Double(v >> 24 & 0xFF) / 255, green: Double(v >> 16 & 0xFF) / 255,
		          blue: Double(v >> 8 & 0xFF) / 255, opacity: Double(v & 0xFF) / 255)
	}

	init(rgb: UInt32) {
		self.init(.sRGB, red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
	}
}

/// Resource IDs and fallback values taken from the WLM 8.1 stylesheets
/// (logonFrameSS 947, mainwndss 923, clss 1009, mainss 1001/44103).
enum R {
	// Frame (947/923)
	static let header = 20057, vapor = 20055, windowIcon = 20066, logo = 682
	static let menuBtn = 20073, minBtn = 20071, maxBtn = 20072, closeBtn = 20070, gripper = 20076
	static let headerHeight: CGFloat = 121
	static let windowBackground = Color(rgb: 0xECF3F6)
	// Controls
	static let pushButton = 20093, pushButtonDefault = 20094, pushButtonHover = 20095, pushButtonPressed = 20096
	static let checkbox = 20031, checkboxChecked = 20035
	static let caret = 652, hoverBackground = 20201, pressedBackground = 20202
	static let liveIDLogo = 1014
	static let text = Color(rgb: 0x333333), buttonText = Color(rgb: 0x001563), link = Color(rgb: 0x0066CC)
	static let hint = Color(rgb: 0xACA899), inputBorder = Color(rgb: 0x98978B), tileBorder = Color(rgb: 0xD8D9D9)
	// Main window
	static let meAreaBackground = 638, defaultTileLarge = 1529, defaultTileSmall = 597
	static let toolbarIcons = [1480, 1482, 978, 46610, 1484, 1481, 1488, 329]
	static let statusPill = 46611, expandCollapse = 1382, addContact = 1131, viewMenu = 1132
	static let searchClear = 1133
	static let selection = Color(rgb: 0xD2EAF6), selectionInactive = Color(rgb: 0xE4E4E4)
	static let listBorder = Color(rgb: 0xBED6E0), searchBorder = Color(rgb: 0xE2EAF3)
	static let stockPictures = [234, 235, 236, 237, 238, 239, 250, 251, 252, 253, 254]
}

enum WLMFont {
	/// "MS Shell Dlg 2" 8pt at 96 DPI ≈ 11px Tahoma.
	static func regular(_ size: CGFloat = 11) -> Font {
		NSFont(name: "Tahoma", size: size) != nil ? .custom("Tahoma", fixedSize: size) : .system(size: size)
	}

	static func bold(_ size: CGFloat = 11) -> Font {
		NSFont(name: "Tahoma-Bold", size: size) != nil ? .custom("Tahoma-Bold", fixedSize: size) : .system(size: size, weight: .bold)
	}
}
