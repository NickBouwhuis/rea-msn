#if canImport(MatrixRustSDK)
import Foundation
import ImageIO
import MatrixRustSDK
import MSNKit

/// WLM on Matrix through matrix-rust-sdk, which brings end-to-end encryption,
/// cross-signing verification and key backup. The mapping is the one in
/// MatrixHTTPClient: direct chats are the contact list, presence and its
/// status_msg the status and personal message, ignored users the block list,
/// a DM invite "X has added you". The SDK runs a sync v2 loop; messages come
/// from per-room event subscriptions (already decrypted), presence from
/// polling, as the SDK doesn't surface presence events.
///
/// The session, not the password, is kept (StoredMatrixSession), so this
/// device keeps its keys and its verification across launches.
@MainActor
public final class MatrixClient: IMService {
	public enum SignInMethod: Sendable {
		case password
		/// The homeserver's own page in the web browser (SSO), e.g. MAS or an OpenID provider.
		case browser
		/// Already signed in on this computer: the saved session is used.
		case savedSession
	}

	public enum VerificationEvent {
		/// Whether this session is verified (cross-signed by you). Other people's
		/// clients may not share keys with an unverified session.
		case state(verified: Bool)
		/// Another of your sessions asks to verify this one.
		case requested(by: String)
		/// Both sessions show these; compare them.
		case emojis([(symbol: String, description: String)])
		case finished
		case cancelled(String?)
	}

	public private(set) var state: IMState = .signedOut
	/// The Matrix user ID (@user:server); the front ends call it the e-mail address.
	public private(set) var email = ""
	public private(set) var displayName = ""
	public private(set) var personalMessage = ""
	public private(set) var status: Presence = .offline
	public private(set) var displayPicture: Data?
	public private(set) var contacts: [String: Contact] = [:]
	public let groups: [ABGroup] = []
	public private(set) var isVerified = false
	public private(set) var deviceID = ""

	public var onEvent: ((IMEvent) -> Void)?
	public var log: ((String) -> Void)?
	/// Opens the homeserver's sign-in page for browser (SSO) sign-in; the app sets it.
	public var openURL: ((URL) -> Void)?
	public var onVerification: ((VerificationEvent) -> Void)?
	/// Sign out keeps this device's session (and its verification) for next
	/// time, as "Remember me" does; false logs the device out and deletes its store.
	public var keepsSessionOnSignOut = true

	/// nil finds the homeserver from the user ID's server name (.well-known).
	public let homeserver: URL?
	private let store: MatrixSessionStore
	private let directory: URL

	private var client: Client?
	private var signingOut = false
	private var signedInAt = Date()
	private var redirect: LoopbackRedirect?
	private var syncHandle: TaskHandle?
	private var handles: [TaskHandle] = []
	private var roomHandles: [String: [TaskHandle]] = [:]
	private var timelines: [String: Timeline] = [:]
	/// Each followed room's timeline items, kept by applying its diffs (for history).
	private var roomItems: [String: [TimelineItem]] = [:]
	/// Event ID → reported as a message (true) or as undecryptable so far (false).
	private var delivered: [String: Bool] = [:]
	private var tasks: [Task<Void, Never>] = []
	private var verification: SessionVerificationController?
	private var incomingVerification: SessionVerificationRequestDetails?

	private var rooms: [String: Room] = [:]
	private var roomInfos: [String: RoomInfo] = [:]
	/// m.direct: user → their DM rooms. Read from account data, and updated
	/// here as soon as we change it.
	private var direct: [String: [String]] = [:]
	/// Joined and invited members of each room, from the SDK's store: sync v2
	/// without lazy loading has no room summary, so RoomInfo's heroes and
	/// member counts stay empty.
	private var members: [String: Set<String>] = [:]
	private var profilesRequested: Set<String> = []
	/// Room → the contact a conversation there is with.
	private var roomPeer: [String: String] = [:]
	/// Inviter → the DM room they invited us to.
	private var invites: [String: String] = [:]
	private var ignored: Set<String> = []
	private var names: [String: String] = [:]
	private var avatarURLs: [String: String] = [:]
	private var myAvatarURL: String?
	/// mxc:// URL → thumbnail (empty while loading or when it failed).
	private var pictures: [String: Data] = [:]
	private var presence: [String: Presence] = [:]
	private var statusMessages: [String: String] = [:]
	private var typing: [String: Set<String>] = [:]
	private var lastTypingSent: [String: Date] = [:]

	private static var goodbyes: [String: Task<Void, Never>] = [:]

	public nonisolated static var defaultDirectory: URL {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("MessengerMac/Matrix", isDirectory: true)
	}

	public init(homeserver: URL? = nil, store: MatrixSessionStore = KeychainMatrixSessionStore(),
	            directory: URL = MatrixClient.defaultDirectory) {
		self.homeserver = homeserver
		self.store = store
		self.directory = directory
	}

	public static let supportsEncryption = true

	/// A client that keeps nothing (msnctl, tests): a new device in a temporary
	/// folder, logged out again on sign-out.
	public static func throwaway(homeserver: URL?) -> MatrixClient {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("matrixkit-\(UUID().uuidString)", isDirectory: true)
		let client = MatrixClient(homeserver: homeserver, store: MemoryMatrixSessionStore(), directory: dir)
		client.keepsSessionOnSignOut = false
		return client
	}

	// MARK: - Sign in / out

	/// How `userID` signs in here, so the sign-in window can drop the password
	/// box: a saved session, else password when offered, else the browser.
	public nonisolated static func signInMethod(for userID: String, homeserver: URL? = nil,
	                                            store: MatrixSessionStore = KeychainMatrixSessionStore()) async throws -> SignInMethod {
		guard let serverName = MatrixID.serverName(of: userID) else { throw MatrixError.badUserID(userID) }
		if store.load(userID) != nil { return .savedSession }
		let base: URL
		if let homeserver { base = homeserver } else { base = try await MatrixAPI.discover(serverName: serverName) }
		let flows = try await MatrixAPI(baseURL: base).loginFlows()
		if flows.contains("m.login.password") { return .password }
		if flows.contains("m.login.sso"), flows.contains("m.login.token") { return .browser }
		throw MatrixError.unsupportedLogin
	}

