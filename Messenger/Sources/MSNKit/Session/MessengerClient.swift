import Foundation

/// High-level WLM 8.1-equivalent client: Passport SSO, NS session, ABCH
/// contact list and a pool of switboards keyed by conversation peer.
@MainActor
public final class MessengerClient {
	public enum State: Equatable {
		case signedOut
		case signingIn(String)
		case signedIn
	}

	public enum ConversationEvent {
		case message(from: String, displayName: String, text: String, format: TextFormat)
		case typing(from: String)
		case nudge(from: String)
		case joined(email: String, displayName: String)
		case left(email: String)
		case deliveryFailed(text: String, reason: String)
	}

	public enum Event {
		case stateChanged(State)
		case contactListLoaded
		case contactUpdated(Contact, previousStatus: Presence)
		case contactRemoved(email: String)
		case profileChanged
		/// Someone put us on their list (RL/PL) and we have not allowed or blocked them.
		case addedBy(email: String, displayName: String)
		case conversation(peer: String, ConversationEvent)
		case signedOut(reason: String?)
	}

	public let config: ServerConfig
	public private(set) var state: State = .signedOut
	public private(set) var email = ""
	public private(set) var displayName = ""
	public private(set) var personalMessage = ""
	public private(set) var status: Presence = .offline
	public private(set) var contacts: [String: Contact] = [:]
	public private(set) var groups: [ABGroup] = []

	public var onEvent: ((Event) -> Void)?
	public var log: ((String) -> Void)?

	private var ns: MSNPConnection?
	private var tokens: PassportTokens?
	private var addressBook: ABService?
	private var storage: StorageService?
	private var profileResourceID: String?
	private var privacyMode: String?
	private var knownDisplayName = false
	private var knownPersonalMessage = false
	private var switchboards: [String: SwitchboardSession] = [:]
	private var openingSwitchboards: [String: Task<SwitchboardSession, Error>] = [:]
	private var pingTask: Task<Void, Never>?
	private var signingOut = false
	public let machineGUID = "{\(UUID().uuidString)}"

	public init(config: ServerConfig) {
		self.config = config
	}

	// MARK: - Sign in / out

	/// Signing in re-announces only what the server already has (roaming name and
	/// message from the Storage service, privacy mode from the address book), so
	/// it never overwrites the account's profile. Pass `personalMessage` to set one.
	public func signIn(email rawEmail: String, password: String, status initialStatus: Presence = .online, personalMessage psm: String? = nil) async throws {
		guard state == .signedOut else { return }
		personalMessage = psm ?? ""
		knownPersonalMessage = psm != nil
		knownDisplayName = false
		let email = rawEmail.trimmingCharacters(in: .whitespaces).lowercased()
		self.email = email
		signingOut = false
		setState(.signingIn("Connecting..."))
		do {
			// Passport runs alongside the NS handshake, as msidcrl does in WLM.
			let passport = Task { try await PassportAuth(config: config).requestTokens(email: email, password: password) }
			let conn = try await connectNotificationServer(email: email, passport: passport)
			ns = conn
			setState(.signingIn("Loading contacts..."))
			try await loadContactList()
			try await announcePresence(initialStatus)
			startPing()
			setState(.signedIn)
		} catch {
			tearDown()
			setState(.signedOut)
			throw error
		}
	}

