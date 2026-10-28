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

	/// Whether sendPicture works (the front ends then offer pasted images).
	var supportsPictures: Bool { get }
	func sendPicture(to peer: String, data: Data, filename: String) async
	/// Earlier messages with `peer` from before this sign-in, oldest first;
	/// empty where the service keeps no history (MSNP).
	func recentMessages(with peer: String, limit: Int) async -> [IMHistoryMessage]
}

/// A message from before this sign-in, for a conversation window's history.
public struct IMHistoryMessage {
	public var sender: String
	public var senderName: String
	public var text: String
	public var format: TextFormat
	/// An image message's picture (encoded); `text` then names it.
	public var picture: Data?
	public var date: Date
	public var outgoing: Bool

	public init(sender: String, senderName: String, text: String, format: TextFormat = TextFormat(),
	            picture: Data? = nil, date: Date, outgoing: Bool) {
		self.sender = sender
		self.senderName = senderName
		self.text = text
		self.format = format
		self.picture = picture
		self.date = date
		self.outgoing = outgoing
	}
}

public extension IMService {
	func signIn(email: String, password: String, status: Presence = .online) async throws {
		try await signIn(email: email, password: password, status: status, personalMessage: nil)
	}

	func sendMessage(to peer: String, text: String) async {
		await sendMessage(to: peer, text: text, format: TextFormat())
	}

	var supportsPictures: Bool { false }

	func sendPicture(to peer: String, data: Data, filename: String) async {
		onEvent?(.conversation(peer: peer, .deliveryFailed(text: filename, reason: "Pictures can't be sent on this service.")))
	}

	func recentMessages(with peer: String, limit: Int) async -> [IMHistoryMessage] { [] }
}

extension MessengerClient: IMService {
	/// Display pictures travel over MSNP P2P, which this port doesn't implement.
	public var displayPicture: Data? { nil }
}
