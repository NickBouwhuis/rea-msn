import Foundation
import MatrixKit
import MSNKit

extension CLI {
	/// e2e against a Matrix homeserver: the same WLM walk-through, with
	/// Matrix's differences (Busy reads back as Away; there is no "contact is
	/// offline" failure because the server keeps the message). With
	/// matrix-rust-sdk, DMs are end-to-end encrypted, which it checks on the
	/// server. With a third account, also checks a message that can't be
	/// decrypted: shown as a notice, and never answered in the clear.
	func matrixE2E(_ idA: String, _ idB: String, _ password: String, encryptedFrom idC: String?) async throws {
		let a = makeClient("A"), b = makeClient("B")
		var inbox: [String] = []
		/// "B<-@alice:localhost: text": the raw text (inbox holds debug descriptions, which escape quotes).
		var texts: [String] = []
		var formats: [String: TextFormat] = [:]
		var addedPrompts: [String] = []
		for (client, tag) in [(a, "A"), (b, "B")] {
			client.onEvent = { event in
				switch event {
				case let .conversation(peer, kind):
					inbox.append("\(tag)<-\(peer): \(kind)")
					if case let .message(_, _, text, format) = kind {
						texts.append("\(tag)<-\(peer): \(text)")
						formats[text] = format
					}
				case let .addedBy(email, _):
					addedPrompts.append("\(tag):\(email)")
				default:
					break
				}
			}
		}

		func received(by tag: String, from peer: String, _ text: String) -> Bool {
			(inbox + texts).contains { $0.hasPrefix("\(tag)<-\(peer)") && $0.contains(text) }
		}

		try await step("bad password is rejected (M_FORBIDDEN)") {
			do {
				try await makeClient("X").signIn(email: idA, password: password + "-wrong")
				throw MSNPError.unexpected("sign-in succeeded")
			} catch MatrixError.authenticationFailed {}
		}
		try await step("A signs in (/login → /sync → presence)") {
			try await a.signIn(email: idA, password: password)
		}
		try await step("B signs in as Busy") {
			try await b.signIn(email: idB, password: password, status: .busy)
		}
		try await step("A sets display name and personal message (profile, status_msg)") {
			try await a.setDisplayName("Alice ☕ on Matrix")
			try await a.setPersonalMessage("Ported with rea + Ghidra")
		}
		for (client, other, tag) in [(a, idB, "A"), (b, idA, "B")] {
			if client.contacts[other]?.isBlocked == true {
				try await step("reset: \(tag) unblocks \(other)") { try await client.unblock(other) }
			}
			if client.contacts[other]?.isForward == true {
				try await step("reset: \(tag) removes \(other)") { try await client.removeContact(other) }
			}
		}
		let encrypted = MatrixClient.supportsEncryption
		try await step("A adds B (createRoom is_direct\(encrypted ? " + m.room.encryption" : "") + m.direct)") {
			try await a.addContact(idB)
			guard a.contacts[idB]?.isForward == true else { throw MSNPError.unexpected("B not on A's list") }
		}
		try await step("B is told A added them (DM invite)") {
			// Removing a contact keeps the room, so on re-runs there's no new invite.
			try await waitFor("B's add prompt") {
				addedPrompts.contains("B:\(idA)") || b.contacts[idA]?.lists.contains(.allow) == true
			}
		}
		try await step("B accepts and adds A back (join + m.direct)") {
			try await b.respondToAdd(idA, allow: true, addToList: true)
			guard b.contacts[idA]?.isForward == true else { throw MSNPError.unexpected("A not on B's list") }
		}
		try await step("A sees B as Away (Busy is \"unavailable\" on Matrix)") {
			try await waitFor("B presence") { a.contacts[idB]?.status == .away }
		}
		try await step("B goes Online and A sees it") {
			try await b.setStatus(.online)
			try await waitFor("B online") { a.contacts[idB]?.status == .online }
		}
		try await step("B sees A's name and personal message") {
			try await waitFor("A profile") {
				b.contacts[idA]?.displayName == "Alice ☕ on Matrix"
					&& b.contacts[idA]?.personalMessage == "Ported with rea + Ghidra"
			}
		}
		let run = String(Int(Date().timeIntervalSince1970))
		try await step("A → B instant message (m.room.message)") {
			await a.sendMessage(to: idB, text: "Hello from Messenger! 😀 <&> \(run)")
			try await waitFor("B receives message") { received(by: "B", from: idA, "Hello from Messenger! 😀 <&> \(run)") }
		}
		try await step("B → A reply") {
			await b.sendMessage(to: idA, text: "Hi Alice, it works \(run)")
			try await waitFor("A receives reply") { received(by: "A", from: idB, "Hi Alice, it works \(run)") }
		}
		if encrypted {
			try await step("the server only has ciphertext (m.room.encrypted)") {
				let events = try await recentEvents(idB, password, inDMWith: idA)
				guard events.contains(where: { $0.type == "m.room.encrypted" }) else { throw MSNPError.unexpected("no encrypted events: \(events)") }
				guard !events.contains(where: { $0.body?.contains(run) == true }) else { throw MSNPError.unexpected("plaintext on the server") }
			}
		}
		try await step("fonts and colours round-trip") {
			var format = TextFormat()
			format.fontName = "Comic Sans MS"
			format.bold = true
			format.color = 0xFF0000
			await a.sendMessage(to: idB, text: "in colour \(run)", format: format)
			try await waitFor("formatted message") { formats["in colour \(run)"] == format }
		}
		try await step("typing notification (m.typing)") {
			b.sendTyping(to: idA)
			try await waitFor("A sees typing") { received(by: "A", from: idB, "typing") }
		}
		try await step("nudge") {
			try await a.sendNudge(to: idB)
			try await waitFor("B gets nudge") { received(by: "B", from: idA, "nudge") }
		}
		try await step("B signs out and A sees Offline") {
			b.signOut()
			try await waitFor("B offline") { a.contacts[idB]?.status == .offline }
		}
		try await step("A blocks and unblocks B (m.ignored_user_list)") {
			try await a.block(idB)
			guard a.contacts[idB]?.isBlocked == true else { throw MSNPError.unexpected("not blocked") }
			try await a.unblock(idB)
			guard a.contacts[idB]?.isBlocked == false else { throw MSNPError.unexpected("still blocked") }
		}
		if let idC {
			try await encryptedDMCheck(a, idA: idA, idC: idC, password: password) {
				received(by: "A", from: idC, $0)
			}
		}
		try await step("contact list survives a fresh sign-in") {
			a.signOut()
			let a2 = makeClient("A2")
			try await a2.signIn(email: idA, password: password)
			guard a2.contacts[idB]?.isForward == true else { throw MSNPError.unexpected("B missing from A's list") }
			guard a2.displayName == "Alice ☕ on Matrix" else { throw MSNPError.unexpected("name not kept: \(a2.displayName)") }
			guard a2.personalMessage == "Ported with rea + Ghidra" else { throw MSNPError.unexpected("PSM not kept: \(a2.personalMessage)") }
			a2.signOut()
		}
		#if os(macOS)
		try await step("a remembered session comes back without the password, as the same device") {
			let store = MemoryMatrixSessionStore()
			let dir = FileManager.default.temporaryDirectory.appendingPathComponent("msnctl-\(UUID().uuidString)", isDirectory: true)
			let first = MatrixClient(homeserver: homeserver, store: store, directory: dir)
			try await first.signIn(email: idA, password: password)
			let device = first.deviceID
			first.signOut()  // "Remember me": keeps the session
			let again = MatrixClient(homeserver: homeserver, store: store, directory: dir)
			again.keepsSessionOnSignOut = false
			try await again.signIn(email: idA, password: "")
			guard again.deviceID == device else { throw MSNPError.unexpected("new device \(again.deviceID), not \(device)") }
			guard again.contacts[idB]?.isForward == true else { throw MSNPError.unexpected("B missing after restore") }
			again.signOut()  // and this time log it out
		}
		#endif
		try await Task.sleep(nanoseconds: 500_000_000)  // let the sign-outs reach the server
		print("All steps passed.")
	}

