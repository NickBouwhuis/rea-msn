import Foundation

/// The events every service reports. They were MessengerClient's first, so the
/// MSNP client keeps its nested names; other services (MatrixKit) use these.
public typealias IMState = MessengerClient.State
public typealias IMEvent = MessengerClient.Event
public typealias IMConversationEvent = MessengerClient.ConversationEvent

/// What the front ends need from a signed-in session: MessengerClient speaks
/// MSNP15 to Escargot, MatrixKit's MatrixClient the Matrix client-server API.
/// Contacts are keyed by `email`, which for Matrix is the user ID (@user:server).
@MainActor
public protocol IMService: AnyObject {
	var state: IMState { get }
	var email: String { get }
	var displayName: String { get }
	var personalMessage: String { get }
	var status: Presence { get }
	/// Your display picture as an encoded image; nil shows the default tile.
	var displayPicture: Data? { get }
	var contacts: [String: Contact] { get }
	var groups: [ABGroup] { get }
	var onEvent: ((IMEvent) -> Void)? { get set }
	var log: ((String) -> Void)? { get set }

	func signIn(email: String, password: String, status: Presence, personalMessage: String?) async throws
	func signOut()

	func setStatus(_ presence: Presence) async throws
	func setDisplayName(_ name: String) async throws
	func setPersonalMessage(_ text: String) async throws

	func addContact(_ email: String) async throws
	func respondToAdd(_ email: String, allow: Bool, addToList: Bool) async throws
	func removeContact(_ email: String) async throws
	func block(_ email: String) async throws
	func unblock(_ email: String) async throws

	func sendMessage(to peer: String, text: String, format: TextFormat) async
	func sendTyping(to peer: String)
	func sendNudge(to peer: String) async throws
	func closeConversation(with peer: String)
}

public extension IMService {
	func signIn(email: String, password: String, status: Presence = .online) async throws {
		try await signIn(email: email, password: password, status: status, personalMessage: nil)
	}

	func sendMessage(to peer: String, text: String) async {
		await sendMessage(to: peer, text: text, format: TextFormat())
	}
}

extension MessengerClient: IMService {
	/// Display pictures travel over MSNP P2P, which this port doesn't implement.
	public var displayPicture: Data? { nil }
}
