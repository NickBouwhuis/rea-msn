import Foundation
import MSNKit

/// Persisted preferences (Tools ▸ Options in WLM).
struct AppSettings: Codable, Equatable {
	enum ServerChoice: String, Codable, CaseIterable, Identifiable {
		case escargot, local, custom
		var id: String { rawValue }
		var title: String {
			switch self {
			case .escargot: return "Escargot (escargot.chat)"
			case .local: return "Local dev server (Docker)"
			case .custom: return "Custom"
			}
		}
	}

	var server: ServerChoice = .escargot
	var customNSHost = "msnmsgr.escargot.chat"
	var customNSPort: UInt16 = 1863
	var customHTTPBase = "https://msnmsgr.escargot.chat"
	/// For @user:server sign-ins; nil finds the homeserver through the server's .well-known.
	var matrixHomeserver: String?

	var rememberedAccounts: [String] = []
	var lastAccount: String?
	var rememberPassword = false
	var signInAutomatically = false
	var signInStatus: Presence = .online

	var playSounds = true
	var showToasts = true
	var sortByGroups = true
	var showOfflineContacts = true
	var convertEmoticons = true

	var serverConfig: ServerConfig {
		switch server {
		case .escargot: return .escargot
		case .local: return .localDev
		case .custom:
			let base = URL(string: customHTTPBase) ?? ServerConfig.escargot.loginBaseURL
			return ServerConfig(nsHost: customNSHost, nsPort: customNSPort, loginBaseURL: base, contactsBaseURL: base)
		}
	}

	var matrixHomeserverURL: URL? {
		matrixHomeserver.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : URL(string: $0) }
	}

	private static let key = "settings.v1"

	static func load() -> AppSettings {
		guard let data = UserDefaults.standard.data(forKey: key),
		      let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
		return s
	}

	func save() {
		UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
	}
}
