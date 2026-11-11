import CGtk
import Foundation
import MSNKit

struct Settings: Codable {
	enum Server: String, Codable { case escargot, local, custom }
	var server: Server = .escargot
	var customHost = "127.0.0.1"
	/// For @user:server sign-ins; nil finds the homeserver through the server's .well-known.
	var matrixHomeserver: String?
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

	var matrixHomeserverURL: URL? {
		matrixHomeserver.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : URL(string: $0) }
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
		return config.appendingPathComponent("\(AppState.storageName)/settings.json")
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
		case picture(senderName: String, data: Data, outgoing: Bool)
		/// Left while we were offline; shown as "X says (time):".
		case offline(senderName: String, text: String, sent: Date?)
		/// A wink's preview image (WLM's winks are Flash animations).
		case wink(senderName: String, image: Data?)
	}
	let kind: Kind
	let date = Date()
}

/// Shared state between MSNKit and the GTK windows (the Linux AppModel).
@MainActor
final class AppState {
	enum Phase: Equatable { case signedOut, signingIn(String), signedIn }

	/// The service this app is built for, and where it keeps its settings,
	/// pictures and passwords (set by MessengerGTKLauncher before anything else).
	static var profile: IMServiceProfile = EscargotProfile()
	nonisolated(unsafe) static var storageName = "messenger-wlm"
	static let shared = AppState()
	let profile: IMServiceProfile = AppState.profile

	/// The GApplication ID; the Escargot app keeps the one install.sh registers.
	static var applicationID: String {
		profile.identifier == "escargot" ? "chat.messenger.wlm81" : "chat.messenger.wlm81.\(profile.identifier)"
	}

	var app: Ptr!
	var settings = Settings.load() { didSet { settings.save() } }
	private(set) var phase: Phase = .signedOut
	var signInError: String?
	private(set) var client: (any IMService)?
	private(set) var contacts: [Contact] = []
	/// Group conversations that stay (Matrix rooms), kept apart from the people.
	private(set) var groupChats: [Contact] = []
	private(set) var groups: [ABGroup] = []
	private(set) var myEmail = ""
	private(set) var myName = ""
	private(set) var myMessage = ""
	private(set) var myStatus: Presence = .offline
	var addRequests: [(email: String, name: String)] = []
	/// Matrix with encryption: this session isn't cross-signed yet, and the
	/// verification dialog's step (nil: no dialog).
	private(set) var sessionUnverified = false
	var verification: Verification? { didSet { onVerification?() } }
	var onVerification: (() -> Void)?
	private var promptedVerification = false

	enum Verification: Equatable {
		case prompt
		case waiting(String)
		/// Another of your sessions asks to verify this one.
		case incoming(String)
		case emojis([Emoji])
		case recoveryKey
		case done
		case failed(String)
	}

	struct Emoji: Equatable {
		let symbol: String
		let name: String
	}

	/// Listeners the windows register.
	var onPhase: [() -> Void] = []
	var onContacts: [() -> Void] = []
	var onProfile: [() -> Void] = []
	var onPictures: [() -> Void] = []
	var onAddRequest: (() -> Void)?

	private(set) var conversations: [String: ConversationWindow] = [:]

	// MARK: Sign in