	/// Restores this computer's session if there is one; otherwise signs in
	/// with the password, or through the browser when it is empty and the
	/// homeserver offers SSO.
	public func signIn(email rawID: String, password: String, status initialStatus: Presence = .online, personalMessage psm: String? = nil) async throws {
		guard state == .signedOut else { return }
		let userID = rawID.trimmingCharacters(in: .whitespaces).lowercased()
		guard let serverName = MatrixID.serverName(of: userID) else { throw MatrixError.badUserID(rawID) }
		email = userID
		signingOut = false
		signedInAt = Date()
		setState(.signingIn("Connecting..."))
		do {
			await Self.goodbyes[userID]?.value
			let client: Client
			if let restored = try await restoredClient(userID) {
				client = restored
			} else {
				client = try await freshLogin(userID, password: password, server: homeserver?.absoluteString ?? serverName)
			}
			try stillSigningIn()
			self.client = client
			email = (try? client.userId()) ?? userID
			deviceID = (try? client.deviceId()) ?? ""
			log?("[matrix] signed in as \(email), device \(deviceID)")
			status = initialStatus
			if let handle = try? client.setDelegate(delegate: AuthErrorListener { [weak self] soft in
				Task { @MainActor in self?.sessionEnded(soft ? "Please sign in again." : "Your Matrix session has ended. You may have signed it out from another device.") }
			}) { handles.append(handle) }
			try await client.setPresence(presence: status.matrixPresence, immediate: false)

			setState(.signingIn("Loading contacts..."))
			_ = try await client.syncOnceV2(settings: SyncSettingsV2(timeoutMs: 0, fullState: false))
			try stillSigningIn()
			ignored = Set((try? await client.ignoredUsers()) ?? [])
			await loadOwnProfile(personalMessage: psm)
			await refreshRooms(nil, emit: false)
			await loadProfiles(Array(contacts.keys))
			rebuildContacts(emit: false)
			onEvent?(.contactListLoaded)
			try? await publishPresence()
			try stillSigningIn()
			startSync()
			setState(.signedIn)
			onEvent?(.profileChanged)
			for inviter in invites.keys {
				onEvent?(.addedBy(email: inviter, displayName: name(of: inviter)))
			}
			watchVerification()
		} catch {
			if !signingOut {
				tearDown()
				setState(.signedOut)
			}
			throw error
		}
	}

	/// The saved session for `userID`, if it still works; a revoked one is forgotten.
	private func restoredClient(_ userID: String) async throws -> Client? {
		guard let saved = store.load(userID) else { return nil }
		setState(.signingIn("Signing in..."))
		let api = MatrixAPI(baseURL: URL(string: saved.homeserverURL)!, accessToken: saved.accessToken)
		do {
			_ = try await api.call("GET", "/account/whoami")
		} catch MatrixError.server(401, _, _) {
			log?("[matrix] saved session was revoked; signing in again")
			store.delete(userID)
			removeStore(saved.storeName)
			return nil
		}
		let client = try await makeClient(store: saved.storeName, passphrase: saved.storePassphrase, server: saved.homeserverURL)
		try await client.restoreSession(session: saved.session)
		return client
	}

	private func freshLogin(_ userID: String, password: String, server: String) async throws -> Client {
		let storeName = UUID().uuidString
		var key = [UInt8](repeating: 0, count: 32)
		for i in key.indices { key[i] = UInt8.random(in: 0...255) }
		let passphrase = Data(key).base64EncodedString()
		let client = try await makeClient(store: storeName, passphrase: passphrase, server: server)
		do {
			let details = await client.homeserverLoginDetails()
			let deviceName = "Windows Live Messenger (\(Self.hostName))"
			if details.supportsPasswordLogin(), !password.isEmpty {
				setState(.signingIn("Signing in..."))
				do {
					try await client.login(username: userID, password: password, initialDeviceName: deviceName, deviceId: nil)
				} catch let error where "\(error)".contains("M_FORBIDDEN") {
					throw MatrixError.authenticationFailed
				}
			} else if details.supportsSsoLogin() {
				try await browserLogin(client)
			} else if details.supportsPasswordLogin() {
				throw MatrixError.passwordRequired
			} else {
				throw MatrixError.unsupportedLogin
			}
			try stillSigningIn()
			store.save(StoredMatrixSession(try client.session(), storeName: storeName, storePassphrase: passphrase))
			return client
		} catch {
			if (try? client.session()) != nil { try? await client.logout() }
			removeStore(storeName)
			throw error
		}
	}

