import AppKit
import MatrixKit
import MSNKit
import SwiftUI
import UniformTypeIdentifiers

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
	/// Matrix: this session isn't cross-signed yet, and the verification dialog's step.
	@Published private(set) var sessionUnverified = false
	@Published var verification: Verification? {
		didSet { verificationWindow.update() }
	}
	private var promptedVerification = false
	private lazy var verificationWindow = VerificationWindow(app: self)
	/// Bumped when any display picture changes, so views showing them redraw.
	@Published private(set) var pictureVersion = 0
	private var pictureImages: [String: (data: Data, image: NSImage)] = [:]

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

	struct Emoji: Equatable, Hashable {
		let symbol: String
		let name: String
	}

	private(set) var client: (any IMService)?
	private(set) var conversations: [String: ConversationModel] = [:]
	lazy var windows = ConversationWindows(app: self)
	let toasts = ToastCenter()
	let sounds = SoundPlayer()

	static let shared = AppModel()

	// MARK: - Sign in

	func signIn(email: String, password: String, status: Presence, rememberMe: Bool, rememberPassword: Bool, auto: Bool) {
		let email = email.trimmingCharacters(in: .whitespaces).lowercased()
		// Matrix homeservers may sign in through the browser instead, with no password here.
		guard !email.isEmpty, !password.isEmpty || MatrixID.isUserID(email) else {
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
		if !rememberPassword { Keychain.deletePassword(for: email) } else if !password.isEmpty { Keychain.setPassword(password, for: email) }

		// A Matrix ID (@user:server) signs in to Matrix; anything else to the MSN service.
		let client: any IMService
		if MatrixID.isUserID(email) {
			// MESSENGER_MATRIX_EPHEMERAL=1 (development): keep nothing, not even in the Keychain.
			let matrix = ProcessInfo.processInfo.environment["MESSENGER_MATRIX_EPHEMERAL"] != nil
				? MatrixClient.throwaway(homeserver: settings.matrixHomeserverURL)
				: MatrixClient(homeserver: settings.matrixHomeserverURL)
			matrix.openURL = { NSWorkspace.shared.open($0) }
			// Without "Remember me", signing out also logs this device out.
			matrix.keepsSessionOnSignOut = rememberMe
			matrix.onVerification = { [weak self] in self?.handleVerification($0) }
			promptedVerification = false
			client = matrix
		} else {
			client = MessengerClient(config: settings.serverConfig)
		}
		if ProcessInfo.processInfo.environment["MESSENGER_DEBUG"] != nil {
			client.log = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }  // unbuffered
		}
		client.onEvent = { [weak self] in self?.handle($0) }
		client.displayPictureDirectory = Self.supportDirectory.appendingPathComponent("Pictures", isDirectory: true)
		self.client = client
		myEmail = email
		phase = .signingIn("Signing in...")
		Task {
			do {
				// MSN advertises the picture kept on this computer; a Matrix
				// account's picture lives on the server (changed through chooseDisplayPicture).
				if client is MessengerClient { await client.setDisplayPicture(try? Data(contentsOf: myPictureURL)) }
				try await client.signIn(email: email, password: password, status: status)
				NSApp.activate(ignoringOtherApps: true)  // back from the browser after a browser sign-in
			} catch {
				guard self.client === client else { return }  // cancelled
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
		verification = nil
		sessionUnverified = false
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

	// MARK: - Display pictures

	static var supportDirectory: URL {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("MessengerMac", isDirectory: true)
	}

	/// Our display picture, one per account as in WLM.
	private var myPictureURL: URL {
		Self.supportDirectory.appendingPathComponent("DisplayPictures", isDirectory: true).appendingPathComponent("\(myEmail).png")
	}

	/// Someone's display picture (ours for our own address), if we have it.
	func displayPicture(of email: String) -> NSImage? {
		_ = pictureVersion
		let data = email == myEmail ? (client?.displayPicture ?? (try? Data(contentsOf: myPictureURL))) : client?.displayPicture(of: email)
		guard let data else { return nil }
		if let hit = pictureImages[email], hit.data == data { return hit.image }
		guard let image = NSImage(data: data) else { return nil }
		pictureImages[email] = (data, image)
		return image
	}

	func chooseDisplayPicture() {
		let panel = NSOpenPanel()
		panel.title = Skin.shared.string(2092, "Select a Display Picture")
		panel.allowedContentTypes = [.image]
		panel.allowsMultipleSelection = false
		guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url), let png = Self.tilePNG(image) else { return }
		setDisplayPicture(png)
	}

	func setDisplayPicture(_ png: Data?) {
		try? FileManager.default.createDirectory(at: myPictureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		if let png { try? png.write(to: myPictureURL) } else { try? FileManager.default.removeItem(at: myPictureURL) }
		pictureVersion += 1
		guard let client else { return }
		Task { await client.setDisplayPicture(png) }
	}

	/// WLM's display pictures are 96×96: centre-cropped and scaled, as PNG.
	static func tilePNG(_ image: NSImage) -> Data? {
		let side = 96
		guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
		                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
		                                 bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
		let size = image.size, crop = min(size.width, size.height)
		image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
		           from: NSRect(x: (size.width - crop) / 2, y: (size.height - crop) / 2, width: crop, height: crop),
		           operation: .copy, fraction: 1)
		NSGraphicsContext.restoreGraphicsState()
		return rep.representation(using: .png, properties: [:])
	}

	// MARK: - Contacts

	func addContact(_ email: String) {
		guard let client else { return }
		let email = email.trimmingCharacters(in: .whitespaces).lowercased()
		guard MatrixID.isUserID(email) || (email.contains("@") && email.contains(".")) else {
			alert = "Please type a valid e-mail address, such as someone@example.com, or a Matrix ID, such as @someone:matrix.org."
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
		if email == myEmail { return myName }
		return client?.bestName(of: email, fallback: conversations[email]?.peerName) ?? conversations[email]?.peerName ?? email
	}

	// MARK: - Conversations

	func conversation(with peer: String) -> ConversationModel {
		if let c = conversations[peer] { return c }
		let c = ConversationModel(peer: peer)
		conversations[peer] = c
		loadHistory(c)
		return c
	}

	/// The last messages from before this sign-in (Matrix keeps history; MSNP doesn't).
	private func loadHistory(_ convo: ConversationModel) {
		guard let client else { return }
		Task {
			let history = await client.recentMessages(with: convo.peer, limit: 30)
			guard !history.isEmpty, conversations[convo.peer] === convo, !convo.historyLoaded else { return }
			convo.prependHistory(history.map { m in
				let kind: ChatLine.Kind = m.picture.map { .picture(sender: m.sender, senderName: m.senderName, data: $0, outgoing: m.outgoing) }
					?? .message(sender: m.sender, senderName: m.senderName, text: m.text, format: m.format, outgoing: m.outgoing)
				return ChatLine(kind: kind, date: m.date, isHistory: true)
			})
		}
	}

	private func reloadHistory(_ convo: ConversationModel) {
		convo.dropHistory()
		loadHistory(convo)
	}

	/// Whether the current service can send pasted pictures.
	var supportsPictures: Bool { client?.supportsPictures ?? false }

	func sendPicture(_ picture: PendingPicture, to peer: String) {
		guard let client else { return }
		conversation(with: peer).append(.picture(sender: myEmail, senderName: myName, data: picture.data, outgoing: true))
		sounds.play(.outgoing)
		Task { await client.sendPicture(to: peer, data: picture.data, filename: picture.filename) }
	}

	func openConversation(_ peer: String, activate: Bool = true) {
		let convo = conversation(with: peer)
		windows.show(convo, activate: activate)
		client?.requestDisplayPicture(of: peer)
		if let c = contact(peer), !c.status.isOnline { tellOffline(convo) }
	}

	/// "X appears to be offline. Messages you send will be delivered when they sign in.", once.
	private func tellOffline(_ convo: ConversationModel) {
		guard !convo.toldOffline else { return }
		convo.toldOffline = true
		let text = Skin.shared.string(20088, "%1 appears to be offline. Messages you send will be delivered when they sign in.")
			.replacingOccurrences(of: #"\s*\{A:\d+\}( \| \{A:\d+\})*"#, with: "", options: .regularExpression)
		convo.append(.notice(text.replacingOccurrences(of: "%1", with: name(of: convo.peer))))
	}

	func invite(_ email: String, into peer: String) {
		guard let client else { return }
		Task {
			do { try await client.invite(email, into: peer) } catch {
				self.conversation(with: peer).append(.notice(Skin.shared.string(2074, "Your invitation to join this conversation could not be delivered to %1.")
					.replacingOccurrences(of: "%1", with: self.name(of: email))))
			}
		}
	}

	// MARK: - Files

	func sendFiles(_ urls: [URL], to peer: String) {
		guard let client else { return }
		for url in urls {
			do { try client.sendFile(url, to: peer) } catch {
				conversation(with: peer).append(.notice(Skin.shared.string(2105, "The invitation could not be sent.")))
			}
		}
	}

	func acceptFile(_ t: FileTransfer) { client?.acceptFile(t.id, saveTo: Self.downloadURL(for: t.name)) }
	func declineFile(_ t: FileTransfer) { client?.declineFile(t.id) }
	func cancelFile(_ t: FileTransfer) { client?.cancelFile(t.id) }

	func openFile(_ t: FileTransfer) {
		if let url = t.fileURL { NSWorkspace.shared.open(url) }
	}

	func revealFile(_ t: FileTransfer) {
		if let url = t.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
	}

	/// ~/Downloads/name, or "name 2" etc. if that's taken.
	static func downloadURL(for name: String) -> URL {
		let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
		let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
		var url = dir.appendingPathComponent(name)
		var n = 2
		while FileManager.default.fileExists(atPath: url.path) {
			url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
			n += 1
		}
		return url
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

	// MARK: - Matrix session verification

	private var matrix: MatrixClient? { client as? MatrixClient }

	private func handleVerification(_ event: MatrixClient.VerificationEvent) {
		switch event {
		case let .state(verified):
			let wasUnverified = sessionUnverified
			sessionUnverified = !verified
			if verified {
				if verification != nil { verification = .done }
				// Verified now: keys for older messages come from your other sessions
				// and key backup, so show the history again once they've had a moment.
				if wasUnverified {
					Task {
						try? await Task.sleep(nanoseconds: 5_000_000_000)
						for convo in conversations.values { reloadHistory(convo) }
					}
				}
			} else if !promptedVerification {
				promptedVerification = true
				verification = .prompt
			}
		case let .requested(device):
			verification = .incoming(device)
			NSApp.requestUserAttention(.informationalRequest)
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
			do { try await matrix?.requestVerification() } catch { verification = .failed(error.localizedDescription) }
		}
	}

	func acceptIncomingVerification() {
		verification = .waiting("Waiting for your other session...")
		Task {
			do { try await matrix?.acceptVerification() } catch { verification = .failed(error.localizedDescription) }
		}
	}

	func confirmEmojis(_ match: Bool) {
		verification = match ? .waiting("Waiting for your other session to confirm...")
			: .failed("The emoji didn't match, so this session wasn't verified.")
		Task {
			do { try await matrix?.confirmVerification(match) } catch { verification = .failed(error.localizedDescription) }
		}
	}

	func recover(_ key: String) {
		verification = .waiting("Checking your recovery key...")
		Task {
			do {
				try await matrix?.recover(recoveryKey: key)
				verification = .done
			} catch {
				verification = .failed("That recovery key didn't work. (\(error.localizedDescription))")
			}
		}
	}

	func closeVerification() {
		switch verification {
		case .waiting?, .incoming?, .emojis?: Task { await matrix?.cancelVerification() }
		default: break
		}
		verification = nil
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
		case .displayPictureChanged:
			pictureVersion += 1
		case let .signedOut(reason):
			verification = nil
			sessionUnverified = false
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
		case let .picture(from, name, data, _):
			let isNew = !windows.isOpen(peer)
			convo.append(.picture(sender: from, senderName: name, data: data, outgoing: false))
			openConversation(peer, activate: false)
			if !windows.isKey(peer) {
				sounds.play(isNew ? .newConversation : .incoming)
				NSApp.requestUserAttention(.informationalRequest)
				if settings.showToasts {
					toasts.show(title: "\(name) sent a picture", body: "", peer: peer) { [weak self] in
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
		case let .joined(email, _):
			let wasIn = convo.participants.contains(email)
			convo.participants = client?.participants(inConversationWith: peer) ?? [peer]
			if !wasIn, email != peer {
				convo.append(.notice(Skin.shared.string(2032, "%1 has been added to the conversation.").replacingOccurrences(of: "%1", with: name(of: email))))
			}
		case let .left(email):
			let wasGroup = convo.participants.count > 1
			convo.participants = client?.participants(inConversationWith: peer) ?? [peer]
			if conversations[peer] != nil, windows.isOpen(peer), email != peer || wasGroup {
				convo.append(.notice(Skin.shared.string(2033, "%1 has left the conversation.").replacingOccurrences(of: "%1", with: name(of: email))))
			}
		case let .deliveryFailed(text, reason):
			convo.append(.failed(text: text, reason: reason))
		case let .offlineMessage(from, name, text, sent):
			convo.append(.offline(sender: from, senderName: name, text: text, sent: sent))
			openConversation(peer, activate: false)
			if !windows.isKey(peer) {
				sounds.play(.newConversation)
				if settings.showToasts {
					toasts.show(title: "\(name) says:", body: text, peer: peer) { [weak self] in self?.openConversation(peer) }
				}
			}
		case .storedOffline:
			tellOffline(convo)
		case let .file(t):
			convo.update(t)
			if t.incoming, t.state == .offered {
				openConversation(peer, activate: false)
				sounds.play(.incoming)
				NSApp.requestUserAttention(.informationalRequest)
			}
		case let .wink(_, name, thumbnail):
			convo.append(.wink(senderName: name, image: thumbnail))
			openConversation(peer, activate: false)
			if !windows.isKey(peer) { sounds.play(.incoming) }
		}
	}
}
