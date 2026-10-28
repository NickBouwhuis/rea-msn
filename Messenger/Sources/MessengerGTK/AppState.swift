import CGtk
import Foundation
import MSNKit

struct Settings: Codable {
	enum Server: String, Codable { case escargot, local, custom }
	var server: Server = .escargot
	var customHost = "127.0.0.1"
	var rememberedAccounts: [String] = []
	var lastAccount: String?
	var rememberPassword = false
	var signInStatus: Presence = .online
	var playSounds = true
	var showNotifications = true

	var serverConfig: ServerConfig {
		switch server {
		case .escargot: return .escargot
		case .local: return .localDev
		case .custom:
			let base = URL(string: "http://\(customHost):8081")!
			return ServerConfig(nsHost: customHost, loginBaseURL: base, contactsBaseURL: base)
		}
	}

	var serverName: String {
		switch server {
		case .escargot: return "escargot.chat"
		case .local: return "local dev server"
		case .custom: return customHost
		}
	}

	static var file: URL {
		let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
			?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
		return config.appendingPathComponent("messenger-wlm/settings.json")
	}

	static func load() -> Settings {
		(try? JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))) ?? Settings()
	}

	func save() {
		try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
		try? JSONEncoder().encode(self).write(to: Self.file)
	}
}

struct ChatLine {
	enum Kind {
		case message(senderName: String, text: String, format: TextFormat, outgoing: Bool)
		case nudge(name: String, outgoing: Bool)
		case notice(String)
		case failed(text: String, reason: String)
	}
	let kind: Kind
	let date = Date()
}

/// Shared state between MSNKit and the GTK windows (the Linux AppModel).
@MainActor
final class AppState {
	enum Phase: Equatable { case signedOut, signingIn(String), signedIn }

	static let shared = AppState()

	var app: Ptr!
	var settings = Settings.load() { didSet { settings.save() } }
	private(set) var phase: Phase = .signedOut
	var signInError: String?
	private(set) var client: MessengerClient?
	private(set) var contacts: [Contact] = []
	private(set) var groups: [ABGroup] = []
	private(set) var myEmail = ""
	private(set) var myName = ""
	private(set) var myMessage = ""
	private(set) var myStatus: Presence = .offline
	var addRequests: [(email: String, name: String)] = []

	/// Listeners the windows register.
	var onPhase: [() -> Void] = []
	var onContacts: [() -> Void] = []
	var onProfile: [() -> Void] = []
	var onAddRequest: (() -> Void)?

	private(set) var conversations: [String: ConversationWindow] = [:]

	// MARK: Sign in

	func signIn(email rawEmail: String, password: String, status: Presence, rememberMe: Bool, rememberPassword: Bool) {
		let email = rawEmail.trimmingCharacters(in: .whitespaces).lowercased()
		guard !email.isEmpty, !password.isEmpty else {
			signInError = "Please type your e-mail address and password."
			notify(onPhase)
			return
		}
		signInError = nil
		var s = settings
		s.lastAccount = email
		s.signInStatus = status
		s.rememberPassword = rememberPassword
		s.rememberedAccounts.removeAll { $0 == email }
		if rememberMe { s.rememberedAccounts.insert(email, at: 0) }
		settings = s
		if rememberPassword { SecretStore.set(password, for: email) } else { SecretStore.delete(email) }

		let client = MessengerClient(config: settings.serverConfig)
		if ProcessInfo.processInfo.environment["MESSENGER_DEBUG"] != nil { client.log = { print($0) } }
		client.onEvent = { [weak self] in self?.handle($0) }
		self.client = client
		myEmail = email
		phase = .signingIn("Signing in...")
		notify(onPhase)
		Task {
			do {
				try await client.signIn(email: email, password: password, status: status)
			} catch {
				self.client = nil
				self.phase = .signedOut
				self.signInError = Self.friendly(error)
				self.notify(self.onPhase)
			}
		}
	}

	func cancelSignIn() {
		client?.signOut()
		client = nil
		phase = .signedOut
		notify(onPhase)
	}

	func signOut() {
		client?.signOut()
		client = nil
		for w in conversations.values { w.close() }
		conversations.removeAll()
		contacts = []
		phase = .signedOut
		notify(onPhase)
	}

