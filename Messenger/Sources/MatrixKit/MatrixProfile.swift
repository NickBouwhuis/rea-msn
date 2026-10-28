import Foundation
import MSNKit

/// Messenger for Matrix: the WLM windows on a Matrix account.
public struct MatrixProfile: IMServiceProfile {
	public init() {}

	public var appName: String { "Messenger for Matrix" }
	public var identifier: String { "matrix" }
	public var accountLabel: String { "Matrix ID:" }
	public var contactExample: String { "@someone:matrix.org" }
	public var connection: IMConnectionKind { .matrixHomeserver }
	public var forgotPasswordURL: URL? { nil }
	public var serviceStatusURL: URL? { nil }
	public var announcesLocalDisplayPicture: Bool { false }

	public func problem(withAccount account: String) -> String? {
		MatrixID.isUserID(account.lowercased()) ? nil : "Please type your Matrix ID, such as @you:matrix.org."
	}

	public func problem(withContact address: String) -> String? {
		MatrixID.isUserID(address) ? nil : "Please type a Matrix ID, such as @someone:matrix.org."
	}

	/// The client decides: a saved session or the browser need none.
	public func allowsEmptyPassword(for account: String) -> Bool { true }

	public func passwordNote(for account: String, homeserver: URL?) async -> String? {
		let id = account.trimmingCharacters(in: .whitespaces).lowercased()
		guard let server = MatrixID.serverName(of: id),
		      let method = try? await MatrixClient.signInMethod(for: id, homeserver: homeserver) else { return nil }
		switch method {
		case .password: return nil
		case .browser: return "Sign in opens your web browser, where \(server) asks for your password."
		#if canImport(MatrixRustSDK)
		case .savedSession: return "You're already signed in to \(server) on this computer."
		#endif
		}
	}

	public func makeClient(_ settings: IMConnectionSettings) -> any IMService {
		#if canImport(MatrixRustSDK)
		// MESSENGER_MATRIX_EPHEMERAL=1 (development): keep nothing, not even in the Keychain.
		let client: MatrixClient
		if ProcessInfo.processInfo.environment["MESSENGER_MATRIX_EPHEMERAL"] != nil {
			client = .throwaway(homeserver: settings.homeserver)
		} else {
			client = MatrixClient(homeserver: settings.homeserver)
			// Without "Remember me", signing out also logs this device out.
			client.keepsSessionOnSignOut = settings.rememberMe
		}
		#else
		let client = MatrixClient(homeserver: settings.homeserver)
		#endif
		client.openURL = settings.openURL
		return client
	}
}
