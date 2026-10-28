// The plain client-server API client, for platforms without a matrix-rust-sdk
// build (Linux, for now). Where the SDK is available, MatrixSDKClient.swift
// provides MatrixClient instead, with end-to-end encryption.
#if !canImport(MatrixRustSDK)
import Foundation
import MSNKit

/// WLM on Matrix: the same surface as MessengerClient, over the client-server
/// API. Direct chats (m.direct) are the contact list, presence and its
/// status_msg are the status and personal message, ignored users are the block
/// list, and a DM invite is "X has added you to their contact list".
/// Group rooms and end-to-end encrypted rooms are not supported.
@MainActor
public final class MatrixClient: IMService {
	public private(set) var state: IMState = .signedOut
	/// The Matrix user ID (@user:server); the front ends call it the e-mail address.
	public private(set) var email = ""
	public private(set) var displayName = ""
	public private(set) var personalMessage = ""
	public private(set) var status: Presence = .offline
	public private(set) var displayPicture: Data?
	public private(set) var contacts: [String: Contact] = [:]
	public let groups: [ABGroup] = []
	public private(set) var deviceID = ""

	public var onEvent: ((IMEvent) -> Void)?
	public var log: ((String) -> Void)?
	/// Opens the homeserver's sign-in page for browser (SSO) sign-in; the app sets it.
	public var openURL: ((URL) -> Void)?

	/// nil finds the homeserver from the user ID's server name (.well-known).
	public let homeserver: URL?

	public enum SignInMethod: Sendable {
		case password
		/// The homeserver's own page in the web browser (SSO), e.g. MAS or an OpenID provider.
		case browser
	}

	private struct Summary {
		var heroes: [String] = []
		var joined = 0
		var invited = 0
	}

	private var api: MatrixAPI?
	private var since: String?
	private var syncTask: Task<Void, Never>?
	private var typingTask: Task<Void, Never>?
	private var signingOut = false
	private var redirect: LoopbackRedirect?
	private var txnCounter = 0
	private var creatingRooms: [String: Task<String, Error>] = [:]

	// Account state, as /sync reports it.
	private var direct: [String: [String]] = [:]
	private var ignored: Set<String> = []
	private var joined: Set<String> = []
	private var summaries: [String: Summary] = [:]
	private var encrypted: Set<String> = []
	/// Inviter → the DM room they invited us to.
	private var invites: [String: String] = [:]
	private var names: [String: String] = [:]
	/// User → avatar mxc:// URL, and mxc:// URL → thumbnail (empty when the download failed).
	private var avatarURLs: [String: String] = [:]
	private var pictures: [String: Data] = [:]
	private var myAvatarURL: String?
	private var presence: [String: Presence] = [:]
	private var statusMessages: [String: String] = [:]
	/// Room → the contact a conversation there is with.
	private var roomPeer: [String: String] = [:]
	private var typing: [String: Set<String>] = [:]
	private var lastTypingSent: [String: Date] = [:]

	/// Logging out deletes the device, which the next sign-in on this machine
	/// reuses, so a sign-in waits for the previous sign-out to finish.
	private static var goodbyes: [String: Task<Void, Never>] = [:]

	public init(homeserver: URL? = nil) {
		self.homeserver = homeserver
	}

	public static let supportsEncryption = false

	/// The same as init here: this client keeps nothing between runs anyway.
	public static func throwaway(homeserver: URL?) -> MatrixClient {
		MatrixClient(homeserver: homeserver)
	}

	// MARK: - Sign in / out

	/// How `userID`'s homeserver lets people sign in, so the sign-in window can
	/// drop the password box. Password wins when both are offered.
	public nonisolated static func signInMethod(for userID: String, homeserver: URL? = nil) async throws -> SignInMethod {
		guard let serverName = MatrixID.serverName(of: userID) else { throw MatrixError.badUserID(userID) }
		let base: URL
		if let homeserver { base = homeserver } else { base = try await MatrixAPI.discover(serverName: serverName) }
		let flows = try await MatrixAPI(baseURL: base).loginFlows()
		if flows.contains("m.login.password") { return .password }
		if flows.contains("m.login.sso"), flows.contains("m.login.token") { return .browser }
		throw MatrixError.unsupportedLogin
	}