	private func connectNotificationServer(email: String, passport: Task<PassportTokens, Error>) async throws -> MSNPConnection {
		var host = config.nsHost
		var port = config.nsPort
		for _ in 0..<4 {
			let conn = MSNPConnection(host: host, port: port)
			conn.log = log.map { l in { l("[NS] " + $0) } }
			try await conn.connect()

			let ver = try await conn.request("VER", ClientIdentity.protocolVersions + ["CVR0"])
			guard ver.args.count >= 2, ver.args[1] == "MSNP15" else {
				conn.close()
				throw MSNPError.unexpected("server does not support MSNP15 (\(ver))")
			}
			_ = try await conn.request("CVR", ClientIdentity.cvrArguments(email: email))
			let usr = try await conn.request("USR", ["SSO", "I", email])
			if usr.name == "XFR", usr.args.count >= 3, usr.args[1] == "NS" {
				// XFR trid NS host:port 0 current-host:port — the NS wants us elsewhere.
				(host, port) = SwitchboardSession.parseHostPort(usr.args[2])
				conn.close()
				continue
			}
			guard usr.name == "USR", usr.args.count >= 5, usr.args[1] == "SSO", usr.args[2] == "S" else {
				throw MSNPError.unexpected("\(usr)")
			}
			let nonce = usr.args[4]
			setState(.signingIn("Signing in..."))
			let tokens = try await passport.value
			guard let mc = tokens.messengerClear, let secret = mc.binarySecret else {
				throw PassportError.badResponse("no proof key for messengerclear.live.com")
			}
			self.tokens = tokens
			let blob = try MBICrypto.ssoResponse(binarySecret: secret, nonce: nonce)
			let ok: MSNPCommand
			do {
				ok = try await conn.request("USR", ["SSO", "S", mc.ticket, blob])
			} catch MSNPError.server(911, _) {
				throw PassportError.authenticationFailed
			}
			guard ok.args.count >= 2, ok.args[1] == "OK" else { throw MSNPError.unexpected("\(ok)") }

			conn.onCommand = { [weak self] in self?.handleNotification($0) }
			conn.onClose = { [weak self] error in self?.notificationClosed(error) }
			return conn
		}
		throw MSNPError.unexpected("too many NS redirects")
	}

	private func loadContactList() async throws {
		guard let ticket = tokens?.contacts?.ticket else { throw PassportError.badResponse("no contacts.msn.com ticket") }
		let ab = ABService(config: config, ticket: ticket)
		addressBook = ab
		let book = try await ab.fetchAddressBook()

		var result: [String: Contact] = [:]
		for c in book.contacts {
			var contact = Contact(email: c.email, displayName: c.displayName)
			contact.contactID = c.contactID
			contact.groupIDs = c.groupIDs
			contact.lists.insert(.forward)
			result[c.email] = contact
		}
		for (email, lists) in book.memberships {
			result[email, default: Contact(email: email, displayName: book.memberDisplayNames[email])].lists.formUnion(lists)
		}
		contacts = result
		groups = book.groups
		privacyMode = book.privacyMode
		if let name = book.meDisplayName, !name.isEmpty {
			displayName = name
			knownDisplayName = true
		} else {
			displayName = email
		}
		await loadRoamingProfile()
		onEvent?(.contactListLoaded)

		try await sendInitialADL()
		for c in result.values where needsApproval(c) {
			onEvent?(.addedBy(email: c.email, displayName: c.displayName))
		}
	}

	private func needsApproval(_ c: Contact) -> Bool {
		(c.lists.contains(.pending) || c.lists.contains(.reverse)) && !c.lists.contains(.allow) && !c.lists.contains(.block)
	}

	private func sendInitialADL() async throws {
		guard let ns else { return }
		let entries = contacts.values.compactMap { c -> (String, Int)? in
			let l = c.lists.intersection([.forward, .allow, .block]).rawValue
			return l == 0 ? nil : (c.email, l)
		}
		let payloads = Self.adlPayloads(entries, initial: true)
		if entries.isEmpty {
			// The Escargot NS does not answer an empty initial list.
			ns.send("ADL", payload: Data(payloads[0].utf8))
			return
		}
		for p in payloads {
			_ = try await ns.request("ADL", payload: Data(p.utf8))
		}
	}

