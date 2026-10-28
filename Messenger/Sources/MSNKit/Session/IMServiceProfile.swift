import Foundation

/// What a front end needs to know about the one service it is built for. The
/// same windows make two apps: Messenger (Escargot, `EscargotProfile`) and
/// Messenger for Matrix (MatrixKit's `MatrixProfile`).
@MainActor
public protocol IMServiceProfile {
	/// The app's name in titles and messages.
	var appName: String { get }
	/// Short, file-system safe: settings folders, Keychain and desktop IDs.
	var identifier: String { get }
	/// The sign-in box's label.
	var accountLabel: String { get }
	/// An example address, for "Add a contact".
	var contactExample: String { get }
	var connection: IMConnectionKind { get }
	var forgotPasswordURL: URL? { get }
	var serviceStatusURL: URL? { get }
	/// MSNP: the display picture saved on this computer is announced at
	/// sign-in. Elsewhere it lives on the server.
	var announcesLocalDisplayPicture: Bool { get }

	/// nil when `account` can sign in here, else what to tell the user.
	func problem(withAccount account: String) -> String?
	/// nil when `address` can be added as a contact, else what to tell the user.
	func problem(withContact address: String) -> String?
	/// Whether signIn may be given an empty password (the client then signs in
	/// another way: a saved session, the browser).
	func allowsEmptyPassword(for account: String) -> Bool
	/// Shown instead of the password box when this account doesn't need one
	/// here; nil asks for the password.
	func passwordNote(for account: String, homeserver: URL?) async -> String?
	func makeClient(_ settings: IMConnectionSettings) -> any IMService
}

/// Which connection settings the sign-in window and Options offer.
public enum IMConnectionKind: Sendable {
	/// Escargot, the local dev server, or another MSN server.
	case msnServer
	/// A Matrix homeserver URL, found from the user ID when left empty.
	case matrixHomeserver
}

/// Everything a profile needs to make a client for one sign-in.
public struct IMConnectionSettings {
	public var msnServer: ServerConfig
	public var homeserver: URL?
	/// "Remember me": whether signing out keeps what the service keeps (Matrix: the session).
	public var rememberMe: Bool
	/// Opens a URL in the browser (Matrix browser sign-in).
	public var openURL: (URL) -> Void

	public init(msnServer: ServerConfig, homeserver: URL?, rememberMe: Bool, openURL: @escaping (URL) -> Void) {
		self.msnServer = msnServer
		self.homeserver = homeserver
		self.rememberMe = rememberMe
		self.openURL = openURL
	}
}

/// Windows Live Messenger on Escargot (MSNP15), the original app.
public struct EscargotProfile: IMServiceProfile {
	public init() {}

	public var appName: String { "Windows Live Messenger" }
	public var identifier: String { "escargot" }
	public var accountLabel: String { "E-mail address:" }
	public var contactExample: String { "someone@escargot.chat" }
	public var connection: IMConnectionKind { .msnServer }
	public var forgotPasswordURL: URL? { URL(string: "https://escargot.chat/forgot/") }
	public var serviceStatusURL: URL? { URL(string: "https://escargot.chat/") }
	public var announcesLocalDisplayPicture: Bool { true }

	public func problem(withAccount account: String) -> String? { nil }

	public func problem(withContact address: String) -> String? {
		address.contains("@") && address.contains(".") ? nil : "Please type a valid e-mail address, such as someone@example.com."
	}

	public func allowsEmptyPassword(for account: String) -> Bool { false }
	public func passwordNote(for account: String, homeserver: URL?) async -> String? { nil }

	public func makeClient(_ settings: IMConnectionSettings) -> any IMService {
		MessengerClient(config: settings.msnServer)
	}
}

/// Verifying this session with another of yours (emoji) or a recovery key,
/// for services with end-to-end encryption (MatrixKit on matrix-rust-sdk).
public enum IMVerificationEvent {
	/// Whether this session is verified; others may not share keys with it until it is.
	case state(verified: Bool)
	/// Another of your sessions asks to verify this one.
	case requested(by: String)
	/// Both sessions show these; compare them.
	case emojis([(symbol: String, description: String)])
	case finished
	case cancelled(String?)
}

@MainActor
public protocol IMVerifying: AnyObject {
	var onVerification: ((IMVerificationEvent) -> Void)? { get set }
	/// Asks your other sessions to verify this one.
	func requestVerification() async throws
	/// Accepts another session's request to verify this one.
	func acceptVerification() async throws
	/// The emoji match (or not) on both screens.
	func confirmVerification(_ match: Bool) async throws
	func cancelVerification() async
	/// Verifies this session with the recovery key.
	func recover(recoveryKey: String) async throws
}