	/// Signs in with the password, or through the browser when it is empty and
	/// the homeserver offers SSO (or offers nothing else).
	public func signIn(email rawID: String, password: String, status initialStatus: Presence = .online, personalMessage psm: String? = nil) async throws {
		guard state == .signedOut else { return }
		let userID = rawID.trimmingCharacters(in: .whitespaces).lowercased()
		guard let serverName = MatrixID.serverName(of: userID) else { throw MatrixError.badUserID(rawID) }
		email = userID
		signingOut = false
		setState(.signingIn("Connecting..."))
		var session: MatrixAPI?
		do {
			let base: URL
			if let homeserver { base = homeserver } else { base = try await MatrixAPI.discover(serverName: serverName) }
			log?("[matrix] homeserver \(base.absoluteString)")
			await Self.goodbyes[userID]?.value
			var api = MatrixAPI(baseURL: base)
			let flows = try await api.loginFlows()
			try stillSigningIn()
			log?("[matrix] login flows \(flows)")
			let device = Self.deviceID(for: userID), deviceName = "Windows Live Messenger (\(Self.hostName))"
			let login: MatrixAPI.Login
			if flows.contains("m.login.password"), !password.isEmpty {
				setState(.signingIn("Signing in..."))
				login = try await api.login(user: userID, password: password, deviceID: device, deviceName: deviceName)
			} else if flows.contains("m.login.sso"), flows.contains("m.login.token") {
				login = try await browserLogin(api, deviceID: device, deviceName: deviceName)
			} else if flows.contains("m.login.password") {
				throw MatrixError.passwordRequired
			} else {
				throw MatrixError.unsupportedLogin
			}
			api.accessToken = login.accessToken
			session = api
			try stillSigningIn()
			self.api = api
			email = login.userID
			deviceID = login.deviceID
			status = initialStatus
			log?("[matrix] signed in as \(email), device \(deviceID)")

			setState(.signingIn("Loading contacts..."))
			let initial = try await api.sync(since: nil, filter: Self.filter(timelineLimit: 1), timeout: 0, setPresence: status.matrixState)
			try stillSigningIn()
			apply(initial, initial: true)
			await loadProfile(personalMessage: psm)
			await loadProfiles(Array(contacts.keys) + Array(invites.keys))
			rebuildContacts(emit: false)
			onEvent?(.contactListLoaded)
			try await publishPresence()
			try stillSigningIn()
			startSync()
			setState(.signedIn)
			onEvent?(.profileChanged)
			for inviter in invites.keys {
				onEvent?(.addedBy(email: inviter, displayName: name(of: inviter)))
			}
		} catch {
			// Don't leave a half-made session behind on the account.
			if let session { Task { _ = try? await session.call("POST", "/logout", body: [:]) } }
			if !signingOut {
				tearDown()
				setState(.signedOut)
			}
			throw error
		}
	}

	/// Cancel (signOut) during sign-in: stop at the next step.
	private func stillSigningIn() throws {
		if signingOut { throw CancellationError() }
	}

	/// SSO: the homeserver's sign-in page in the browser, which sends the
	/// browser back to a loopback listener with a one-time loginToken.
	private func browserLogin(_ api: MatrixAPI, deviceID: String, deviceName: String) async throws -> MatrixAPI.Login {
		guard let openURL else { throw MatrixError.unsupportedLogin }
		let redirect = try LoopbackRedirect()
		self.redirect = redirect
		defer {
			redirect.stop()
			if self.redirect === redirect { self.redirect = nil }
		}
		setState(.signingIn("Finish signing in in your web browser..."))
		openURL(api.ssoRedirectURL(returningTo: redirect.callbackURL))
		let token = try await redirect.wait(forQueryItem: "loginToken", page: Self.signedInPage)
		try stillSigningIn()
		setState(.signingIn("Signing in..."))
		return try await api.login(token: token, deviceID: deviceID, deviceName: deviceName)
	}

	static let signedInPage = """
		<!doctype html><meta charset="utf-8"><title>Windows Live Messenger</title>
		<body style="font: 13px Tahoma, 'Segoe UI', sans-serif; color: #333; background: #eaf1f6; padding: 48px">
		<h2 style="color: #1e3287; font-weight: normal">You're signed in to Windows Live Messenger</h2>
		<p>You can close this tab and go back to Messenger.</p>
		"""