	private func makeClient(store name: String, passphrase: String, server: String) async throws -> Client {
		let path = directory.appendingPathComponent(name, isDirectory: true).path
		try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
		                                        attributes: [.posixPermissions: 0o700])
		var builder = ClientBuilder()
			.sqliteStore(config: SqliteStoreBuilder(dataPath: path, cachePath: path).passphrase(passphrase: passphrase))
			.userAgent(userAgent: "Windows Live Messenger 8.1 (MatrixKit)")
			.autoEnableCrossSigning(autoEnableCrossSigning: true)
			.autoEnableBackups(autoEnableBackups: true)
			// Element's long-standing default: keys go to all of a contact's
			// devices, but sending fails if someone you verified has an unsigned one.
			.roomKeyRecipientStrategy(strategy: .errorOnVerifiedUserProblem)
			.setSessionDelegate(sessionDelegate: SessionSaver(store: store))
		builder = server.hasPrefix("http") ? builder.homeserverUrl(url: server) : builder.serverNameOrHomeserverUrl(serverNameOrUrl: server)
		return try await builder.build()
	}

	private func removeStore(_ name: String) {
		try? FileManager.default.removeItem(at: directory.appendingPathComponent(name, isDirectory: true))
	}

	/// SSO: the homeserver's sign-in page in the browser, which sends the
	/// browser back to a loopback listener with a one-time loginToken.
	private func browserLogin(_ client: Client) async throws {
		guard let openURL else { throw MatrixError.unsupportedLogin }
		let redirect = try LoopbackRedirect()
		self.redirect = redirect
		defer {
			redirect.stop()
			if self.redirect === redirect { self.redirect = nil }
		}
		let handler = try await client.startSsoLogin(redirectUrl: redirect.callbackURL.absoluteString, idpId: nil)
		guard let url = URL(string: handler.url()) else { throw MatrixError.badResponse("bad SSO URL") }
		setState(.signingIn("Finish signing in in your web browser..."))
		openURL(url)
		let token = try await redirect.wait(forQueryItem: "loginToken", page: Self.signedInPage)
		try stillSigningIn()
		setState(.signingIn("Signing in..."))
		var callback = URLComponents(url: redirect.callbackURL, resolvingAgainstBaseURL: false)!
		callback.queryItems = [URLQueryItem(name: "loginToken", value: token)]
		try await handler.finish(callbackUrl: callback.url!.absoluteString)
	}

	static let signedInPage = """
		<!doctype html><meta charset="utf-8"><title>Windows Live Messenger</title>
		<body style="font: 13px Tahoma, 'Segoe UI', sans-serif; color: #333; background: #eaf1f6; padding: 48px">
		<h2 style="color: #1e3287; font-weight: normal">You're signed in to Windows Live Messenger</h2>
		<p>You can close this tab and go back to Messenger.</p>
		"""

	public func signOut() {
		signingOut = true
		let client = self.client, me = email, psm = personalMessage, keep = keepsSessionOnSignOut
		let saved = store.load(me)
		tearDown()
		setState(.signedOut)
		guard let client else { return }
		if !keep { store.delete(me) }
		// Go offline at once (contacts would otherwise see us online until the
		// server's sync timeout); without "Remember me", end the session too.
		Self.goodbyes[me] = Task {
			if let api = Self.api(client) {
				_ = try? await api.call("PUT", "/presence/\(MatrixAPI.segment(me))/status", body: ["presence": "offline", "status_msg": .string(psm)])
			}
			if !keep {
				try? await client.logout()
				if let saved { try? FileManager.default.removeItem(at: self.directory.appendingPathComponent(saved.storeName, isDirectory: true)) }
			}
		}
	}

	private func stillSigningIn() throws {
		if signingOut { throw CancellationError() }
	}

	private func tearDown() {
		redirect?.stop()
		redirect = nil
		syncHandle?.cancel()
		syncHandle = nil
		for h in handles { h.cancel() }
		handles = []
		for hs in roomHandles.values { for h in hs { h.cancel() } }
		roomHandles = [:]
		timelines = [:]
		roomItems = [:]
		for t in tasks { t.cancel() }
		tasks = []
		verification?.setDelegate(delegate: nil)
		verification = nil
		client = nil
		status = .offline
		rooms = [:]
		roomInfos = [:]
		direct = [:]
		members = [:]
		roomPeer = [:]
		invites = [:]
		typing = [:]
		lastTypingSent = [:]
		for key in contacts.keys { contacts[key]?.status = .offline }
	}

	private func sessionEnded(_ reason: String) {
		guard !signingOut, client != nil else { return }
		store.delete(email)
		tearDown()
		setState(.signedOut)
		onEvent?(.signedOut(reason: reason))
	}

	private func setState(_ s: IMState) {
		state = s
		onEvent?(.stateChanged(s))
	}

	nonisolated static var hostName: String {
		var buf = [CChar](repeating: 0, count: 256)
		gethostname(&buf, buf.count)
		return String(cString: buf)
	}

	/// The client-server API with the SDK's current token, for what the SDK
	/// doesn't wrap (presence with a status message).
	private nonisolated static func api(_ client: Client) -> MatrixAPI? {
		guard let session = try? client.session(), let url = URL(string: session.homeserverUrl) else { return nil }
		return MatrixAPI(baseURL: url, accessToken: session.accessToken)
	}

	// MARK: - Sync

	private func startSync() {
		guard let client else { return }
		syncHandle = client.syncV2(settings: SyncSettingsV2(timeoutMs: 30_000, fullState: false), listener: SyncListener { [weak self] response in
			Task { @MainActor in await self?.synced(response) }
		})
		handles.append(client.subscribeToIgnoredUsers(listener: IgnoredListener { [weak self] users in
			Task { @MainActor in
				guard let self else { return }
				self.ignored = Set(users)
				self.rebuildContacts(emit: true)
			}
		}))
		// Presence isn't in the SDK's sync; ask for it, and catch room changes
		// that come only through account data (m.direct) on the way. Your own
		// name and picture too, every minute or so: the SDK's profile updates
		// need sliding sync.
		tasks.append(Task { [weak self] in
			var round = 0
			while !Task.isCancelled {
				// Every 10 s, slower with long lists (about 3 requests a second at most).
				let contacts = await MainActor.run { self?.contacts.count ?? 0 }
				try? await Task.sleep(nanoseconds: UInt64(max(10, contacts / 3)) * 1_000_000_000)
				guard let self else { return }
				await self.pollPresence()
				await self.refreshRooms(nil, emit: true)
				round += 1
				if round % 6 == 0 { await self.refreshOwnProfile() }
			}
		})
		// m.typing only says when someone starts or stops; WLM's "is typing"
		// line expires after ~6 s, so repeat it while they are still at it.
		tasks.append(Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: 5_000_000_000)
				guard let self else { return }
				for (room, users) in self.typing {
					guard let peer = self.roomPeer[room] else { continue }
					for user in users { self.onEvent?(.conversation(peer: peer, .typing(from: user))) }
				}
			}
		})
	}

	private func synced(_ response: SyncResponseV2) async {
		let ids = response.rooms.joined + response.rooms.invited + response.rooms.left
		if !ids.isEmpty { await refreshRooms(ids, emit: true) }
	}

	/// Reads room state and m.direct from the SDK's store (all rooms, or `ids`).
	private func refreshRooms(_ ids: [String]?, emit: Bool) async {
		guard let client else { return }
		if let raw = try? await client.accountData(eventType: "m.direct"), let json = try? JSON(data: Data(raw.utf8)) {
			direct = json.object.mapValues { $0.array.compactMap(\.string) }
		}
		let list = ids.map { $0.compactMap { try? client.getRoom(roomId: $0) } } ?? client.rooms()
		for room in list {
			let id = room.id()
			guard let info = try? await room.roomInfo() else { continue }
			if info.membership == .joined || info.membership == .invited {
				rooms[id] = room
				roomInfos[id] = info
				if info.membership == .joined, let ids = try? await room.activeHumanMemberIdsNoSync() {
					members[id] = Set(ids)
				}
			} else {
				rooms[id] = nil
				roomInfos[id] = nil
			}
		}
		rebuildContacts(emit: emit)
	}

	/// Contacts are everyone m.direct lists with a room we're in, plus the other
	/// person in any other two-person room (allowed, not listed), ignored users
	/// (blocked) and DM inviters.
	private func rebuildContacts(emit: Bool) {
		var peers: [String: String] = [:]
		var lists: [String: MSNList] = [:]
		var invitesNow: [String: String] = [:]
		var directPeer: [String: String] = [:]
		for (user, ids) in direct where user != email {
			for id in ids { directPeer[id] = user }
		}
		for (id, info) in roomInfos {
			for hero in info.heroes { learn(hero.userId, name: hero.displayName, avatar: hero.avatarUrl) }
			switch info.membership {
			case .joined:
				if let peer = directPeer[id] {
					peers[id] = peer
					lists[peer, default: []].formUnion([.forward, .allow])
				} else if let others = members[id]?.subtracting([email]), others.count == 1, members[id]?.count == 2,
				          let peer = others.first {
					peers[id] = peer
					lists[peer, default: []].insert(.allow)
				}
			case .invited:
				guard let inviter = info.inviter, inviter.userId != email, info.isDirect || info.rawName == nil,
				      !ignored.contains(inviter.userId) else { continue }
				learn(inviter.userId, name: inviter.displayName, avatar: inviter.avatarUrl)
				invitesNow[inviter.userId] = id
			default:
				break
			}
		}
		for user in ignored {
			lists[user, default: []].remove(.allow)
			lists[user, default: []].insert(.block)
		}
		for user in invitesNow.keys { lists[user, default: []].formUnion([.reverse, .pending]) }
		let newInvites = invitesNow.keys.filter { invites[$0] == nil }
		invites = invitesNow
		roomPeer = peers
		watchConversations()

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
		let unnamed = next.keys.filter { names[$0] == nil && !profilesRequested.contains($0) }
		if !unnamed.isEmpty {
			profilesRequested.formUnion(unnamed)
			tasks.append(Task {
				await self.loadProfiles(unnamed)
				self.rebuildContacts(emit: true)
			})
		}
		guard emit else { return }
		for (user, c) in next where old[user] != c {
			onEvent?(.contactUpdated(c, previousStatus: old[user]?.status ?? .offline))
		}
		for (user, c) in old where c.isForward && next[user]?.isForward != true {
			onEvent?(.contactRemoved(email: user))
		}
		for inviter in newInvites {
			onEvent?(.addedBy(email: inviter, displayName: name(of: inviter)))
		}
	}

	private func learn(_ user: String, name: String?, avatar: String?) {
		if let name, !name.isEmpty { names[user] = name }
		if let avatar { avatarURLs[user] = avatar }
	}

	private func name(of user: String) -> String {
		names[user] ?? MatrixID.localpart(of: user)
	}

	private func picture(_ mxc: String?) -> Data? {
		mxc.flatMap { pictures[$0] }.flatMap { $0.isEmpty ? nil : $0 }
	}

	private func fetchPictures() {
		guard let client else { return }
		let wanted = Set(contacts.keys.compactMap { avatarURLs[$0] } + [myAvatarURL].compactMap { $0 })
		for mxc in wanted where pictures[mxc] == nil {
			pictures[mxc] = Data()
			tasks.append(Task {
				guard let source = try? MediaSource.fromUrl(url: mxc) else { return }
				var data: Data
				do {
					data = try await client.getMediaThumbnail(mediaSource: source, width: 96, height: 96)
				} catch {
					// Some servers don't make thumbnails of every image; take the original.
					self.log?("[matrix] no thumbnail for \(mxc) (\(error)); downloading it")
					guard let full = try? await client.getMediaContent(mediaSource: source) else { return }
					data = full
				}
				guard !data.isEmpty, self.client != nil else { return }
				self.pictures[mxc] = data
				self.pictureArrived(mxc)
			})
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

	/// Your Matrix avatar: uploaded (nil removes it).
	public func setDisplayPicture(_ data: Data?) async {
		guard let client else { return }
		do {
			if let data {
				try await client.uploadAvatar(mimeType: MatrixMessage.imageMimeType(data), data: data)
			} else {
				try await client.removeAvatar()
			}
		} catch {
			log?("[matrix] couldn't change the avatar: \(error)")
			return
		}
		myAvatarURL = try? await client.avatarUrl()
		if let myAvatarURL, let data { pictures[myAvatarURL] = data }
		displayPicture = picture(myAvatarURL)
		onEvent?(.displayPictureChanged(email: email))
	}

	private func loadOwnProfile(personalMessage psm: String?) async {
		guard let client else { return }
		displayName = (try? await client.displayName()) ?? MatrixID.localpart(of: email)
		myAvatarURL = try? await client.avatarUrl()
		if let psm {
			personalMessage = psm
		} else if let api = Self.api(client) {
			personalMessage = (try? await api.call("GET", "/presence/\(MatrixAPI.segment(email))/status"))?["status_msg"].string ?? ""
		}
	}

	/// Picks up name and picture changes made in other apps.
	private func refreshOwnProfile() async {
		guard let client else { return }
		let avatar: String?
		do { avatar = try await client.avatarUrl() } catch { return }
		let name = (try? await client.displayName()) ?? displayName
		guard name != displayName || avatar != myAvatarURL else { return }
		displayName = name
		myAvatarURL = avatar
		rebuildContacts(emit: true)
		onEvent?(.profileChanged)
	}

	/// Names and avatars for people no room has described yet.
	private func loadProfiles(_ users: [String]) async {
		guard let client else { return }
		for user in users where names[user] == nil {
			if let profile = try? await client.getProfile(userId: user) {
				learn(user, name: profile.displayName, avatar: profile.avatarUrl)
			}
		}
	}

	private func pollPresence() async {
		guard let client, let api = Self.api(client) else { return }
		let users = contacts.values.filter { !$0.lists.isDisjoint(with: [.forward, .allow]) }.map(\.email)
		let found = await withTaskGroup(of: (String, JSON?).self) { group in
			for user in users {
				group.addTask { (user, try? await api.call("GET", "/presence/\(MatrixAPI.segment(user))/status")) }
			}
			var out: [String: JSON] = [:]
			for await (user, reply) in group { if let reply { out[user] = reply } }
			return out
		}
		for (user, reply) in found {
			presence[user] = Presence(matrix: reply["presence"].string)
			statusMessages[user] = reply["status_msg"].string ?? ""
		}
	}

	// MARK: - Conversations (incoming)

	/// Follows every room a contact is in: a timeline for messages (it shows
	/// undecryptable ones and decrypts them when keys arrive later) and typing.
	private func watchConversations() {
		for (id, hs) in roomHandles where roomPeer[id] == nil {
			for h in hs { h.cancel() }
			roomHandles[id] = nil
			timelines[id] = nil
		}
		for id in roomPeer.keys where roomHandles[id] == nil {
			guard let room = rooms[id] else { continue }
			roomHandles[id] = [room.subscribeToTypingNotifications(listener: TypingListener { [weak self] users in
				Task { @MainActor in self?.typingChanged(users, room: id) }
			})]
			tasks.append(Task { [weak self] in
				guard let timeline = try? await room.timeline() else {
					self?.log?("[matrix] no timeline for \(id)")
					return
				}
				let handle = await timeline.addListener(listener: TimelineWatcher { [weak self] diffs in
					// The main queue keeps the diffs in order, which applying them needs.
					DispatchQueue.main.async { MainActor.assumeIsolated { self?.timelineChanged(diffs, room: id) } }
				})
				guard let self, self.roomHandles[id] != nil else { return handle.cancel() }
				self.roomHandles[id]?.append(handle)
				self.timelines[id] = timeline
				self.log?("[matrix] watching \(id) (\(self.roomPeer[id] ?? "?"))")
			})
		}
	}

	private func timelineChanged(_ diffs: [TimelineDiff], room id: String) {
		var items = roomItems[id] ?? []
		for diff in diffs { diff.apply(to: &items) }
		roomItems[id] = items
		incoming(diffs.flatMap(\.items).compactMap { $0.asEvent() }, room: id)
	}

	/// New or changed timeline items: each incoming message is reported once,
	/// and one that couldn't be decrypted gets a notice, then the message
	/// itself if it's decrypted later.
	private func incoming(_ items: [EventTimelineItem], room id: String) {
		guard let peer = roomPeer[id] else { return }
		for item in items {
			guard item.isRemote, !item.isOwn, case let .eventId(eventID) = item.eventOrTransactionId,
			      !ignored.contains(item.sender), case let .msgLike(content) = item.content,
			      // Like WLM, conversations start when you sign in.
			      Double(item.timestamp) / 1000 >= signedInAt.timeIntervalSince1970 - 10 else { continue }
			let sender = item.sender, name = name(of: sender)
			switch content.kind {
			case .unableToDecrypt:
				guard delivered[eventID] == nil else { continue }
				delivered[eventID] = false
				typing[id]?.remove(sender)
				log?("[matrix] \(eventID) from \(sender) can't be decrypted yet")
				onEvent?(.conversation(peer: peer, .message(from: sender, displayName: name, text: MatrixMessage.undecryptableNotice,
				                                            format: MatrixMessage.noticeFormat)))
			case let .message(message):
				guard delivered[eventID] != true else { continue }
				delivered[eventID] = true
				typing[id]?.remove(sender)
				if case let .image(image) = message.msgType {
					tasks.append(Task {
						if let data = await self.download(image.source, size: image.info?.size) {
							self.onEvent?(.conversation(peer: peer, .picture(from: sender, displayName: name, data: data, filename: image.filename)))
						} else {
							self.onEvent?(.conversation(peer: peer, .message(from: sender, displayName: name,
							                                                 text: "[Picture: \(image.filename)]", format: TextFormat())))
						}
					})
					continue
				}
				let raw = Self.content(of: item, message: message)
				if MatrixMessage.isNudge(raw) {
					onEvent?(.conversation(peer: peer, .nudge(from: sender)))
				} else {
					let text = MatrixMessage.text(of: raw, senderName: name)
					onEvent?(.conversation(peer: peer, .message(from: sender, displayName: name, text: text, format: MatrixMessage.format(of: raw))))
				}
			default:
				continue
			}
		}
	}

	/// An item's event content, from its JSON so the namespaced font and nudge
	/// keys survive; the latest edit's content if it was edited.
	private static func content(of item: EventTimelineItem, message: MessageContent) -> JSON {
		var raw = item.lazyProvider.latestJson().flatMap { try? JSON(data: Data($0.utf8)) }?["content"] ?? .null
		if !raw["m.new_content"].isNull { raw = raw["m.new_content"] }
		if raw["body"].string == nil { raw = ["msgtype": "m.text", "body": .string(message.body)] }
		return raw
	}

	/// An image message's file, decrypted if need be; nil when it's very large or fails.
	private func download(_ source: MediaSource, size: UInt64?) async -> Data? {
		guard let client, (size ?? 0) <= 20_000_000 else { return nil }
		do {
			return try await client.getMediaContent(mediaSource: source)
		} catch {
			log?("[matrix] couldn't download a picture: \(error)")
			return nil
		}
	}

	/// The conversation's timeline, once watchConversations has made it.
	private func timeline(for id: String) async -> Timeline? {
		for _ in 0..<50 {
			if let timeline = timelines[id] { return timeline }
			try? await Task.sleep(nanoseconds: 100_000_000)
		}
		return nil
	}

	/// Messages from before this sign-in, from the room's timeline, fetching
	/// more from the server when the local cache is short.
	public func recentMessages(with peer: String, limit: Int) async -> [IMHistoryMessage] {
		guard let id = existingRoom(with: peer), let timeline = await timeline(for: id) else { return [] }
		let cutoff = signedInAt.timeIntervalSince1970 - 10
		func earlier() -> [EventTimelineItem] {
			(roomItems[id] ?? []).compactMap { $0.asEvent() }.filter {
				guard case .msgLike = $0.content else { return false }
				return Double($0.timestamp) / 1000 < cutoff
			}
		}
		for _ in 0..<3 where earlier().count < limit {
			let atStart = (try? await timeline.paginateBackwards(numEvents: UInt16(limit))) ?? true
			try? await Task.sleep(nanoseconds: 300_000_000)  // let the diffs arrive
			if atStart { break }
		}
		let items = Array(earlier().suffix(limit))
		var out: [IMHistoryMessage] = []
		for (n, item) in items.enumerated() {
			guard case let .msgLike(content) = item.content else { continue }
			let outgoing = item.isOwn, sender = item.sender
			let senderName = outgoing ? displayName : name(of: sender)
			let date = Date(timeIntervalSince1970: Double(item.timestamp) / 1000)
			switch content.kind {
			case .unableToDecrypt:
				out.append(IMHistoryMessage(sender: sender, senderName: senderName, text: "This message couldn't be decrypted.",
				                            format: MatrixMessage.noticeFormat, date: date, outgoing: outgoing))
			case let .message(message):
				if case let .image(image) = message.msgType {
					// Only the last few pictures are downloaded.
					let data = n >= items.count - 6 ? await download(image.source, size: image.info?.size) : nil
					out.append(IMHistoryMessage(sender: sender, senderName: senderName, text: "[Picture: \(image.filename)]",
					                            picture: data, date: date, outgoing: outgoing))
					continue
				}
				let raw = Self.content(of: item, message: message)
				if MatrixMessage.isNudge(raw) {
					out.append(IMHistoryMessage(sender: sender, senderName: senderName,
					                            text: outgoing ? "You sent a nudge." : "\(senderName) sent a nudge.",
					                            format: MatrixMessage.noticeFormat, date: date, outgoing: outgoing))
				} else {
					out.append(IMHistoryMessage(sender: sender, senderName: senderName, text: MatrixMessage.text(of: raw, senderName: senderName),
					                            format: MatrixMessage.format(of: raw), date: date, outgoing: outgoing))
				}
			default:
				continue
			}
		}
		return out
	}

	private func typingChanged(_ users: [String], room id: String) {
		guard let peer = roomPeer[id] else { return }
		let now = Set(users).subtracting([email])
		let started = now.subtracting(typing[id] ?? [])
		typing[id] = now
		for user in started { onEvent?(.conversation(peer: peer, .typing(from: user))) }
	}

	// MARK: - Profile

	private func publishPresence() async throws {
		guard let client else { return }
		try await client.setPresence(presence: status.matrixPresence, immediate: false)
		guard let api = Self.api(client) else { return }
		_ = try await api.call("PUT", "/presence/\(MatrixAPI.segment(email))/status",
		                       body: ["presence": .string(status.matrixState), "status_msg": .string(personalMessage)])
	}

	public func setStatus(_ presence: Presence) async throws {
		guard client != nil else { return }
		status = presence
		try await publishPresence()
		onEvent?(.profileChanged)
	}

	public func setDisplayName(_ name: String) async throws {
		guard let client, !name.isEmpty else { return }
		try await client.setDisplayName(name: name)
		displayName = name
		onEvent?(.profileChanged)
	}

	public func setPersonalMessage(_ text: String) async throws {
		guard client != nil else { return }
		personalMessage = text
		try await publishPresence()
		onEvent?(.profileChanged)
	}

	// MARK: - Contact management

	public func addContact(_ raw: String) async throws {
		let user = raw.trimmingCharacters(in: .whitespaces).lowercased()
		guard MatrixID.isUserID(user) else { throw MatrixError.badUserID(raw) }
		guard client != nil else { throw MSNPError.disconnected }
		guard user != email else { return }
		if invites[user] != nil { return try await respondToAdd(user, allow: true, addToList: true) }
		if contacts[user]?.isForward != true {
			// Reuse a two-person room with them only if it's encrypted; otherwise
			// start an encrypted DM, as Element would.
			if let id = roomPeer.first(where: { $0.value == user && isEncrypted($0.key) })?.key {
				try await setDirect(id, user, true)
			} else {
				_ = try await createDirectRoom(with: user)
			}
		}
		await loadProfiles([user])
		rebuildContacts(emit: true)
	}

	/// Accepting joins the DM room; declining leaves it and blocks the inviter, as WLM's "Block" did.
	public func respondToAdd(_ user: String, allow: Bool, addToList: Bool) async throws {
		guard client != nil else { throw MSNPError.disconnected }
		guard let id = invites[user], let room = rooms[id] else {
			if allow, addToList { try await addContact(user) } else if !allow { try await block(user) }
			return
		}
		if allow {
			try await room.join()
			await refreshRooms([id], emit: false)
			if addToList { try await setDirect(id, user, true) } else { rebuildContacts(emit: true) }
		} else {
			try? await room.leave()
			try await block(user)
		}
	}

	/// Takes them off m.direct; the room stays, so they can still message you (as in WLM).
	public func removeContact(_ user: String) async throws {
		var next = try await serverDirect()
		guard next[user] != nil else { return }
		next[user] = nil
		try await putDirect(next)
	}

	public func block(_ user: String) async throws {
		try await setIgnored(user, true)
	}

	public func unblock(_ user: String) async throws {
		try await setIgnored(user, false)
	}

	/// m.ignored_user_list from the server, changed and written back: the SDK's
	/// own (un)ignoreUser go by its cached copy, which lags behind quick changes.
	private func setIgnored(_ user: String, _ ignore: Bool) async throws {
		guard let client, let api = Self.api(client) else { throw MSNPError.disconnected }
		let path = "/user/\(MatrixAPI.segment(email))/account_data/m.ignored_user_list"
		var users: [String: JSON]
		do {
			users = try await api.call("GET", path)["ignored_users"].object
		} catch MatrixError.server(404, _, _) {
			users = [:]
		}
		users[user] = ignore ? .object([:]) : nil
		_ = try await api.call("PUT", path, body: ["ignored_users": .object(users)])
		ignored = Set(users.keys)
		rebuildContacts(emit: true)
	}

	/// Lists `id` as a DM with `user` in m.direct.
	private func setDirect(_ id: String, _ user: String, _ isDirect: Bool) async throws {
		var next = try await serverDirect()
		var list = next[user] ?? []
		if isDirect, !list.contains(id) { list.append(id) }
		if !isDirect { list.removeAll { $0 == id } }
		next[user] = list.isEmpty ? nil : list
		try await putDirect(next)
	}

	private func putDirect(_ next: [String: [String]]) async throws {
		guard let client else { throw MSNPError.disconnected }
		let content = JSON.object(next.mapValues { .array($0.map(JSON.string)) })
		try await client.setAccountData(eventType: "m.direct", content: String(decoding: content.encoded(), as: UTF8.self))
		direct = next
		rebuildContacts(emit: true)
	}

	/// m.direct as the server has it now. The SDK writes it too (creating and
	/// joining DMs), so changes start from this rather than a cached copy.
	private func serverDirect() async throws -> [String: [String]] {
		guard let client, let api = Self.api(client) else { throw MSNPError.disconnected }
		do {
			let json = try await api.call("GET", "/user/\(MatrixAPI.segment(email))/account_data/m.direct")
			return json.object.mapValues { $0.array.compactMap(\.string) }
		} catch MatrixError.server(404, _, _) {
			return [:]
		}
	}

	/// A new encrypted DM, as Element makes them.
	private func createDirectRoom(with user: String) async throws -> String {
		guard let client else { throw MSNPError.disconnected }
		let id = try await client.createRoom(request: CreateRoomParameters(
			name: nil, isEncrypted: true, isDirect: true, visibility: .private, preset: .trustedPrivateChat, invite: [user]))
		let room = try await client.awaitRoomRemoteEcho(roomId: id)
		rooms[id] = room
		if let info = try? await room.roomInfo() { roomInfos[id] = info }
		try await setDirect(id, user, true)
		return id
	}

	// MARK: - Conversations (outgoing)

	public func sendMessage(to peer: String, text: String, format: TextFormat = TextFormat()) async {
		do {
			let room = try await conversationRoom(with: peer)
			try await send(MatrixMessage.content(text: text, format: format), in: room)
			stopTyping(in: room)
		} catch {
			onEvent?(.conversation(peer: peer, .deliveryFailed(text: text, reason: Self.describe(error))))
		}
	}

	/// Typing goes only to an existing room, at most every 4 s while keys are pressed.
	public func sendTyping(to peer: String) {
		guard let id = existingRoom(with: peer), let room = rooms[id] else { return }
		if let last = lastTypingSent[id], Date().timeIntervalSince(last) < 4 { return }
		lastTypingSent[id] = Date()
		Task { try? await room.typingNotice(isTyping: true) }
	}

	private func stopTyping(in room: Room) {
		guard lastTypingSent.removeValue(forKey: room.id()) != nil else { return }
		Task { try? await room.typingNotice(isTyping: false) }
	}

	public var supportsPictures: Bool { true }

	/// An m.image; in encrypted rooms the SDK encrypts the file before uploading it.
	public func sendPicture(to peer: String, data: Data, filename: String) async {
		do {
			let room = try await conversationRoom(with: peer)
			guard let timeline = await timeline(for: room.id()) else { throw MatrixError.badResponse("the conversation isn't loaded yet") }
			let size = Self.imageSize(data)
			let info = ImageInfo(height: size.map { UInt64($0.height) }, width: size.map { UInt64($0.width) },
			                     mimetype: MatrixMessage.imageMimeType(data), size: UInt64(data.count),
			                     thumbnailInfo: nil, thumbnailSource: nil, blurhash: nil, isAnimated: nil)
			let params = UploadParameters(source: .data(bytes: data, filename: filename), caption: nil, formattedCaption: nil,
			                              mentions: nil, inReplyTo: nil)
			try await timeline.sendImage(params: params, thumbnailSource: nil, imageInfo: info).join()
		} catch {
			onEvent?(.conversation(peer: peer, .deliveryFailed(text: filename, reason: Self.describe(error))))
		}
	}

	private nonisolated static func imageSize(_ data: Data) -> (width: Int, height: Int)? {
		guard let source = CGImageSourceCreateWithData(data as CFData, nil),
		      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
		      let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
		return (width, height)
	}

	public func sendNudge(to peer: String) async throws {
		try await send(MatrixMessage.nudge(), in: try await conversationRoom(with: peer))
	}

	public func closeConversation(with peer: String) {
		if let id = existingRoom(with: peer), let room = rooms[id] { stopTyping(in: room) }
	}

	/// The room to talk to `user` in, of the rooms with them we're in (m.direct's
	/// newest first): an encrypted one they're in too, else any they're in,
	/// else the newest listed.
	private func existingRoom(with user: String) -> String? {
		let listed = (direct[user] ?? []).reversed().filter { roomInfos[$0]?.membership == .joined }
		let others = roomPeer.filter { $0.value == user && !listed.contains($0.key) }.map(\.key)
		let shared = (listed + others).filter { members[$0]?.contains(user) == true }
		return shared.first(where: isEncrypted) ?? shared.first ?? listed.first ?? others.first
	}

	private func isEncrypted(_ id: String) -> Bool {
		roomInfos[id]?.encryptionState == .encrypted
	}

	private func conversationRoom(with peer: String) async throws -> Room {
		guard MatrixID.isUserID(peer) else { throw MatrixError.badUserID(peer) }
		let id: String
		if let existing = existingRoom(with: peer) { id = existing } else { id = try await createDirectRoom(with: peer) }
		guard let room = rooms[id] else { throw MatrixError.badResponse("room \(id) isn't loaded") }
		// They left the DM: invite them back, as other clients do.
		if members[id]?.contains(peer) == false {
			try? await room.inviteUserById(userId: peer)
		}
		return room
	}

	/// Raw, so the namespaced font and nudge keys survive; the SDK encrypts it.
	private func send(_ content: JSON, in room: Room) async throws {
		log?("[matrix] sending to \(room.id())")
		let id = try await room.sendRaw(eventType: "m.room.message", content: String(decoding: content.encoded(), as: UTF8.self),
		                                requestConfigOverride: nil)
		log?("[matrix] sent \(id)")
	}

	private static func describe(_ error: Error) -> String {
		(error as? LocalizedError)?.errorDescription ?? "\(error)"
	}

	// MARK: - Verification

	private func watchVerification() {
		guard let client else { return }
		let encryption = client.encryption()
		handles.append(encryption.verificationStateListener(listener: VerificationStateWatcher { [weak self] state in
			Task { @MainActor in self?.verificationChanged(state) }
		}))
		tasks.append(Task { [weak self] in
			await encryption.waitForE2eeInitializationTasks()
			guard let self, self.client != nil else { return }
			if let controller = try? await client.getSessionVerificationController() {
				controller.setDelegate(delegate: VerificationListener { [weak self] event in
					Task { @MainActor in await self?.verificationEvent(event) }
				})
				self.verification = controller
			}
			self.verificationChanged(encryption.verificationState())
		})
	}

	private func verificationChanged(_ state: VerificationState) {
		guard state != .unknown else { return }
		isVerified = state == .verified
		onVerification?(.state(verified: isVerified))
	}

	private func verificationEvent(_ event: VerificationListener.Event) async {
		switch event {
		case let .request(details):
			incomingVerification = details
			try? await verification?.acknowledgeVerificationRequest(senderId: details.senderProfile.userId, flowId: details.flowId)
			onVerification?(.requested(by: details.deviceDisplayName ?? details.deviceId))
		case .accepted:
			// We asked; the other session agreed, so start comparing emoji.
			try? await verification?.startSasVerification()
		case let .data(.emojis(emojis, _)):
			onVerification?(.emojis(emojis.map { ($0.symbol(), $0.description()) }))
		case let .data(.decimals(values)):
			onVerification?(.emojis(values.map { (String($0), "") }))
		case .finished:
			incomingVerification = nil
			onVerification?(.finished)
		case let .cancelled(why):
			incomingVerification = nil
			onVerification?(.cancelled(why))
		}
	}

	/// Asks your other sessions (e.g. Element) to verify this one with emoji.
	public func requestVerification() async throws {
		guard let verification else { throw MatrixError.badResponse("encryption isn't ready yet") }
		try await verification.requestDeviceVerification()
	}

	/// Accepts another session's request to verify this one.
	public func acceptVerification() async throws {
		guard let verification, incomingVerification != nil else { return }
		try await verification.acceptVerificationRequest()
	}

	/// The emoji match (or not) on both screens.
	public func confirmVerification(_ match: Bool) async throws {
		guard let verification else { return }
		if match { try await verification.approveVerification() } else { try await verification.declineVerification() }
	}

	public func cancelVerification() async {
		incomingVerification = nil
		try? await verification?.cancelVerification()
	}

	/// Verifies this session with the recovery key, which also restores key backup.
	public func recover(recoveryKey: String) async throws {
		guard let client else { throw MSNPError.disconnected }
		try await client.encryption().recover(recoveryKey: recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines))
	}
}