	static func friendly(_ error: Error) -> String {
		if let e = error as? PassportError, case .authenticationFailed = e {
			return "We can't sign you in to Windows Live Messenger. The e-mail address or password is incorrect. (80048821)"
		}
		return "We can't sign you in to Windows Live Messenger. \(error.localizedDescription)"
	}

	// MARK: Profile & contacts

	func setStatus(_ p: Presence) { run { try await $0.setStatus(p) } }
	func setName(_ n: String) { run { try await $0.setDisplayName(n) } }
	func setPersonalMessage(_ m: String) { run { try await $0.setPersonalMessage(m) } }
	func addContact(_ email: String) { run { try await $0.addContact(email) } }
	func removeContact(_ email: String) { run { try await $0.removeContact(email) } }
	func setBlocked(_ email: String, _ blocked: Bool) { run { blocked ? try await $0.block(email) : try await $0.unblock(email) } }
	func respond(_ email: String, allow: Bool, add: Bool) {
		addRequests.removeAll { $0.email == email }
		run { try await $0.respondToAdd(email, allow: allow, addToList: allow && add) }
	}

	private func run(_ op: @escaping (MessengerClient) async throws -> Void) {
		guard let client else { return }
		Task {
			do { try await op(client) } catch { self.alert(error.localizedDescription) }
		}
	}

	func contact(_ email: String) -> Contact? { client?.contacts[email] }

	func name(of email: String) -> String {
		email == myEmail ? myName : (contact(email)?.displayName ?? conversations[email]?.peerName ?? email)
	}

	// MARK: Conversations

	@discardableResult
	func openConversation(_ peer: String, present: Bool = true) -> ConversationWindow {
		let w = conversations[peer] ?? {
			let w = ConversationWindow(peer: peer)
			conversations[peer] = w
			return w
		}()
		if present { w.present() }
		return w
	}

	func conversationClosed(_ peer: String) {
		conversations[peer] = nil
		client?.closeConversation(with: peer)
	}

	func send(_ text: String, to peer: String, format: TextFormat) {
		guard let client, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
		openConversation(peer, present: false).post(.message(senderName: myName, text: text, format: format, outgoing: true))
		Task { await client.sendMessage(to: peer, text: text, format: format) }
	}

	func typing(to peer: String) { client?.sendTyping(to: peer) }

	func nudge(_ peer: String) {
		guard let client else { return }
		let w = openConversation(peer, present: false)
		w.post(.nudge(name: myName, outgoing: true))
		w.shake()
		Sounds.play("nudge")
		Task {
			do { try await client.sendNudge(to: peer) }
			catch { w.post(.notice("The nudge could not be delivered: \(error.localizedDescription)")) }
		}
	}

	// MARK: Events

	private func refresh() {
		guard let client else { return }
		contacts = client.contacts.values.filter(\.isForward)
			.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
		groups = client.groups
		myName = client.displayName
		myMessage = client.personalMessage
		myStatus = client.status
	}

	private func handle(_ event: MessengerClient.Event) {
		switch event {
		case let .stateChanged(s):
			switch s {
			case .signedOut: if phase != .signedOut { phase = .signedOut; notify(onPhase) }
			case let .signingIn(m): phase = .signingIn(m); notify(onPhase)
			case .signedIn:
				refresh()
				phase = .signedIn
				notify(onPhase)
				notify(onContacts)
				notify(onProfile)
			}
		case .contactListLoaded:
			refresh(); notify(onContacts)
		case .profileChanged:
			refresh(); notify(onProfile)
		case let .contactUpdated(c, previous):
			refresh(); notify(onContacts)
			if phase == .signedIn, c.isForward, !previous.isOnline, c.status.isOnline {
				Sounds.play("online")
				notifyDesktop(title: c.displayName, body: "has just signed in.", id: "online-\(c.email)")
			}
			if let w = conversations[c.email] {
				w.refreshHeader()
				if previous.isOnline, !c.status.isOnline {
					w.post(.notice("\(c.displayName) has signed out."))
				} else if !previous.isOnline, c.status.isOnline {
					w.post(.notice("\(c.displayName) has signed in."))
				}
			}
		case let .contactRemoved(email):
			refresh(); notify(onContacts)
			conversations[email]?.post(.notice("\(email) was removed from your contact list."))
		case let .addedBy(email, name):
			if !addRequests.contains(where: { $0.email == email }) {
				addRequests.append((email, name))
				onAddRequest?()
			}
		case let .conversation(peer, ev):
			handleConversation(peer, ev)
		case let .signedOut(reason):
			for w in conversations.values { w.close() }
			conversations.removeAll()
			contacts = []
			client = nil
			phase = .signedOut
			signInError = reason
			notify(onPhase)
		}
	}

