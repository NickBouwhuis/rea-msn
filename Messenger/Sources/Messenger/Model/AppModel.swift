import AppKit
import MSNKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
	enum Phase: Equatable {
		case signedOut
		case signingIn(String)
		case signedIn
	}

	struct AddRequest: Identifiable, Equatable {
		var id: String { email }
		let email: String
		let displayName: String
	}

	@Published var settings = AppSettings.load() {
		didSet { settings.save() }
	}
	@Published private(set) var phase: Phase = .signedOut
	@Published var signInError: String?
	@Published private(set) var myEmail = ""
	@Published private(set) var myName = ""
	@Published private(set) var myMessage = ""
	@Published private(set) var myStatus: Presence = .offline
	@Published private(set) var contacts: [Contact] = []
	@Published private(set) var groups: [ABGroup] = []
	@Published var addRequests: [AddRequest] = []
	@Published var alert: String?

	private(set) var client: MessengerClient?
	private(set) var conversations: [String: ConversationModel] = [:]
	lazy var windows = ConversationWindows(app: self)
	let toasts = ToastCenter()
	let sounds = SoundPlayer()

	static let shared = AppModel()

	// MARK: - Sign in

	func signIn(email: String, password: String, status: Presence, rememberMe: Bool, rememberPassword: Bool, auto: Bool) {
		let email = email.trimmingCharacters(in: .whitespaces).lowercased()
		guard !email.isEmpty, !password.isEmpty else {
			signInError = "Please type your e-mail address and password."
			return
		}
		signInError = nil
		var s = settings
		s.lastAccount = email
		s.signInStatus = status
		s.rememberPassword = rememberPassword
		s.signInAutomatically = auto && rememberPassword
		if rememberMe, !s.rememberedAccounts.contains(email) { s.rememberedAccounts.insert(email, at: 0) }
		if !rememberMe { s.rememberedAccounts.removeAll { $0 == email } }
		settings = s
		if rememberPassword { Keychain.setPassword(password, for: email) } else { Keychain.deletePassword(for: email) }

		let client = MessengerClient(config: settings.serverConfig)
		if ProcessInfo.processInfo.environment["MESSENGER_DEBUG"] != nil {
			client.log = { print($0) }
		}
		client.onEvent = { [weak self] in self?.handle($0) }
		self.client = client
		myEmail = email
		phase = .signingIn("Signing in...")
		Task {
			do {
				try await client.signIn(email: email, password: password, status: status)
			} catch {
				self.client = nil
				self.phase = .signedOut
				self.signInError = Self.friendly(error)
			}
		}
	}

	func cancelSignIn() {
		client?.signOut()
		client = nil
		phase = .signedOut
	}

	func signOut() {
		client?.signOut()
		client = nil
		windows.closeAll()
		conversations.removeAll()
		contacts = []
		addRequests = []
		phase = .signedOut
		settings.signInAutomatically = false
	}

	static func friendly(_ error: Error) -> String {
		if let e = error as? PassportError, case .authenticationFailed = e {
			return "We can't sign you in to Windows Live Messenger. The e-mail address or password is incorrect. (80048821)"
		}
		if let e = error as? MSNPError {
			switch e {
			case .connectFailed, .timeout, .disconnected:
				return "We can't sign you in to Windows Live Messenger. The service is temporarily unavailable or your network is down. (\(e.localizedDescription))"
			default: break
			}
		}
		return "We can't sign you in to Windows Live Messenger. \(error.localizedDescription)"
	}

	// MARK: - Profile

	func setStatus(_ p: Presence) {
		guard let client else { return }
		Task { do { try await client.setStatus(p) } catch { self.alert = error.localizedDescription } }
	}

	func setName(_ name: String) {
		guard let client, !name.isEmpty, name != myName else { return }
		Task { do { try await client.setDisplayName(name) } catch { self.alert = error.localizedDescription } }
	}

	func setPersonalMessage(_ text: String) {
		guard let client, text != myMessage else { return }
		Task { do { try await client.setPersonalMessage(text) } catch { self.alert = error.localizedDescription } }
	}

	// MARK: - Contacts

	func addContact(_ email: String) {
		guard let client else { return }
		let email = email.trimmingCharacters(in: .whitespaces).lowercased()
		guard email.contains("@"), email.contains(".") else {
			alert = "Please type a valid e-mail address, such as someone@example.com."
			return
		}
		Task {
			do { try await client.addContact(email) } catch { self.alert = "Couldn't add \(email): \(error.localizedDescription)" }
		}
	}

	func removeContact(_ email: String, block: Bool) {
		guard let client else { return }
		Task {
			do {
				if block { try await client.block(email) }
				try await client.removeContact(email)
			} catch { self.alert = error.localizedDescription }
		}
	}

	func setBlocked(_ email: String, _ blocked: Bool) {
		guard let client else { return }
		Task {
			do { if blocked { try await client.block(email) } else { try await client.unblock(email) } }
			catch { self.alert = error.localizedDescription }
		}
	}

	func respond(to request: AddRequest, allow: Bool, addToList: Bool) {
		addRequests.removeAll { $0.email == request.email }
		guard let client else { return }
		Task {
			do { try await client.respondToAdd(request.email, allow: allow, addToList: addToList) }
			catch { self.alert = error.localizedDescription }
		}
	}

	func contact(_ email: String) -> Contact? {
		client?.contacts[email]
	}

	func name(of email: String) -> String {
		email == myEmail ? myName : (contact(email)?.displayName ?? conversations[email]?.peerName ?? email)
	}

	// MARK: - Conversations

	func conversation(with peer: String) -> ConversationModel {
		if let c = conversations[peer] { return c }
		let c = ConversationModel(peer: peer)
		conversations[peer] = c
		return c
	}

	func openConversation(_ peer: String, activate: Bool = true) {
		windows.show(conversation(with: peer), activate: activate)
	}

	func send(_ text: String, to peer: String) {
		guard let client, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
		let convo = conversation(with: peer)
		convo.append(.message(sender: myEmail, senderName: myName, text: text, format: convo.format, outgoing: true))
		sounds.play(.outgoing)
		Task { await client.sendMessage(to: peer, text: text, format: convo.format) }
	}

	func userIsTyping(to peer: String) {
		client?.sendTyping(to: peer)
	}

	func nudge(_ peer: String) {
		guard let client else { return }
		conversation(with: peer).append(.nudge(senderName: myName, outgoing: true))
		windows.shake(peer)
		sounds.play(.nudge)
		Task {
			do { try await client.sendNudge(to: peer) }
			catch { self.conversation(with: peer).append(.notice("The nudge could not be delivered: \(error.localizedDescription)")) }
		}
	}

	func conversationClosed(_ peer: String) {
		client?.closeConversation(with: peer)
	}

	// MARK: - Events

	private func refreshContacts() {
		guard let client else { return }
		contacts = client.contacts.values
			.filter { $0.isForward }
			.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
		groups = client.groups
	}

	private func refreshProfile() {
		guard let client else { return }
		myName = client.displayName
		myMessage = client.personalMessage
		myStatus = client.status
	}

	private func handle(_ event: MessengerClient.Event) {
		switch event {
		case let .stateChanged(state):
			switch state {
			case .signedOut: if phase != .signedOut { phase = .signedOut }
			case let .signingIn(msg): phase = .signingIn(msg)
			case .signedIn:
				phase = .signedIn
				refreshProfile()
				refreshContacts()
			}
		case .contactListLoaded:
			refreshContacts()
		case .profileChanged:
			refreshProfile()
		case let .contactUpdated(c, previous):
			refreshContacts()
			if phase == .signedIn, c.isForward, !previous.isOnline, c.status.isOnline {
				sounds.play(.online)
				if settings.showToasts {
					toasts.show(title: c.displayName, body: "has just signed in.", peer: c.email) { [weak self] in
						self?.openConversation(c.email)
					}
				}
			}
			if let convo = conversations[c.email], previous != c.status {
				if previous.isOnline, !c.status.isOnline {
					convo.append(.notice("\(c.displayName) has signed out."))
				} else if !previous.isOnline, c.status.isOnline {
					convo.append(.notice("\(c.displayName) has signed in."))
				}
			}
		case let .contactRemoved(email):
			refreshContacts()
			conversations[email]?.append(.notice("\(email) was removed from your contact list."))
		case let .addedBy(email, name):
			if !addRequests.contains(where: { $0.email == email }) {
				addRequests.append(AddRequest(email: email, displayName: name))
			}
			NSApp.requestUserAttention(.informationalRequest)
		case let .conversation(peer, event):
			handleConversation(peer, event)
		case let .signedOut(reason):
			windows.closeAll()
			conversations.removeAll()
			contacts = []
			client = nil
			phase = .signedOut
			signInError = reason
		}
	}

	private func handleConversation(_ peer: String, _ event: MessengerClient.ConversationEvent) {
		let convo = conversation(with: peer)
		switch event {
		case let .message(from, name, text, format):
			let isNew = !windows.isOpen(peer)
			convo.append(.message(sender: from, senderName: name, text: text, format: format, outgoing: false))
			openConversation(peer, activate: false)
			if !windows.isKey(peer) {
				sounds.play(isNew ? .newConversation : .incoming)
				NSApp.requestUserAttention(.informationalRequest)
				if settings.showToasts {
					toasts.show(title: "\(name) says:", body: text, peer: peer) { [weak self] in
						self?.openConversation(peer)
					}
				}
			}
		case let .typing(from):
			convo.typing(from, name: name(of: from))
		case let .nudge(from):
			convo.append(.nudge(senderName: name(of: from), outgoing: false))
			openConversation(peer, activate: false)
			windows.shake(peer)
			sounds.play(.nudge)
		case .joined:
			break
		case let .left(email):
			if conversations[peer] != nil, windows.isOpen(peer), email != peer {
				convo.append(.notice("\(name(of: email)) has left the conversation."))
			}
		case let .deliveryFailed(text, reason):
			convo.append(.failed(text: text, reason: reason))
		}
	}
}