extension Presence {
	var matrixPresence: PresenceState {
		switch matrixState {
		case "online": return .online
		case "offline": return .offline
		default: return .unavailable
		}
	}
}

// MARK: - SDK listener adapters (called on SDK threads)

private final class SyncListener: SyncListenerV2, @unchecked Sendable {
	let handler: (SyncResponseV2) -> Void
	init(_ handler: @escaping (SyncResponseV2) -> Void) { self.handler = handler }
	func onUpdate(response: SyncResponseV2) { handler(response) }
}

private final class TimelineWatcher: TimelineListener, @unchecked Sendable {
	let handler: ([TimelineDiff]) -> Void
	init(_ handler: @escaping ([TimelineDiff]) -> Void) { self.handler = handler }
	func onUpdate(diff: [TimelineDiff]) { handler(diff) }
}

private extension TimelineDiff {
	func apply(to items: inout [TimelineItem]) {
		switch self {
		case let .append(values): items.append(contentsOf: values)
		case .clear: items.removeAll()
		case let .pushFront(value): items.insert(value, at: 0)
		case let .pushBack(value): items.append(value)
		case .popFront: if !items.isEmpty { items.removeFirst() }
		case .popBack: if !items.isEmpty { items.removeLast() }
		case let .insert(index, value): items.insert(value, at: min(Int(index), items.count))
		case let .set(index, value): if Int(index) < items.count { items[Int(index)] = value }
		case let .remove(index): if Int(index) < items.count { items.remove(at: Int(index)) }
		case let .truncate(length): if Int(length) < items.count { items.removeSubrange(Int(length)...) }
		case let .reset(values): items = values
		}
	}