	func signIn(email rawEmail: String, password: String, status: Presence, rememberMe: Bool, rememberPassword: Bool) {
		let email = rawEmail.trimmingCharacters(in: .whitespaces).lowercased()
		// Some services sign in without a password here (the browser).
		guard !email.isEmpty, !password.isEmpty || profile.allowsEmptyPassword(for: email) else {
			signInError = "Please type your \(profile.accountLabel.lowercased().trimmingCharacters(in: [":"])) and password."
			notify(onPhase)
			return
		}
		if let problem = profile.problem(withAccount: email) {
			signInError = problem
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
		if !rememberPassword { SecretStore.delete(email) } else if !password.isEmpty { SecretStore.set(password, for: email) }

		let client = profile.makeClient(IMConnectionSettings(
			msnServer: settings.serverConfig, homeserver: settings.matrixHomeserverURL, rememberMe: rememberMe,
			openURL: { url in gtk_uri_launcher_launch(gtk_uri_launcher_new(url.absoluteString), nil, nil, nil, nil) }))
		if ProcessInfo.processInfo.environment["MESSENGER_DEBUG"] != nil {
			client.log = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }  // unbuffered
		}
		if let verifier = client as? IMVerifying {
			verifier.onVerification = { [weak self] in self?.handleVerification($0) }
			promptedVerification = false
		}
		client.onEvent = { [weak self] in self?.handle($0) }
		client.displayPictureDirectory = Self.dataDirectory.appendingPathComponent("Pictures", isDirectory: true)
		self.client = client
		myEmail = email
		phase = .signingIn("Signing in...")
		notify(onPhase)
		Task {
			do {
				// MSN advertises the picture kept on this computer; a Matrix
				// account's picture lives on the server.
				if profile.announcesLocalDisplayPicture { await client.setDisplayPicture(try? Data(contentsOf: myPictureURL)) }
				try await client.signIn(email: email, password: password, status: status)
			} catch {
				guard self.client === client else { return }  // cancelled
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
		verification = nil
		sessionUnverified = false
		client?.signOut()
		client = nil
		for w in conversations.values { w.close() }
		conversations.removeAll()
		contacts = []
		groupChats = []
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

	private func run(_ op: @escaping (any IMService) async throws -> Void) {
		guard let client else { return }
		Task {
			do { try await op(client) } catch { self.alert(error.localizedDescription) }
		}
	}

	func contact(_ email: String) -> Contact? { client?.contacts[email] }

	func name(of email: String) -> String {
		if email == myEmail { return myName }
		return client?.bestName(of: email, fallback: conversations[email]?.peerName) ?? conversations[email]?.peerName ?? email
	}

	// MARK: Display pictures

	static var dataDirectory: URL {
		(ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
			?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share"))
			.appendingPathComponent(storageName, isDirectory: true)
	}

	/// Our display picture, one per account as in WLM.
	private var myPictureURL: URL {
		Self.dataDirectory.appendingPathComponent("DisplayPictures", isDirectory: true).appendingPathComponent("\(myEmail).png")
	}

	/// Someone's display picture (ours for our own address), if we have it.
	func displayPicture(of email: String) -> Data? {
		email == myEmail ? (client?.displayPicture ?? (try? Data(contentsOf: myPictureURL))) : client?.displayPicture(of: email)
	}

	func chooseDisplayPicture() {
		chooseFiles(parent: mainWindow, title: Skin.shared.string(2092, "Select a Display Picture"), multiple: false, imagesOnly: true) { [weak self] paths in
			guard let path = paths.first else { return }
			guard let png = tilePNG(path: path) else {
				self?.alert("That picture couldn't be opened.")
				return
			}
			self?.setDisplayPicture(png)
		}
	}

	func setDisplayPicture(_ png: Data?) {
		try? FileManager.default.createDirectory(at: myPictureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		if let png { try? png.write(to: myPictureURL) } else { try? FileManager.default.removeItem(at: myPictureURL) }
		picturesChanged()
		guard let client else { return }
		Task { await client.setDisplayPicture(png) }
	}

	private func picturesChanged() {
		notify(onPictures)
		for w in conversations.values { w.refreshPictures() }
	}

	// MARK: Conversations

	@discardableResult
	func openConversation(_ peer: String, present: Bool = true) -> ConversationWindow {
		let w = conversations[peer] ?? {
			let w = ConversationWindow(peer: peer)
			conversations[peer] = w
			client?.requestDisplayPicture(of: peer)
			if let c = contact(peer), !c.status.isOnline { tellOffline(w) }
			return w
		}()
		if present { w.present() }
		return w
	}

	/// "X appears to be offline. Messages you send will be delivered when they sign in.", once.
	private func tellOffline(_ w: ConversationWindow) {
		guard !w.toldOffline else { return }
		w.toldOffline = true
		let text = Skin.shared.string(20088, "%1 appears to be offline. Messages you send will be delivered when they sign in.")
			.replacingOccurrences(of: #"\s*\{A:\d+\}( \| \{A:\d+\})*"#, with: "", options: .regularExpression)
		w.post(.notice(text.replacingOccurrences(of: "%1", with: name(of: w.peer))))
	}

	func participants(with peer: String) -> [String] {
		client?.participants(inConversationWith: peer) ?? [peer]
	}

	func invite(_ email: String, into peer: String) {
		guard let client else { return }
		Task {
			do {
				// Matrix makes a group of its own for the three of you: carry on there.
				let group = try await client.invite(email, into: peer)
				if group != peer { self.openConversation(group) }
			} catch {
				self.conversations[peer]?.post(.notice(Skin.shared.string(2074, "Your invitation to join this conversation could not be delivered to %1.")
					.replacingOccurrences(of: "%1", with: self.name(of: email))))
			}
		}
	}

	func startGroup(named name: String) {
		guard let client else { return }
		Task {
			do { self.openConversation(try await client.createGroup(named: name)) } catch { self.alert(error.localizedDescription) }
		}
	}

	func renameGroup(_ id: String, to name: String) { run { try await $0.renameGroup(id, to: name) } }

	// MARK: Files

	func sendFiles(_ paths: [String], to peer: String) {
		guard let client else { return }
		for path in paths {
			do { try client.sendFile(URL(fileURLWithPath: path), to: peer) } catch {
				conversations[peer]?.post(.notice(Skin.shared.string(2105, "The invitation could not be sent.")))
			}
		}
	}

	func acceptFile(_ t: FileTransfer) { client?.acceptFile(t.id, saveTo: Self.downloadURL(for: t.name)) }
	func declineFile(_ t: FileTransfer) { client?.declineFile(t.id) }
	func cancelFile(_ t: FileTransfer) { client?.cancelFile(t.id) }

	/// ~/Downloads/name (or the XDG download folder), "name 2" etc. if taken.
	static func downloadURL(for name: String) -> URL {
		let dir = g_get_user_special_dir(G_USER_DIRECTORY_DOWNLOAD).map { URL(fileURLWithPath: String(cString: $0)) }
			?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
		var url = dir.appendingPathComponent(name)
		var n = 2
		while FileManager.default.fileExists(atPath: url.path) {
			url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
			n += 1
		}
		return url
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

	// MARK: Session verification (services with end-to-end encryption)

	private var verifier: IMVerifying? { client as? IMVerifying }

	private func handleVerification(_ event: IMVerificationEvent) {
		switch event {
		case let .state(verified):
			sessionUnverified = !verified
			if verified {
				if verification != nil { verification = .done }
			} else if !promptedVerification {
				promptedVerification = true
				verification = .prompt
			}
			notify(onContacts)  // the menu offers "Verify this session" while it's needed
		case let .requested(device):
			verification = .incoming(device)
		case let .emojis(list):
			verification = .emojis(list.map { Emoji(symbol: $0.symbol, name: $0.description) })
		case .finished:
			verification = .done
		case let .cancelled(why):
			if verification != nil, verification != .done {
				verification = .failed(why ?? "The verification was cancelled.")
			}
		}
	}

	func verifyWithOtherSession() {
		verification = .waiting("Open Element (or another app you're signed in to) and accept the verification request there.")
		Task {
			do { try await verifier?.requestVerification() } catch { verification = .failed(error.localizedDescription) }
		}
	}

	func acceptIncomingVerification() {
		verification = .waiting("Waiting for your other session...")
		Task {
			do { try await verifier?.acceptVerification() } catch { verification = .failed(error.localizedDescription) }
		}
	}

	func confirmEmojis(_ match: Bool) {
		verification = match ? .waiting("Waiting for your other session to confirm...")
			: .failed("The emoji didn't match, so this session wasn't verified.")
		Task {
			do { try await verifier?.confirmVerification(match) } catch { verification = .failed(error.localizedDescription) }
		}
	}

	func recover(_ key: String) {
		verification = .waiting("Checking your recovery key...")
		Task {
			do {
				try await verifier?.recover(recoveryKey: key)
				verification = .done
			} catch {
				verification = .failed("That recovery key didn't work. (\(error.localizedDescription))")
			}
		}
	}

	func closeVerification() {
		switch verification {
		case .waiting?, .incoming?, .emojis?: Task { await verifier?.cancelVerification() }
		default: break
		}
		verification = nil
	}

	// MARK: Events

	private func refresh() {
		guard let client else { return }
		let listed = client.contacts.values.filter(\.isForward)
			.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
		contacts = listed.filter { !$0.isGroup }
		groupChats = listed.filter(\.isGroup)
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
		case .displayPictureChanged:
			picturesChanged()
		case let .signedOut(reason):
			verification = nil
			sessionUnverified = false
			for w in conversations.values { w.close() }
			conversations.removeAll()
			contacts = []
			groupChats = []
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
		case let .joined(email, _):
			guard let w = conversations[peer] else { return }
			let wasIn = w.participants.contains(email)
			w.updateParticipants(participants(with: peer))
			if !wasIn, email != peer {
				w.post(.notice(Skin.shared.string(2032, "%1 has been added to the conversation.").replacingOccurrences(of: "%1", with: name(of: email))))
			}
		case let .left(email):
			guard let w = conversations[peer] else { return }
			let wasGroup = w.participants.count > 1
			w.updateParticipants(participants(with: peer))
			if email != peer || wasGroup {
				w.post(.notice(Skin.shared.string(2033, "%1 has left the conversation.").replacingOccurrences(of: "%1", with: name(of: email))))
			}
		case let .deliveryFailed(text, reason):
			openConversation(peer, present: false).post(.failed(text: text, reason: reason))
		case let .picture(from, name, data, _):
			let isNew = conversations[peer] == nil
			let w = openConversation(peer, present: isNew)
			if from == peer { w.peerName = name }
			w.post(.picture(senderName: name, data: data, outgoing: false))
			if !w.isActive {
				Sounds.play("type")
				notifyDesktop(title: "\(name) sent a picture", body: "", id: "msg-\(peer)")
			}
		case let .offlineMessage(_, name, text, sent):
			let isNew = conversations[peer] == nil
			let w = openConversation(peer, present: isNew)
			if peer == w.peer { w.peerName = name }
			w.refreshHeader()
			w.post(.offline(senderName: name, text: text, sent: sent))
			if !w.isActive {
				Sounds.play("type")
				notifyDesktop(title: "\(name) says:", body: text, id: "msg-\(peer)")
			}
		case .storedOffline:
			if let w = conversations[peer] { tellOffline(w) }
		case let .file(t):
			let w = openConversation(peer, present: t.incoming && t.state == .offered && conversations[peer] == nil)
			w.showTransfer(t)
			if t.incoming, t.state == .offered, !w.isActive {
				Sounds.play("type")
				notifyDesktop(title: name(of: t.peer), body: "wants to send you \"\(t.name)\" (\(t.sizeText)).", id: "file-\(t.id)")
			}
		case let .wink(_, name, thumbnail):
			let w = openConversation(peer, present: conversations[peer] == nil)
			w.post(.wink(senderName: name, image: thumbnail))
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
		tool(["lookup", "application", AppState.storageName, "account", account]).flatMap { $0.isEmpty ? nil : $0 }
	}

	static func set(_ password: String, for account: String) {
		_ = tool(["store", "--label=Messenger (\(account))", "application", AppState.storageName, "account", account], input: password)
	}

	static func delete(_ account: String) {
		_ = tool(["clear", "application", AppState.storageName, "account", account])
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