	/// `<ml l="1"><d n="domain"><c n="user" l="3" t="1"/></d></ml>`, split to stay
	/// under the NS's 7500-byte ADL limit.
	static func adlPayloads(_ entries: [(email: String, lists: Int)], initial: Bool) -> [String] {
		var byDomain: [String: [(String, Int)]] = [:]
		for (email, l) in entries {
			let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
			guard parts.count == 2 else { continue }
			byDomain[parts[1], default: []].append((parts[0], l))
		}
		let open = initial ? "<ml l=\"1\">" : "<ml>"
		var payloads: [String] = []
		var current = open
		for domain in byDomain.keys.sorted() {
			var d = "<d n=\"\(domain.xmlEscaped)\">"
			for (user, l) in byDomain[domain]! {
				let c = "<c n=\"\(user.xmlEscaped)\" l=\"\(l)\" t=\"1\"/>"
				if current.utf8.count + d.utf8.count + c.utf8.count + 20 > 7400 {
					if d != "<d n=\"\(domain.xmlEscaped)\">" { current += d + "</d>" }
					payloads.append(current + "</ml>")
					current = open
					d = "<d n=\"\(domain.xmlEscaped)\">"
				}
				d += c
			}
			current += d + "</d>"
		}
		payloads.append(current + "</ml>")
		return payloads
	}

	private func loadRoamingProfile() async {
		guard let ticket = tokens?.storage?.ticket else { return }
		let storage = StorageService(config: config, ticket: ticket)
		self.storage = storage
		let profile: StorageService.Profile
		do {
			profile = try await storage.getProfile(cid: tokens?.cid ?? "0")
		} catch {
			log?("[storage] GetProfile failed: \(error) (cid \(tokens?.cid.map { "\($0.count) chars" } ?? "missing"), puid \(tokens?.puid.map { "\($0.count) chars" } ?? "missing"))")
			return
		}
		profileResourceID = profile.resourceID
		if let name = profile.displayName, !name.isEmpty {
			displayName = name
			knownDisplayName = true
		}
		if !knownPersonalMessage {
			personalMessage = profile.personalMessage ?? ""
			knownPersonalMessage = true
		}
	}

	private func announcePresence(_ initialStatus: Presence) async throws {
		guard let ns else { return }
		if knownDisplayName, let reply = try? await ns.request("PRP", ["MFN", displayName.msnpURLEncoded]), reply.args.count >= 3 {
			displayName = reply.args[2].msnpURLDecoded
		}
		if let privacyMode {
			_ = try? await ns.request("BLP", [privacyMode])
		}
		try await setStatus(initialStatus)
		if knownPersonalMessage {
			_ = try? await ns.request("UUX", payload: Data(PersonalInfo(personalMessage: personalMessage, machineGUID: machineGUID).xml.utf8))
		}
		onEvent?(.profileChanged)
	}

	private func saveRoaming(displayName: String? = nil, personalMessage: String? = nil) async {
		guard let storage else { return }
		let resourceID = profileResourceID ?? "\(tokens?.cid ?? "0")!106"
		do {
			try await storage.updateProfile(resourceID: resourceID, displayName: displayName, personalMessage: personalMessage)
		} catch {
			log?("[storage] UpdateProfile failed: \(error)")
		}
	}

	public func signOut() {
		signingOut = true
		tearDown()
		setState(.signedOut)
	}

	private func tearDown() {
		pingTask?.cancel()
		pingTask = nil
		for sb in switchboards.values { sb.close() }
		switchboards.removeAll()
		openingSwitchboards.removeAll()
		ns?.onClose = nil
		ns?.close()
		ns = nil
		status = .offline
		for key in contacts.keys { contacts[key]?.status = .offline }
	}

	private func notificationClosed(_ error: Error?) {
		guard !signingOut else { return }
		tearDown()
		setState(.signedOut)
		onEvent?(.signedOut(reason: error.map { "Disconnected: \($0.localizedDescription)" } ?? "You have been disconnected from the server."))
	}