	/// The items this change brings in (new or replaced); removals carry none.
	var items: [TimelineItem] {
		switch self {
		case let .append(values), let .reset(values): return values
		case let .pushFront(value), let .pushBack(value), let .insert(_, value), let .set(_, value): return [value]
		case .clear, .popFront, .popBack, .remove, .truncate: return []
		}
	}
}

private final class TypingListener: TypingNotificationsListener, @unchecked Sendable {
	let handler: ([String]) -> Void
	init(_ handler: @escaping ([String]) -> Void) { self.handler = handler }
	func call(typingUserIds: [String]) { handler(typingUserIds) }
}

private final class IgnoredListener: IgnoredUsersListener, @unchecked Sendable {
	let handler: ([String]) -> Void
	init(_ handler: @escaping ([String]) -> Void) { self.handler = handler }
	func call(ignoredUserIds: [String]) { handler(ignoredUserIds) }
}


private final class VerificationStateWatcher: VerificationStateListener, @unchecked Sendable {
	let handler: (VerificationState) -> Void
	init(_ handler: @escaping (VerificationState) -> Void) { self.handler = handler }
	func onUpdate(status: VerificationState) { handler(status) }
}

private final class AuthErrorListener: ClientDelegate, @unchecked Sendable {
	let handler: (Bool) -> Void
	init(_ handler: @escaping (Bool) -> Void) { self.handler = handler }
	func didReceiveAuthError(isSoftLogout: Bool) { handler(isSoftLogout) }
	func onBackgroundTaskErrorReport(taskName: String, error: BackgroundTaskFailureReason) {}
}