	/// C (over the raw API) opens an encrypted DM with A and sends an
	/// m.room.encrypted event nobody can decrypt. A must show a notice for it,
	/// and its reply must not go out in the clear: refused without encryption
	/// support, encrypted with it.
	private func encryptedDMCheck(_ a: any IMService, idA: String, idC: String, password: String,
	                              received: @escaping (String) -> Bool) async throws {
		var failures: [String] = []
		let previous = a.onEvent
		a.onEvent = { event in
			previous?(event)
			if case let .conversation(_, .deliveryFailed(_, reason)) = event { failures.append(reason) }
		}
		var api: MatrixAPI?
		var room = ""
		try await step("C opens an encrypted DM with A and A accepts") {
			let base: URL
			if let homeserver { base = homeserver } else { base = try await MatrixAPI.discover(serverName: MatrixID.serverName(of: idC) ?? "") }
			var c = MatrixAPI(baseURL: base)
			c.accessToken = try await c.login(user: idC, password: password, deviceID: "WLME2ECAROL", deviceName: "msnctl e2e").accessToken
			api = c
			room = try await c.call("POST", "/createRoom", body: [
				"preset": "trusted_private_chat", "is_direct": true, "invite": [.string(idA)],
				"initial_state": [["type": "m.room.encryption", "state_key": "", "content": ["algorithm": "m.megolm.v1.aes-sha2"]]],
			])["room_id"].string ?? ""
			try await waitFor("A's invite from C") { a.contacts[idC]?.lists.contains(.pending) == true }
			try await a.respondToAdd(idC, allow: true, addToList: true)
			_ = try await c.call("PUT", "/rooms/\(MatrixAPI.segment(room))/send/m.room.encrypted/e2e\(Date().timeIntervalSince1970)", body: [
				"algorithm": "m.megolm.v1.aes-sha2", "ciphertext": "AwgAEnAc", "device_id": "WLME2ECAROL",
				"sender_key": "x", "session_id": "y",
			])
		}
		let encrypted = MatrixClient.supportsEncryption
		try await step("A shows the undecryptable message as a notice") {
			try await waitFor("notice") { received(encrypted ? MatrixMessage.undecryptableNotice : MatrixMessage.encryptedNotice) }
		}
		if encrypted {
			try await step("A's reply to C goes out encrypted") {
				await a.sendMessage(to: idC, text: "a secret reply")
				try await Task.sleep(nanoseconds: 3_000_000_000)
				guard failures.isEmpty else { throw MSNPError.unexpected("not delivered: \(failures)") }
				let events = try await recentEvents(idC, password, inDMWith: idA, room: room)
				guard events.contains(where: { $0.sender == idA && $0.type == "m.room.encrypted" }),
				      !events.contains(where: { $0.body == "a secret reply" }) else { throw MSNPError.unexpected("reply not encrypted: \(events)") }
			}
		} else {
			try await step("A refuses to reply in the clear") {
				await a.sendMessage(to: idC, text: "this must not be sent")
				try await waitFor("delivery refused", timeout: 5) { failures.contains { $0.contains("end-to-end encrypted") } }
			}
		}
		try await step("reset: C leaves, A removes C") {
			_ = try await api?.call("POST", "/rooms/\(MatrixAPI.segment(room))/leave", body: [:])
			_ = try await api?.call("POST", "/logout", body: [:])
			try await a.removeContact(idC)
		}
		a.onEvent = previous
	}