	public func signOut() {
		signingOut = true
		let api = self.api, me = email, psm = personalMessage
		tearDown()
		setState(.signedOut)
		guard let api else { return }
		// Go offline at once (contacts would otherwise see us online until the
		// server's sync timeout), then end the session.
		Self.goodbyes[me] = Task {
			_ = try? await api.call("PUT", "/presence/\(MatrixAPI.segment(me))/status", body: ["presence": "offline", "status_msg": .string(psm)])
			_ = try? await api.call("POST", "/logout", body: [:])
		}
	}

	private func tearDown() {
		redirect?.stop()
		redirect = nil
		syncTask?.cancel()
		syncTask = nil
		typingTask?.cancel()
		typingTask = nil
		api = nil
		since = nil
		status = .offline
		direct = [:]
		ignored = []
		joined = []
		summaries = [:]
		encrypted = []
		invites = [:]
		roomPeer = [:]
		typing = [:]
		lastTypingSent = [:]
		creatingRooms = [:]
		for key in contacts.keys { contacts[key]?.status = .offline }
	}

	private func sessionEnded(_ reason: String) {
		guard !signingOut else { return }
		tearDown()
		setState(.signedOut)
		onEvent?(.signedOut(reason: reason))
	}

	private func setState(_ s: IMState) {
		state = s
		onEvent?(.stateChanged(s))
	}

	/// One device per account and machine, so signing in again (or after quitting
	/// without signing out) reuses the session rather than adding another.
	nonisolated static func deviceID(for userID: String, host: String = hostName) -> String {
		var hash: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV-1a
		for byte in "\(host)|\(userID)".utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
		var id = "WLM"
		for _ in 0..<7 {
			id.append(Character(Unicode.Scalar(UInt8(65 + hash % 26))))
			hash /= 26
		}
		return id
	}

	nonisolated static var hostName: String {
		var buf = [CChar](repeating: 0, count: 256)
		gethostname(&buf, buf.count)
		return String(cString: buf)
	}

	// MARK: - Sync

	nonisolated static func filter(timelineLimit: Int) -> JSON {
		[
			"account_data": ["types": ["m.direct", "m.ignored_user_list"]],
			"presence": ["types": ["m.presence"]],
			"room": [
				"state": ["lazy_load_members": true],
				"timeline": ["limit": .number(Double(timelineLimit)), "lazy_load_members": true],
				"ephemeral": ["types": ["m.typing"]],
				"account_data": ["types": []],
			],
		]
	}

