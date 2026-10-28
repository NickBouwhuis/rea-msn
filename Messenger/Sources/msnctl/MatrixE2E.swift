import Foundation
import MatrixKit
import MSNKit

extension CLI {
	/// e2e against a Matrix homeserver: the same WLM walk-through, with
	/// Matrix's differences (Busy reads back as Away; there is no "contact is
	/// offline" failure because the server keeps the message). With a third
	/// account, also checks that encrypted DMs are shown and refused, not
	/// answered in the clear.
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
		try await step("A adds B (createRoom is_direct + m.direct)") {
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
		try await Task.sleep(nanoseconds: 500_000_000)  // let the sign-outs reach the server
		print("All steps passed.")
	}

	/// C (over the raw API, as Element would) opens an encrypted DM with A and
	/// sends an m.room.encrypted event. A must show a notice for it and refuse
	/// to reply rather than send plaintext into the room.
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
		try await step("A shows the encrypted message as unreadable") {
			try await waitFor("encrypted notice") { received(MatrixMessage.encryptedNotice) }
		}
		try await step("A refuses to reply in the clear") {
			await a.sendMessage(to: idC, text: "this must not be sent")
			try await waitFor("delivery refused", timeout: 5) { failures.contains { $0.contains("end-to-end encrypted") } }
		}
		try await step("reset: C leaves, A removes C") {
			_ = try await api?.call("POST", "/rooms/\(MatrixAPI.segment(room))/leave", body: [:])
			_ = try await api?.call("POST", "/logout", body: [:])
			try await a.removeContact(idC)
		}
		a.onEvent = previous
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

	private func waitFor(_ what: String, timeout: Double = 15, _ cond: () -> Bool) async throws {
		let deadline = Date().addingTimeInterval(timeout)
		while !cond() {
			if Date() > deadline { throw MSNPError.timeout(what) }
			try await Task.sleep(nanoseconds: 100_000_000)
		}
	}
}