	private func handleConversation(_ peer: String, _ ev: MessengerClient.ConversationEvent) {
		switch ev {
		case let .message(from, name, text, format):
			let isNew = conversations[peer] == nil
			let w = openConversation(peer, present: isNew)
			if from == peer { w.peerName = name }
			w.post(.message(senderName: name, text: text, format: format, outgoing: false))
			if !w.isActive {
				Sounds.play("type")
				notifyDesktop(title: "\(name) says:", body: text, id: "msg-\(peer)")
			}
		case let .typing(from):
			conversations[peer]?.typing(name(of: from))
		case let .nudge(from):
			let w = openConversation(peer, present: true)
			w.post(.nudge(name: name(of: from), outgoing: false))
			w.shake()
			Sounds.play("nudge")
		case .joined:
			break
		case let .left(email):
			if email != peer { conversations[peer]?.post(.notice("\(name(of: email)) has left the conversation.")) }
		case let .deliveryFailed(text, reason):
			openConversation(peer, present: false).post(.failed(text: text, reason: reason))
		}
	}

	private func notify(_ listeners: [() -> Void]) { listeners.forEach { $0() } }

	// MARK: Desktop integration

	func notifyDesktop(title: String, body: String, id: String) {
		guard settings.showNotifications, let app else { return }
		let n = g_notification_new(title)
		g_notification_set_body(n, body)
		if let icon = Skin.shared.appIcon {
			let file = g_file_new_for_path(icon)
			let gicon = g_file_icon_new(file)
			g_notification_set_icon(n, gicon)
			g_object_unref(UnsafeMutableRawPointer(gicon))
			g_object_unref(UnsafeMutableRawPointer(file))
		}
		g_application_send_notification(c(app), id, n)
		g_object_unref(UnsafeMutableRawPointer(n))
	}

	var mainWindow: Ptr?

	func alert(_ message: String) {
		Dialog.alert(message, parent: mainWindow)
	}
}

/// "Remember my password" via libsecret's secret-tool, when installed.
enum SecretStore {
	private static func tool(_ args: [String], input: String? = nil) -> String? {
		let p = Process()
		p.executableURL = URL(fileURLWithPath: "/usr/bin/secret-tool")
		guard FileManager.default.isExecutableFile(atPath: p.executableURL!.path) else { return nil }
		p.arguments = args
		let out = Pipe(), inp = Pipe()
		p.standardOutput = out
		p.standardInput = inp
		p.standardError = FileHandle.nullDevice
		do { try p.run() } catch { return nil }
		if let input { inp.fileHandleForWriting.write(Data(input.utf8)) }
		try? inp.fileHandleForWriting.close()
		p.waitUntilExit()
		guard p.terminationStatus == 0 else { return nil }
		return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
	}

	static func get(_ account: String) -> String? {
		tool(["lookup", "application", "messenger-wlm", "account", account]).flatMap { $0.isEmpty ? nil : $0 }
	}

	static func set(_ password: String, for account: String) {
		_ = tool(["store", "--label=Messenger (\(account))", "application", "messenger-wlm", "account", account], input: password)
	}

	static func delete(_ account: String) {
		_ = tool(["clear", "application", "messenger-wlm", "account", account])
	}
}

/// WLM sounds imported from your installer (WAV), played with PipeWire/PulseAudio.
@MainActor
enum Sounds {
	static var dir: URL { Skin.shared.root.deletingLastPathComponent().appendingPathComponent("Sounds") }

	static func play(_ name: String) {
		guard AppState.shared.settings.playSounds else { return }
		let file = dir.appendingPathComponent("\(name).wav").path
		guard FileManager.default.fileExists(atPath: file) else { return }
		for player in ["/usr/bin/pw-play", "/usr/bin/paplay", "/usr/bin/aplay"] where FileManager.default.isExecutableFile(atPath: player) {
			let p = Process()
			p.executableURL = URL(fileURLWithPath: player)
			p.arguments = [file]
			p.standardOutput = FileHandle.nullDevice
			p.standardError = FileHandle.nullDevice
			try? p.run()
			return
		}
	}
}