	private func startPing() {
		pingTask?.cancel()
		pingTask = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: 45_000_000_000)
				guard let self, let ns = self.ns else { return }
				ns.sendRaw(MSNPCommand("PNG"))
			}
		}
	}

	private func setState(_ s: State) {
		state = s
		onEvent?(.stateChanged(s))
	}

	// MARK: - Profile

	public func setStatus(_ presence: Presence) async throws {
		guard let ns else { return }
		let code = presence == .offline ? Presence.appearOffline.rawValue : presence.rawValue
		_ = try await ns.request("CHG", [code, String(ClientIdentity.advertisedCapabilities), "0"])
		status = presence
		onEvent?(.profileChanged)
	}

	public func setDisplayName(_ name: String) async throws {
		guard let ns, !name.isEmpty else { return }
		let reply = try await ns.request("PRP", ["MFN", name.msnpURLEncoded])
		displayName = reply.args.count >= 3 ? reply.args[2].msnpURLDecoded : name
		knownDisplayName = true
		onEvent?(.profileChanged)
		await saveRoaming(displayName: displayName)
	}

	public func setPersonalMessage(_ text: String) async throws {
		guard let ns else { return }
		_ = try await ns.request("UUX", payload: Data(PersonalInfo(personalMessage: text, machineGUID: machineGUID).xml.utf8))
		personalMessage = text
		knownPersonalMessage = true
		onEvent?(.profileChanged)
		await saveRoaming(personalMessage: text)
	}

	// MARK: - Contact management

	public func addContact(_ rawEmail: String) async throws {
		let email = rawEmail.trimmingCharacters(in: .whitespaces).lowercased()
		guard let ns, let ab = addressBook else { throw MSNPError.disconnected }
		let id = try await ab.addContact(email: email)
		_ = try await ns.request("ADL", payload: Data(Self.adlPayloads([(email, MSNList.forward.rawValue)], initial: false)[0].utf8))
		if contacts[email]?.lists.contains(.allow) != true {
			try? await ab.addMember(email: email, list: .allow)
			_ = try? await ns.request("ADL", payload: Data(Self.adlPayloads([(email, MSNList.allow.rawValue)], initial: false)[0].utf8))
		}
		var c = contacts[email] ?? Contact(email: email)
		let previous = c.status
		c.contactID = id ?? c.contactID
		c.lists.formUnion([.forward, .allow])
		c.lists.remove(.pending)
		contacts[email] = c
		onEvent?(.contactUpdated(c, previousStatus: previous))
	}

	/// Answer to "X has added you to their contact list": allow (and optionally add) or block.
	public func respondToAdd(_ email: String, allow: Bool, addToList: Bool) async throws {
		guard let ab = addressBook, let ns else { throw MSNPError.disconnected }
		if allow {
			if addToList {
				try await addContact(email)
			} else {
				try await ab.addMember(email: email, list: .allow)
				_ = try await ns.request("ADL", payload: Data(Self.adlPayloads([(email, MSNList.allow.rawValue)], initial: false)[0].utf8))
				contacts[email]?.lists.insert(.allow)
			}
		} else {
			try await block(email)
		}
		try? await ab.deleteMember(email: email, list: .pending)
		contacts[email]?.lists.remove(.pending)
	}

	public func removeContact(_ email: String) async throws {
		guard let ns, let ab = addressBook, let c = contacts[email] else { return }
		if let id = c.contactID { try await ab.deleteContact(contactID: id) }
		_ = try? await ns.request("RML", payload: Data(Self.adlPayloads([(email, MSNList.forward.rawValue)], initial: false)[0].utf8))
		contacts[email]?.lists.remove(.forward)
		if contacts[email]?.lists.isEmpty == true { contacts[email] = nil }
		onEvent?(.contactRemoved(email: email))
	}

	public func block(_ email: String) async throws {
		guard let ns, let ab = addressBook else { return }
		if contacts[email]?.lists.contains(.allow) == true {
			try? await ab.deleteMember(email: email, list: .allow)
			_ = try? await ns.request("RML", payload: Data(Self.adlPayloads([(email, MSNList.allow.rawValue)], initial: false)[0].utf8))
		}
		try await ab.addMember(email: email, list: .block)
		_ = try await ns.request("ADL", payload: Data(Self.adlPayloads([(email, MSNList.block.rawValue)], initial: false)[0].utf8))
		update(email) { $0.lists.remove(.allow); $0.lists.insert(.block) }
	}

	public func unblock(_ email: String) async throws {
		guard let ns, let ab = addressBook else { return }
		try await ab.deleteMember(email: email, list: .block)
		_ = try? await ns.request("RML", payload: Data(Self.adlPayloads([(email, MSNList.block.rawValue)], initial: false)[0].utf8))
		try await ab.addMember(email: email, list: .allow)
		_ = try await ns.request("ADL", payload: Data(Self.adlPayloads([(email, MSNList.allow.rawValue)], initial: false)[0].utf8))
		update(email) { $0.lists.remove(.block); $0.lists.insert(.allow) }
	}

	private func update(_ email: String, _ change: (inout Contact) -> Void) {
		var c = contacts[email] ?? Contact(email: email)
		let previous = c.status
		change(&c)
		contacts[email] = c
		onEvent?(.contactUpdated(c, previousStatus: previous))
	}

	// MARK: - Conversations

	public func sendMessage(to peer: String, text: String, format: TextFormat = TextFormat()) async {
		do {
			let sb = try await switchboard(for: peer)
			sb.send(.text(text, format: format))
		} catch {
			let reason: String
			if case MSNPError.server(217, _) = error {
				reason = "\(contacts[peer]?.displayName ?? peer) is offline."
			} else {
				reason = error.localizedDescription
			}
			onEvent?(.conversation(peer: peer, .deliveryFailed(text: text, reason: reason)))
		}
	}

	/// Typing notifications go only over an already-open switchboard, or open
	/// one if the contact is online (WLM opens the SB on the first keystroke).
	public func sendTyping(to peer: String) {
		if let sb = switchboards[peer], !sb.isClosed {
			sb.send(.typing(email), ack: "U")
		} else if contacts[peer]?.status.isOnline == true {
			Task { _ = try? await self.switchboard(for: peer) }
		}
	}

	public func sendNudge(to peer: String) async throws {
		let sb = try await switchboard(for: peer)
		sb.send(.nudge())
	}

	public func closeConversation(with peer: String) {
		switchboards.removeValue(forKey: peer)?.close()
	}

	private func switchboard(for peer: String) async throws -> SwitchboardSession {
		if let sb = switchboards[peer], !sb.isClosed, sb.participants[peer] != nil { return sb }
		if let pending = openingSwitchboards[peer] { return try await pending.value }
		guard let ns else { throw MSNPError.disconnected }
		let task = Task { () -> SwitchboardSession in
			// XFR trid SB host:port CKI cookie U messenger.msn.com 1
			let xfr = try await ns.request("XFR", ["SB"])
			guard xfr.args.count >= 4 else { throw MSNPError.unexpected("\(xfr)") }
			let sb = try await SwitchboardSession.open(address: xfr.args[2], cookie: xfr.args[4 < xfr.args.count ? 4 : 3], myEmail: email, log: log)
			self.attach(sb, peer: peer)
			do {
				try await sb.invite(peer)
			} catch {
				sb.close()
				throw error
			}
			return sb
		}
		openingSwitchboards[peer] = task
		defer { openingSwitchboards[peer] = nil }
		return try await task.value
	}

	private func attach(_ sb: SwitchboardSession, peer: String) {
		if let old = switchboards[peer], old !== sb { old.close() }
		switchboards[peer] = sb
		sb.onEvent = { [weak self, weak sb] event in
			guard let self, let sb else { return }
			self.handleSwitchboard(event, sb: sb, peer: peer)
		}
	}

	private func handleSwitchboard(_ event: SwitchboardSession.Event, sb: SwitchboardSession, peer: String) {
		switch event {
		case let .joined(email, name):
			onEvent?(.conversation(peer: peer, .joined(email: email, displayName: name)))
		case let .left(email):
			onEvent?(.conversation(peer: peer, .left(email: email)))
		case let .message(from, name, mime):
			switch mime.contentType {
			case "text/plain":
				let format = mime["X-MMS-IM-Format"].map(TextFormat.init(header:)) ?? TextFormat()
				onEvent?(.conversation(peer: peer, .message(from: from, displayName: name, text: mime.bodyString, format: format)))
			case "text/x-msmsgscontrol":
				onEvent?(.conversation(peer: peer, .typing(from: from)))
			case "text/x-msnmsgr-datacast":
				if mime.bodyString.contains("ID: 1") { onEvent?(.conversation(peer: peer, .nudge(from: from))) }
			default:
				log?("[SB] ignoring \(mime.contentType)")
			}
		case .closed:
			if switchboards[peer] === sb { switchboards[peer] = nil }
		}
	}

	// MARK: - Notification server events

	private func handleNotification(_ cmd: MSNPCommand) {
		switch cmd.name {
		case "ILN":
			// ILN trid status email networkid friendlyname caps [msnobj]
			if cmd.args.count >= 6 { presence(status: cmd.args[1], email: cmd.args[2], name: cmd.args[4], caps: cmd.args[5]) }
		case "NLN":
			// NLN status email networkid friendlyname caps [msnobj]
			if cmd.args.count >= 5 { presence(status: cmd.args[0], email: cmd.args[1], name: cmd.args[3], caps: cmd.args[4]) }
		case "FLN":
			if let email = cmd.args.first?.lowercased() { update(email) { $0.status = .offline } }
		case "UBX":
			// UBX email networkid length\r\n<Data><PSM>…
			guard let email = cmd.args.first?.lowercased(), let payload = cmd.payload else { return }
			let info = PersonalInfo(xml: payload)
			update(email) { $0.personalMessage = info.personalMessage; $0.currentMedia = info.currentMedia }
		case "RNG":
			// RNG sessid host:port CKI cookie email friendlyname U messenger.msn.com 1
			guard cmd.args.count >= 5 else { return }
			acceptInvite(sessionID: cmd.args[0], address: cmd.args[1], cookie: cmd.args[3], inviter: cmd.args[4].lowercased())
		case "ADL":
			if let payload = cmd.payload { listChanged(payload, added: true) }
		case "RML":
			if let payload = cmd.payload { listChanged(payload, added: false) }
		case "CHL":
			// CHL 0 challenge → QRY trid PRODID 32\r\n<md5-mix>
			guard let chl = cmd.args.last, let ns else { return }
			let response = MSNPChallenge.response(to: chl)
			ns.send("QRY", [MSNPChallenge.productID], payload: Data(response.utf8))
		case "OUT":
			signingOut = true
			let reason = cmd.args.first == "OTH"
				? "You have signed in to Messenger at another location."
				: "The server has signed you out (\(cmd.args.first ?? "unknown"))."
			tearDown()
			setState(.signedOut)
			onEvent?(.signedOut(reason: reason))
		default:
			break
		}
	}

	private func presence(status: String, email rawEmail: String, name: String, caps: String) {
		let email = rawEmail.lowercased()
		update(email) {
			$0.status = Presence(rawValue: status) ?? .online
			$0.displayName = name.msnpURLDecoded
			$0.capabilities = UInt32(caps.split(separator: ":").first ?? "") ?? 0
		}
	}

	/// Server-pushed `ADL 0`/`RML 0` when someone adds or removes us.
	private func listChanged(_ payload: Data, added: Bool) {
		guard let root = try? XElement.parse(payload) else { return }
		for d in root.children("d") {
			guard let domain = d.attributes["n"] else { continue }
			for c in d.children("c") {
				guard let user = c.attributes["n"], let l = c.attributes["l"].flatMap(Int.init) else { continue }
				let email = "\(user)@\(domain)".lowercased()
				let lists = MSNList(rawValue: l)
				let name = c.attributes["f"]?.msnpURLDecoded
				update(email) {
					if added { $0.lists.formUnion(lists) } else { $0.lists.subtract(lists) }
					if let name, !$0.isForward { $0.displayName = name }
				}
				if added, lists.contains(.reverse), let contact = contacts[email], needsApproval(contact) {
					onEvent?(.addedBy(email: email, displayName: contact.displayName))
				}
			}
		}
	}

	private func acceptInvite(sessionID: String, address: String, cookie: String, inviter: String) {
		Task {
			do {
				let sb = try await SwitchboardSession.answer(address: address, cookie: cookie, sessionID: sessionID, myEmail: email, log: log)
				self.attach(sb, peer: inviter)
			} catch {
				log?("[SB] failed to answer RNG from \(inviter): \(error)")
			}
		}
	}
}
