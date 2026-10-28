import Foundation
import MSNKit

struct ChatLine: Identifiable, Equatable {
	enum Kind: Equatable {
		case message(sender: String, senderName: String, text: String, format: TextFormat, outgoing: Bool)
		case nudge(senderName: String, outgoing: Bool)
		case notice(String)
		case failed(text: String, reason: String)
		/// Left while we were offline; shown as "X says (time):".
		case offline(sender: String, senderName: String, text: String, sent: Date?)
		/// A file transfer; its current state is in `ConversationModel.transfers`.
		case file(id: String)
		/// A wink's preview image (WLM's winks are Flash animations).
		case wink(senderName: String, image: Data?)
	}

	let id = UUID()
	let date = Date()
	let kind: Kind
}

/// One conversation window's state, keyed by the peer's e-mail.
@MainActor
final class ConversationModel: ObservableObject, Identifiable {
	nonisolated let peer: String
	nonisolated var id: String { peer }
	@Published private(set) var lines: [ChatLine] = []
	@Published private(set) var typingNames: [String] = []
	@Published private(set) var lastReceived: Date?
	/// Friendly name seen on the switchboard, for peers not on the contact list.
	@Published private(set) var peerName: String?
	@Published var draft = ""
	@Published var format = ConversationModel.savedFormat
	/// Everyone in the conversation besides us (more than one: a group conversation).
	@Published var participants: [String]
	@Published private(set) var transfers: [String: FileTransfer] = [:]
	/// Whether we've said this contact is offline and messages will wait for them.
	var toldOffline = false
	private var typingExpiry: [String: Task<Void, Never>] = [:]

	init(peer: String) {
		self.peer = peer
		participants = [peer]
	}

	/// Adds a transfer's line the first time it's seen, then keeps its state current.
	func update(_ t: FileTransfer) {
		if transfers[t.id] == nil { lines.append(ChatLine(kind: .file(id: t.id))) }
		transfers[t.id] = t
	}

	func append(_ kind: ChatLine.Kind) {
		lines.append(ChatLine(kind: kind))
		if case let .message(sender, senderName, _, _, outgoing) = kind, !outgoing {
			lastReceived = Date()
			if sender == peer { peerName = senderName }
			stopTyping(sender)
		}
		if case let .offline(sender, senderName, _, _) = kind, sender == peer { peerName = senderName }
	}

	/// WLM shows "X is typing a message." for ~6 s after each control message.
	func typing(_ email: String, name: String) {
		if !typingNames.contains(name) { typingNames.append(name) }
		typingExpiry[email]?.cancel()
		typingExpiry[email] = Task { [weak self] in
			try? await Task.sleep(nanoseconds: 6_000_000_000)
			guard !Task.isCancelled else { return }
			self?.typingNames.removeAll { $0 == name }
		}
	}

	private func stopTyping(_ email: String) {
		typingExpiry.removeValue(forKey: email)?.cancel()
		typingNames.removeAll()
	}

	static var savedFormat: TextFormat {
		get {
			guard let data = UserDefaults.standard.data(forKey: "messageFormat"),
			      let f = try? JSONDecoder().decode(TextFormat.self, from: data) else { return TextFormat() }
			return f
		}
		set {
			UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "messageFormat")
		}
	}
}
