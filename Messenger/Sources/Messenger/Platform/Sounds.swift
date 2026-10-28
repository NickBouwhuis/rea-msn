import AppKit

/// WLM 8.1 sound events. The original .wma files (online, type, nudge, ...)
/// can be imported from your own installer with scripts/import-wlm-sounds.sh;
/// otherwise macOS system sounds stand in.
@MainActor
final class SoundPlayer {
	enum Cue: String, CaseIterable {
		case online, newConversation = "type", incoming = "type_followup", outgoing, nudge, newEmail = "newemail"

		var fallback: String {
			switch self {
			case .online: return "Glass"
			case .newConversation, .incoming: return "Pop"
			case .outgoing: return "Tink"
			case .nudge: return "Sosumi"
			case .newEmail: return "Submarine"
			}
		}
	}

	var enabled: () -> Bool = { AppModel.shared.settings.playSounds }
	private var cache: [Cue: NSSound] = [:]

	static var importedSoundsDirectory: URL {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("MessengerMac/Sounds", isDirectory: true)
	}

	func play(_ cue: Cue) {
		guard enabled() else { return }
		if cue == .outgoing, imported(.outgoing) == nil { return }  // WLM is silent on send unless themed
		let sound = cache[cue] ?? load(cue)
		cache[cue] = sound
		sound?.stop()
		sound?.play()
	}

	private func imported(_ cue: Cue) -> URL? {
		let name = cue == .incoming ? Cue.newConversation.rawValue : cue.rawValue
		for ext in ["m4a", "aiff", "wav", "mp3"] {
			let url = Self.importedSoundsDirectory.appendingPathComponent("\(name).\(ext)")
			if FileManager.default.fileExists(atPath: url.path) { return url }
		}
		return nil
	}

	private func load(_ cue: Cue) -> NSSound? {
		if let url = imported(cue) { return NSSound(contentsOf: url, byReference: true) }
		return NSSound(named: cue.fallback)
	}
}