private final class VerificationListener: SessionVerificationControllerDelegate, @unchecked Sendable {
	enum Event {
		case request(SessionVerificationRequestDetails)
		case accepted
		case data(SessionVerificationData)
		case finished
		case cancelled(String?)
	}

	let handler: (Event) -> Void
	init(_ handler: @escaping (Event) -> Void) { self.handler = handler }
	func didReceiveVerificationRequest(details: SessionVerificationRequestDetails) { handler(.request(details)) }
	func didAcceptVerificationRequest() { handler(.accepted) }
	func didStartSasVerification() {}
	func didReceiveVerificationData(data: SessionVerificationData) { handler(.data(data)) }
	func didFail() { handler(.cancelled("The verification failed.")) }
	func didCancel() { handler(.cancelled(nil)) }
	func didFinish() { handler(.finished) }
}

/// Keeps tokens the SDK refreshes in the session store.
private final class SessionSaver: ClientSessionDelegate, @unchecked Sendable {
	let store: MatrixSessionStore
	init(store: MatrixSessionStore) { self.store = store }

	func retrieveSessionFromKeychain(userId: String) throws -> Session {
		guard let saved = store.load(userId) else { throw MatrixError.badResponse("no saved session for \(userId)") }
		return saved.session
	}

	func saveSessionInKeychain(session: Session) {
		if let saved = store.load(session.userId) { store.save(saved.updating(session)) }
	}
}
#endif