	private func startSync() {
		syncTask?.cancel()
		syncTask = Task { [weak self] in
			var failures = 0
			while !Task.isCancelled {
				guard let self, let api = self.api else { return }
				do {
					let response = try await api.sync(since: self.since, filter: Self.filter(timelineLimit: 20), timeout: 30_000,
					                                  setPresence: self.status.matrixState)
					if Task.isCancelled { return }
					failures = 0
					self.apply(response, initial: false)
				} catch {
					if Task.isCancelled { return }
					if case MatrixError.server(401, _, _) = error {
						return self.sessionEnded("Your Matrix session has ended. You may have signed it out from another device.")
					}
					failures += 1
					self.log?("[matrix] sync failed (\(failures)): \(error)")
					if failures >= 5 { return self.sessionEnded("Disconnected: \(error.localizedDescription)") }
					try? await Task.sleep(nanoseconds: UInt64(1 << failures) * 1_000_000_000)
				}
			}
		}
		// m.typing only says when someone starts or stops; WLM's "is typing"
		// line expires after ~6 s, so repeat it while they are still at it.
		typingTask?.cancel()
		typingTask = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: 5_000_000_000)
				guard let self else { return }
				for (room, users) in self.typing {
					guard let peer = self.roomPeer[room] else { continue }
					for user in users { self.onEvent?(.conversation(peer: peer, .typing(from: user))) }
				}
			}
		}
	}

	private func apply(_ sync: JSON, initial: Bool) {
		if let next = sync["next_batch"].string { since = next }
		for e in sync["account_data"]["events"].array {
			switch e["type"].string {
			case "m.direct":
				direct = e["content"].object.mapValues { $0.array.compactMap(\.string) }
			case "m.ignored_user_list":
				ignored = Set(e["content"]["ignored_users"].object.keys)
			default:
				break
			}
		}
		for e in sync["presence"]["events"].array {
			guard e["type"].string == "m.presence", let user = e["sender"].string else { continue }
			presence[user] = Presence(matrix: e["content"]["presence"].string)
			statusMessages[user] = e["content"]["status_msg"].string ?? ""
		}

		let rooms = sync["rooms"]
		for (roomID, room) in rooms["join"].object {
			joined.insert(roomID)
			let s = room["summary"]
			var summary = summaries[roomID] ?? Summary()
			if !s["m.heroes"].isNull { summary.heroes = s["m.heroes"].array.compactMap(\.string) }
			if let n = s["m.joined_member_count"].int { summary.joined = n }
			if let n = s["m.invited_member_count"].int { summary.invited = n }
			summaries[roomID] = summary
			for e in room["state"]["events"].array + room["timeline"]["events"].array where !e["state_key"].isNull {
				applyState(e, room: roomID)
			}
			invites = invites.filter { $0.value != roomID }  // accepted on another device
		}
		var newInvites: [String] = []
		for (roomID, room) in rooms["invite"].object {
			let events = room["invite_state"]["events"].array
			func member(_ user: String) -> JSON? {
				events.first { $0["type"].string == "m.room.member" && $0["state_key"].string == user }
			}
			guard let mine = member(email), mine["content"]["membership"].string == "invite",
			      mine["content"]["is_direct"].bool == true,
			      let inviter = mine["sender"].string, !ignored.contains(inviter) else { continue }
			if let name = member(inviter)?["content"]["displayname"].string, !name.isEmpty { names[inviter] = name }
			// Known before joining, so nothing can go out in the clear in between.
			if events.contains(where: { $0["type"].string == "m.room.encryption" }) { encrypted.insert(roomID) }
			if invites[inviter] == nil, !initial { newInvites.append(inviter) }
			invites[inviter] = roomID
		}
		for roomID in rooms["leave"].object.keys {
			joined.remove(roomID)
			invites = invites.filter { $0.value != roomID }
			typing[roomID] = nil
		}
		rebuildContacts(emit: !initial)
		guard !initial else { return }

		for (roomID, room) in rooms["join"].object {
			guard let peer = roomPeer[roomID] else { continue }
			for e in room["timeline"]["events"].array { timelineEvent(e, room: roomID, peer: peer) }
			for e in room["ephemeral"]["events"].array where e["type"].string == "m.typing" {
				let now = Set(e["content"]["user_ids"].array.compactMap(\.string)).subtracting([email])
				let started = now.subtracting(typing[roomID] ?? [])
				typing[roomID] = now
				for user in started { onEvent?(.conversation(peer: peer, .typing(from: user))) }
			}
		}
		for inviter in newInvites {
			onEvent?(.addedBy(email: inviter, displayName: name(of: inviter)))
		}
	}

	private func applyState(_ e: JSON, room roomID: String) {
		switch e["type"].string {
		case "m.room.encryption":
			encrypted.insert(roomID)
		case "m.room.member":
			guard let user = e["state_key"].string, e["content"]["membership"].string == "join" else { break }
			let avatar = e["content"]["avatar_url"].string
			if user == email {
				myAvatarURL = avatar
				break
			}
			if let name = e["content"]["displayname"].string, !name.isEmpty { names[user] = name }
			avatarURLs[user] = avatar
		default:
			break
		}
	}

	private func timelineEvent(_ e: JSON, room roomID: String, peer: String) {
		guard let sender = e["sender"].string, sender != email, !ignored.contains(sender) else { return }
		let content = e["content"]
		let name = name(of: sender)
		switch e["type"].string {
		case "m.room.message":
			typing[roomID]?.remove(sender)
			if MatrixMessage.isNudge(content) {
				onEvent?(.conversation(peer: peer, .nudge(from: sender)))
			} else if content["body"].string != nil {  // a redacted event has no body
				let text = MatrixMessage.text(of: content, senderName: name)
				onEvent?(.conversation(peer: peer, .message(from: sender, displayName: name, text: text, format: MatrixMessage.format(of: content))))
			}
		case "m.room.encrypted":
			typing[roomID]?.remove(sender)
			onEvent?(.conversation(peer: peer, .message(from: sender, displayName: name, text: MatrixMessage.encryptedNotice,
			                                            format: MatrixMessage.noticeFormat)))
		default:
			break
		}
	}

	/// Contacts are everyone m.direct lists with a room we're in, plus the other
	/// person in any two-person room, plus ignored users (blocked) and DM inviters.
	private func rebuildContacts(emit: Bool) {
		var peers: [String: String] = [:]
		var lists: [String: MSNList] = [:]
		for (user, rooms) in direct where user != email {
			let live = rooms.filter(joined.contains)
			guard !live.isEmpty else { continue }
			for room in live { peers[room] = user }
			lists[user, default: []].formUnion([.forward, .allow])
		}
		for (room, s) in summaries where joined.contains(room) && peers[room] == nil && s.joined + s.invited == 2 && s.heroes.count == 1 {
			peers[room] = s.heroes[0]
			lists[s.heroes[0], default: []].insert(.allow)
		}
		for user in ignored {
			lists[user, default: []].remove(.allow)
			lists[user, default: []].insert(.block)
		}
		for user in invites.keys { lists[user, default: []].formUnion([.reverse, .pending]) }
		roomPeer = peers

		var next: [String: Contact] = [:]
		for (user, l) in lists {
			var c = Contact(email: user, displayName: name(of: user))
			c.email = user
			c.lists = l
			c.status = presence[user] ?? .offline
			c.personalMessage = statusMessages[user] ?? ""
			next[user] = c
		}
		let old = contacts
		contacts = next
		displayPicture = picture(myAvatarURL)
		fetchPictures()
		guard emit else { return }
		for (user, c) in next where old[user] != c {
			onEvent?(.contactUpdated(c, previousStatus: old[user]?.status ?? .offline))
		}
		for (user, c) in old where c.isForward && next[user]?.isForward != true {
			onEvent?(.contactRemoved(email: user))
		}
	}

	private func name(of user: String) -> String {
		names[user] ?? MatrixID.localpart(of: user)
	}

	private func picture(_ mxc: String?) -> Data? {
		mxc.flatMap { pictures[$0] }.flatMap { $0.isEmpty ? nil : $0 }
	}

	/// Downloads avatars nobody has fetched yet, then shows them.
	private func fetchPictures() {
		guard let api else { return }
		let wanted = Set(contacts.keys.compactMap { avatarURLs[$0] } + [myAvatarURL].compactMap { $0 })
		for mxc in wanted where pictures[mxc] == nil {
			pictures[mxc] = Data()  // in flight; stays empty if the download fails
			Task {
				guard let data = try? await api.thumbnail(mxc), !data.isEmpty, self.api != nil else { return }
				self.pictures[mxc] = data
				self.pictureArrived(mxc)
			}
		}
	}

	/// A downloaded avatar reaches whoever uses it, us included.
	private func pictureArrived(_ mxc: String) {
		if mxc == myAvatarURL {
			displayPicture = picture(mxc)
			onEvent?(.displayPictureChanged(email: email))
		}
		for (user, url) in avatarURLs where url == mxc && contacts[user] != nil {
			onEvent?(.displayPictureChanged(email: user))
		}
	}

	public func displayPicture(of email: String) -> Data? {
		picture(avatarURLs[email])
	}


	private func loadProfile(personalMessage psm: String?) async {
		guard let api else { return }
		let me = MatrixAPI.segment(email)
		let profile = try? await api.call("GET", "/profile/\(me)")
		displayName = profile?["displayname"].string ?? MatrixID.localpart(of: email)
		myAvatarURL = profile?["avatar_url"].string
		if let psm {
			personalMessage = psm
		} else {
			personalMessage = (try? await api.call("GET", "/presence/\(me)/status"))?["status_msg"].string ?? ""
		}
	}

	/// Profile names and avatars for people no member event has described yet.
	private func loadProfiles(_ users: [String]) async {
		guard let api else { return }
		let missing = Set(users).filter { names[$0] == nil || avatarURLs[$0] == nil }
		let found = await withTaskGroup(of: (String, JSON?).self) { group in
			for user in missing {
				group.addTask { (user, try? await api.call("GET", "/profile/\(MatrixAPI.segment(user))")) }
			}
			var out: [String: JSON] = [:]
			for await (user, profile) in group { if let profile { out[user] = profile } }
			return out
		}
		for (user, profile) in found {
			if names[user] == nil, let name = profile["displayname"].string, !name.isEmpty { names[user] = name }
			if avatarURLs[user] == nil { avatarURLs[user] = profile["avatar_url"].string }
		}
	}

	// MARK: - Profile

	private func publishPresence() async throws {
		guard let api else { return }
		_ = try await api.call("PUT", "/presence/\(MatrixAPI.segment(email))/status",
		                       body: ["presence": .string(status.matrixState), "status_msg": .string(personalMessage)])
	}

	public func setStatus(_ presence: Presence) async throws {
		guard api != nil else { return }
		status = presence
		try await publishPresence()
		onEvent?(.profileChanged)
	}

	public func setDisplayName(_ name: String) async throws {
		guard let api, !name.isEmpty else { return }
		_ = try await api.call("PUT", "/profile/\(MatrixAPI.segment(email))/displayname", body: ["displayname": .string(name)])
		displayName = name
		onEvent?(.profileChanged)
	}

	public func setPersonalMessage(_ text: String) async throws {
		guard api != nil else { return }
		personalMessage = text
		try await publishPresence()
		onEvent?(.profileChanged)
	}

	// MARK: - Contact management

	public func addContact(_ raw: String) async throws {
		let user = raw.trimmingCharacters(in: .whitespaces).lowercased()
		guard MatrixID.isUserID(user) else { throw MatrixError.badUserID(raw) }
		guard api != nil else { throw MSNPError.disconnected }
		guard user != email else { return }
		if invites[user] != nil { return try await respondToAdd(user, allow: true, addToList: true) }
		if contacts[user]?.isForward != true {
			if let room = roomPeer.first(where: { $0.value == user })?.key {
				try await setDirect(room, with: user)
			} else {
				_ = try await directRoom(with: user)
			}
		}
		await loadProfiles([user])
		rebuildContacts(emit: true)
	}

	/// Accepting joins the DM room; declining leaves it and blocks the inviter, as WLM's "Block" did.
	public func respondToAdd(_ user: String, allow: Bool, addToList: Bool) async throws {
		guard let api else { throw MSNPError.disconnected }
		guard let room = invites.removeValue(forKey: user) else {
			if allow, addToList { try await addContact(user) } else if !allow { try await block(user) }
			return
		}
		if allow {
			_ = try await api.call("POST", "/join/\(MatrixAPI.segment(room))", body: [:])
			joined.insert(room)
			if summaries[room] == nil { summaries[room] = Summary(heroes: [user], joined: 2) }
			if addToList { try await setDirect(room, with: user) }
		} else {
			_ = try? await api.call("POST", "/rooms/\(MatrixAPI.segment(room))/leave", body: [:])
			try await block(user)
		}
		rebuildContacts(emit: true)
	}

	/// Takes them off m.direct; the room stays, so they can still message you (as in WLM).
	public func removeContact(_ user: String) async throws {
		guard direct[user] != nil else { return }
		var next = direct
		next[user] = nil
		try await putDirect(next)
		rebuildContacts(emit: true)
	}

	public func block(_ user: String) async throws {
		try await setIgnored(ignored.union([user]))
	}

	public func unblock(_ user: String) async throws {
		try await setIgnored(ignored.subtracting([user]))
	}

	private func setIgnored(_ next: Set<String>) async throws {
		let users = Dictionary(uniqueKeysWithValues: next.map { ($0, JSON.object([:])) })
		try await putAccountData("m.ignored_user_list", ["ignored_users": .object(users)])
		ignored = next
		rebuildContacts(emit: true)
	}

	private func setDirect(_ room: String, with user: String) async throws {
		var next = direct
		if next[user]?.contains(room) != true { next[user, default: []].append(room) }
		try await putDirect(next)
	}

	private func putDirect(_ next: [String: [String]]) async throws {
		try await putAccountData("m.direct", .object(next.mapValues { .array($0.map(JSON.string)) }))
		direct = next
	}

	private func putAccountData(_ type: String, _ content: JSON) async throws {
		guard let api else { throw MSNPError.disconnected }
		_ = try await api.call("PUT", "/user/\(MatrixAPI.segment(email))/account_data/\(MatrixAPI.segment(type))", body: content)
	}

	/// The newest DM room with `user` that we're in, else a new one (unencrypted:
	/// this client can't read anything else). Concurrent callers share one room.
	private func directRoom(with user: String) async throws -> String {
		if let room = existingRoom(with: user) { return room }
		if let pending = creatingRooms[user] { return try await pending.value }
		guard let api else { throw MSNPError.disconnected }
		let task = Task { () -> String in
			let reply = try await api.call("POST", "/createRoom", body: [
				"preset": "trusted_private_chat", "is_direct": true, "invite": [.string(user)],
			])
			guard let room = reply["room_id"].string else { throw MatrixError.badResponse("createRoom without room_id") }
			self.joined.insert(room)
			self.summaries[room] = Summary(heroes: [user], joined: 1, invited: 1)
			try await self.setDirect(room, with: user)
			self.rebuildContacts(emit: true)
			return room
		}
		creatingRooms[user] = task
		defer { creatingRooms[user] = nil }
		return try await task.value
	}

	private func existingRoom(with user: String) -> String? {
		direct[user]?.last(where: joined.contains) ?? roomPeer.first { $0.value == user }?.key
	}

	// MARK: - Conversations

	public func sendMessage(to peer: String, text: String, format: TextFormat = TextFormat()) async {
		do {
			let room = try await conversationRoom(with: peer)
			try await send(MatrixMessage.content(text: text, format: format), to: room)
			stopTyping(in: room)
		} catch {
			onEvent?(.conversation(peer: peer, .deliveryFailed(text: text, reason: error.localizedDescription)))
		}
	}

	/// Typing goes only to an existing room, at most every 4 s while keys are pressed.
	public func sendTyping(to peer: String) {
		guard let api, let room = existingRoom(with: peer), !encrypted.contains(room) else { return }
		if let last = lastTypingSent[room], Date().timeIntervalSince(last) < 4 { return }
		lastTypingSent[room] = Date()
		let path = "/rooms/\(MatrixAPI.segment(room))/typing/\(MatrixAPI.segment(email))"
		Task { _ = try? await api.call("PUT", path, body: ["typing": true, "timeout": 6000]) }
	}

	private func stopTyping(in room: String) {
		guard let api, lastTypingSent.removeValue(forKey: room) != nil else { return }
		let path = "/rooms/\(MatrixAPI.segment(room))/typing/\(MatrixAPI.segment(email))"
		Task { _ = try? await api.call("PUT", path, body: ["typing": false]) }
	}

	public func sendNudge(to peer: String) async throws {
		let room = try await conversationRoom(with: peer)
		try await send(MatrixMessage.nudge(), to: room)
	}

	public func closeConversation(with peer: String) {
		if let room = existingRoom(with: peer) { stopTyping(in: room) }
	}

	private func conversationRoom(with peer: String) async throws -> String {
		guard MatrixID.isUserID(peer) else { throw MatrixError.badUserID(peer) }
		let room = try await directRoom(with: peer)
		if encrypted.contains(room) { throw MatrixError.encryptedRoom }
		// They left the DM: invite them back, as other clients do.
		if let api, let s = summaries[room], s.joined + s.invited < 2 {
			_ = try? await api.call("POST", "/rooms/\(MatrixAPI.segment(room))/invite", body: ["user_id": .string(peer)])
		}
		return room
	}

	private func send(_ content: JSON, to room: String) async throws {
		guard let api else { throw MSNPError.disconnected }
		txnCounter += 1
		let txn = "wlm\(Int(Date().timeIntervalSince1970 * 1000))-\(txnCounter)"
		_ = try await api.call("PUT", "/rooms/\(MatrixAPI.segment(room))/send/m.room.message/\(txn)", body: content)
	}
}
#endif