	#if os(macOS)  // matrix-rust-sdk, which has verification, is macOS-only so far
	/// Signs in and, for `seconds`, accepts verification requests from your
	/// other sessions, confirming the emoji. On a fresh account this first
	/// session sets up cross-signing, so it can verify the others.
	func verifyResponder(_ id: String, _ password: String, seconds: Double) async throws {
		let client = MatrixClient.throwaway(homeserver: homeserver)
		client.onVerification = { event in
			switch event {
			case let .state(verified):
				print("this session is \(verified ? "verified" : "not verified")")
			case let .requested(device):
				print("verification requested by \(device); accepting")
				Task { try? await client.acceptVerification() }
			case let .emojis(emojis):
				print("emoji: " + emojis.map { "\($0.symbol) \($0.description)" }.joined(separator: ", "))
				Task { try? await client.confirmVerification(true) }
			case .finished:
				print("verification finished")
			case let .cancelled(why):
				print("verification cancelled: \(why ?? "")")
			}
		}
		try await client.signIn(email: id, password: password)
		print("Signed in as \(client.email); waiting \(Int(seconds)) s for requests")
		try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
		client.signOut()
	}

	/// Signs in as a new session, asks your other sessions to verify it,
	/// confirms the emoji and waits until it is verified.
	func verifyRequester(_ id: String, _ password: String) async throws {
		let client = MatrixClient.throwaway(homeserver: homeserver)
		var ready = false, verified = false, cancelled: String?
		client.onVerification = { event in
			switch event {
			case let .state(v):
				ready = true
				verified = v
			case let .emojis(emojis):
				print("emoji: " + emojis.map { "\($0.symbol) \($0.description)" }.joined(separator: ", "))
				Task { try? await client.confirmVerification(true) }
			case .finished:
				print("verification finished")
			case let .cancelled(why):
				cancelled = why ?? "cancelled"
			case .requested:
				break
			}
		}
		try await step("new session signs in") { try await client.signIn(email: id, password: password) }
		try await step("encryption is ready and the session starts unverified") {
			try await waitFor("verification state") { ready }
			guard !verified else { throw MSNPError.unexpected("already verified") }
		}
		try await step("emoji verification with the other session") {
			try await client.requestVerification()
			try await waitFor("verified", timeout: 60) { verified || cancelled != nil }
			if let cancelled { throw MSNPError.unexpected("verification \(cancelled)") }
		}
		client.signOut()
		try await Task.sleep(nanoseconds: 500_000_000)
		print("All steps passed.")
	}
	#endif

