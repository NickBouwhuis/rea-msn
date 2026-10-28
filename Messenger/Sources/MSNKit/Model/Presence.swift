import Foundation

/// MSNP status codes (`CHG`, `ILN`, `NLN`). The mapping from WLM's internal
/// state enum to these codes is in CMNSNet::SetLocalState (msnmsgr.exe 0x52fe66).
public enum Presence: String, CaseIterable, Codable, Hashable {
	case online = "NLN"
	case busy = "BSY"
	case beRightBack = "BRB"
	case away = "AWY"
	case onThePhone = "PHN"
	case outToLunch = "LUN"
	case idle = "IDL"
	case appearOffline = "HDN"
	case offline = "FLN"

	public var displayName: String {
		switch self {
		case .online: return "Online"
		case .busy: return "Busy"
		case .beRightBack: return "Be Right Back"
		case .away: return "Away"
		case .onThePhone: return "On the Phone"
		case .outToLunch: return "Out to Lunch"
		case .idle: return "Away"
		case .appearOffline: return "Appear Offline"
		case .offline: return "Offline"
		}
	}

	/// Statuses a user can pick from the sign-in/status menus (WLM 8.1 order).
	public static let selectable: [Presence] = [.online, .busy, .beRightBack, .away, .onThePhone, .outToLunch, .appearOffline]

	public var isOnline: Bool { self != .offline && self != .appearOffline }

	public enum Tint { case green, red, orange, gray }

	public var tint: Tint {
		switch self {
		case .online: return .green
		case .busy, .onThePhone: return .red
		case .beRightBack, .away, .outToLunch, .idle: return .orange
		case .appearOffline, .offline: return .gray
		}
	}
}

public struct Contact: Identifiable, Hashable {
	public var id: String { email }
	public var email: String
	public var contactID: String?
	public var displayName: String
	public var personalMessage: String = ""
	public var currentMedia: String = ""
	public var status: Presence = .offline
	public var lists: MSNList = []
	public var groupIDs: [String] = []
	public var capabilities: UInt32 = 0

	public init(email: String, displayName: String? = nil) {
		self.email = email.lowercased()
		self.displayName = displayName ?? email
	}

	public var isBlocked: Bool { lists.contains(.block) }
	/// On my contact list (as opposed to only having added me).
	public var isForward: Bool { lists.contains(.forward) }
}

/// WLM 8.1 identity. CVR is formatted as `%lu %s %s %lu.%lu %s %s%s%s %s %s %s`
/// (msnmsgr.exe 0x4a91a3); capabilities come from FUN_0052faa8.
public enum ClientIdentity {
	public static let protocolVersions = ["MSNP15", "MSNP14", "MSNP13"]
	public static let locale = "0x0409"
	public static let clientName = "MSNMSGR"
	public static let clientVersion = "8.1.0178"

	/// FUN_0052faa8 starts from 0x7048C024 and always ORs 0x06000000; the high
	/// nibble 7 is the MSNC7 (WLM 8.1) P2P version. This port implements text
	/// IM only, so it advertises MSNC7 + multi-packet messaging (0x20) and not
	/// ink/webcam/P2P feature bits that would invite unsupported sessions.
	public static let wlm81Capabilities: UInt32 = 0x7648_C024
	public static let advertisedCapabilities: UInt32 = 0x7000_0020

	public static func cvrArguments(email: String) -> [String] {
		[locale, "winnt", "5.1", "i386", clientName, clientVersion, "msmsgs", email]
	}
}
