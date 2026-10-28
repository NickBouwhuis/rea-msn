import Foundation
import Security

/// "Remember my password" storage (WLM kept this in the Windows Credential Manager).
enum Keychain {
	private static let service = "MessengerMac"

	static func password(for account: String) -> String? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne,
		]
		var item: CFTypeRef?
		guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
		return String(data: data, encoding: .utf8)
	}

	static func setPassword(_ password: String, for account: String) {
		deletePassword(for: account)
		let attrs: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecValueData as String: Data(password.utf8),
			kSecAttrLabel as String: "Messenger (\(account))",
		]
		SecItemAdd(attrs as CFDictionary, nil)
	}

	static func deletePassword(for account: String) {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
		]
		SecItemDelete(query as CFDictionary)
	}
}