	/// The last events of `user`'s DM with `peer` (or of `room`), as the server
	/// stores them, read with a temporary device over the plain API.
	private func recentEvents(_ user: String, _ password: String, inDMWith peer: String,
	                          room: String? = nil) async throws -> [(type: String, sender: String, body: String?)] {
		let base: URL
		if let homeserver { base = homeserver } else { base = try await MatrixAPI.discover(serverName: MatrixID.serverName(of: user) ?? "") }
		var api = MatrixAPI(baseURL: base)
		api.accessToken = try await api.login(user: user, password: password, deviceID: "WLME2ECHECK", deviceName: "msnctl e2e check").accessToken
		var id = room
		if id == nil {
			let direct = try await api.call("GET", "/user/\(MatrixAPI.segment(user))/account_data/m.direct")
			id = direct[peer].array.last?.string
		}
		var events: [(type: String, sender: String, body: String?)] = []
		if let id {
			let chunk = try await api.call("GET", "/rooms/\(MatrixAPI.segment(id))/messages", query: ["dir": "b", "limit": "20"])["chunk"]
			events = chunk.array.map { ($0["type"].string ?? "", $0["sender"].string ?? "", $0["content"]["body"].string) }
		}
		_ = try? await api.call("POST", "/logout", body: [:])
		return events
	}

	private func step(_ name: String, _ body: () async throws -> Void) async throws {
		do {
			try await body()
			print("PASS  \(name)")
		} catch {
			print("FAIL  \(name): \(error.localizedDescription)")
			throw error
		}
	}

	/// 30 s: with matrix-rust-sdk, presence is polled every 10 s.
	private func waitFor(_ what: String, timeout: Double = 30, _ cond: () -> Bool) async throws {
		let deadline = Date().addingTimeInterval(timeout)
		while !cond() {
			if Date() > deadline { throw MSNPError.timeout(what) }
			try await Task.sleep(nanoseconds: 100_000_000)
		}
	}
}
