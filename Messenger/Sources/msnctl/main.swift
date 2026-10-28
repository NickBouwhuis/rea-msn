import Foundation
import MSNKit

// msnctl — exercise MSNKit without the GUI.
//
//   msnctl [--local|--escargot|--host H] [-v] check EMAIL PASSWORD [SECONDS]   read-only sign-in summary
//   msnctl [--local|--escargot] [-v] [--echo] login EMAIL PASSWORD    sign in, print the list and IMs
//   PASSWORD "-" reads $MSN_PASSWORD
//   msnctl [--local] [-v] say EMAIL PASSWORD TO TEXT [SECONDS] [--nudge] [--picture FILE] [--invite EMAIL]
//   msnctl [--local] [-v] wink EMAIL PASSWORD TO PREVIEW.png [SECONDS]     a wink around a preview image
//   msnctl [--local] [-v] sendfile EMAIL PASSWORD TO FILE [SECONDS]        offer a file, report its fate
//   msnctl [--local] [-v] e2e EMAIL_A EMAIL_B PASSWORD [EMAIL_C]   end-to-end scenario
//     (with EMAIL_C, also a group conversation; all accounts share PASSWORD)

@MainActor
struct CLI {
	var config = ServerConfig.localDev
	var verbose = false
	/// `login` replies "echo: …" to incoming IMs only with --echo (never on real accounts by default).
	var echo = false

	func log(_ s: String) {
		if verbose { FileHandle.standardError.write(Data((s + "\n").utf8)) }
	}

	func makeClient(_ tag: String) -> MessengerClient {
		let c = MessengerClient(config: config)
		c.log = verbose ? { s in FileHandle.standardError.write(Data("[\(tag)] \(s)\n".utf8)) } : nil
		return c
	}

	/// Read-only health check: sign in, summarise the account, sign out. Prints
	/// counts rather than contact addresses and changes nothing on the account.
	func check(_ email: String, _ password: String, seconds: Double) async throws {
		let client = makeClient("me")
		let started = Date()
		try await client.signIn(email: email, password: password, status: .appearOffline)
		print("Signed in as \(client.displayName) <\(client.email)> in \(String(format: "%.1f", Date().timeIntervalSince(started))) s (Appear Offline)")
		print("Personal message: \(client.personalMessage.isEmpty ? "(none)" : client.personalMessage)")
		try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))  // let ILN/NLN/UBX arrive
		let list = client.contacts.values.filter(\.isForward)
		var byStatus: [String: Int] = [:]
		for c in list { byStatus[c.status.displayName, default: 0] += 1 }
		print("Contacts: \(list.count) in \(client.groups.count) group(s); " + byStatus.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
		print("With personal message: \(list.filter { !$0.personalMessage.isEmpty }.count); blocked: \(client.contacts.values.filter(\.isBlocked).count); pending adds: \(client.contacts.values.filter { $0.lists.contains(.pending) }.count)")
		client.signOut()
	}

	func login(_ email: String, _ password: String) async throws {
		let client = makeClient("me")
		client.onEvent = { event in
			switch event {
			case let .contactUpdated(c, previous) where c.status != previous:
				print("* \(c.displayName) <\(c.email)> is now \(c.status.displayName)")
			case let .addedBy(email, name):
				print("* \(name) <\(email)> added you to their contact list")
			case let .conversation(peer, .message(_, name, text, _)):
				print("\(name) says: \(text)")
				if echo { Task { await client.sendMessage(to: peer, text: "echo: \(text)") } }
			case let .conversation(_, .nudge(from)):
				print("* \(from) sent you a nudge!")
			case let .signedOut(reason):
				print("* signed out: \(reason ?? "")")
				exit(1)
			default:
				break
			}
		}
		try await client.signIn(email: email, password: password)
		print("Signed in as \(client.displayName) <\(client.email)>")
		for c in client.contacts.values.sorted(by: { $0.email < $1.email }) {
			print(String(format: "  %-30@ %-14@ lists=%d", c.email, c.status.displayName, c.lists.rawValue))
		}
		print("Listening; Ctrl-C to quit.")
		while true { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
	}

	/// Signs in, sends `text` (and optionally a nudge) to `peer`, stays online
	/// for `linger` seconds printing replies, then signs out.
	func say(_ email: String, _ password: String, to peer: String, _ text: String, nudge: Bool, linger: Double,
	         picture: URL? = nil, invite: String? = nil) async throws {
		let client = makeClient("me")
		client.onEvent = { event in
			if case let .conversation(_, .message(_, name, reply, _)) = event { print("\(name) says: \(reply)") }
			if case let .conversation(_, .deliveryFailed(_, reason)) = event { print("not delivered: \(reason)") }
		}
		if let picture { await client.setDisplayPicture(try Data(contentsOf: picture)) }
		try await client.signIn(email: email, password: password)
		try await Task.sleep(nanoseconds: 1_500_000_000)
		client.sendTyping(to: peer)
		try await Task.sleep(nanoseconds: 1_500_000_000)
		await client.sendMessage(to: peer, text: text)
		if nudge {
			try await Task.sleep(nanoseconds: 1_000_000_000)
			try await client.sendNudge(to: peer)
		}
		if let invite {
			try await Task.sleep(nanoseconds: 1_000_000_000)
			try await client.invite(invite, into: peer)
			try await Task.sleep(nanoseconds: 1_500_000_000)
			await client.sendMessage(to: peer, text: "Welcome to the group, \(invite)! (^)")
		}
		try await Task.sleep(nanoseconds: UInt64(linger * 1_000_000_000))
		client.signOut()
	}

	/// Signs in two accounts and walks through the WLM feature set, checking
	/// each step arrives on the other side.
	func e2e(_ emailA: String, _ emailB: String, _ password: String, _ emailC: String? = nil) async throws {
		let a = makeClient("A"), b = makeClient("B")
		var inbox: [String] = []
		var addedPrompts: [String] = []
		var statusSeen: [String: Presence] = [:]
		var transfers: [String: FileTransfer] = [:]
		var winks: [String: Data] = [:]
		func listen(_ client: MessengerClient, _ tag: String) {
			client.onEvent = { event in
				switch event {
				case let .conversation(_, .file(t)):
					transfers["\(tag):\(t.id)"] = t
				case let .conversation(_, .wink(_, _, thumbnail)):
					winks[tag] = thumbnail ?? Data()
				case let .conversation(peer, kind):
					inbox.append("\(tag)<-\(peer): \(kind)")
				case let .addedBy(email, _):
					addedPrompts.append("\(tag):\(email)")
				case let .contactUpdated(c, _):
					statusSeen["\(tag):\(c.email)"] = c.status
				default:
					break
				}
			}
		}
		listen(a, "A")
		listen(b, "B")
		func randomData(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }
		let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("msnctl-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: scratch) }

		func step(_ name: String, _ body: () async throws -> Void) async throws {
			do {
				try await body()
				print("PASS  \(name)")
			} catch {
				print("FAIL  \(name): \(error.localizedDescription)")
				for line in inbox.suffix(6) { print("      recent: \(line.prefix(300))") }
				throw error
			}
		}
		func waitFor(_ what: String, timeout: Double = 10, _ cond: () -> Bool) async throws {
			let deadline = Date().addingTimeInterval(timeout)
			while !cond() {
				if Date() > deadline { throw MSNPError.timeout(what) }
				try await Task.sleep(nanoseconds: 100_000_000)
			}
		}

		try await step("bad password is rejected") {
			do {
				try await makeClient("X").signIn(email: emailA, password: password + "-wrong")
				throw MSNPError.unexpected("sign-in succeeded")
			} catch is PassportError {}
		}
		try await step("A signs in (RST → USR SSO → ABFindAll → ADL → CHG)") {
			try await a.signIn(email: emailA, password: password)
		}
		try await step("B signs in as Busy") {
			try await b.signIn(email: emailB, password: password, status: .busy)
		}
		try await step("A sets display name and personal message") {
			try await a.setDisplayName("Alice ☕ on macOS")
			try await a.setPersonalMessage("Ported with rea + Ghidra")
		}
		if a.contacts[emailB]?.isForward == true {
			try await step("reset: A removes B") { try await a.removeContact(emailB) }
		}
		if b.contacts[emailA]?.isForward == true {
			try await step("reset: B removes A") { try await b.removeContact(emailA) }
		}
		try await step("A adds B (ABContactAdd + AddMember + ADL)") {
			try await a.addContact(emailB)
		}
		try await step("B is told A added them") {
			// Deleting a contact leaves them on the Allow list (as in WLM), so on
			// re-runs B has already approved A and no prompt is due.
			try await waitFor("B's add prompt") {
				addedPrompts.contains("B:\(emailA)") || b.contacts[emailA]?.lists.contains(.allow) == true
			}
		}
		try await step("B accepts and adds A back") {
			try await b.respondToAdd(emailA, allow: true, addToList: true)
		}
		try await step("A sees B as Busy (NLN)") {
			try await waitFor("B presence") { a.contacts[emailB]?.status == .busy }
		}
		try await step("B goes Online and A sees it") {
			try await b.setStatus(.online)
			try await waitFor("B online") { a.contacts[emailB]?.status == .online }
		}
		try await step("B sees A's name and personal message (NLN/UBX)") {
			try await waitFor("A profile") {
				b.contacts[emailA]?.displayName == "Alice ☕ on macOS"
					&& b.contacts[emailA]?.personalMessage == "Ported with rea + Ghidra"
			}
		}
		try await step("A → B instant message (XFR SB → USR → CAL → JOI → MSG)") {
			await a.sendMessage(to: emailB, text: "Hello from MessengerMac! 😀 <&>")
			try await waitFor("B receives message") { inbox.contains { $0.hasPrefix("B<-\(emailA)") && $0.contains("Hello from MessengerMac! 😀 <&>") } }
		}
		try await step("B → A reply over the answered switchboard (RNG → ANS)") {
			await b.sendMessage(to: emailA, text: "Hi Alice, it works")
			try await waitFor("A receives reply") { inbox.contains { $0.hasPrefix("A<-\(emailB)") && $0.contains("Hi Alice, it works") } }
		}
		try await step("typing notification") {
			b.sendTyping(to: emailA)
			try await waitFor("A sees typing") { inbox.contains { $0.hasPrefix("A<-\(emailB)") && $0.contains("typing") } }
		}
		try await step("nudge") {
			try await a.sendNudge(to: emailB)
			try await waitFor("B gets nudge") { inbox.contains { $0.hasPrefix("B<-\(emailA)") && $0.contains("nudge") } }
		}
		if let emailC {
			let c = makeClient("C")
			listen(c, "C")
			try await step("C signs in") {
				try await c.signIn(email: emailC, password: password)
			}
			try await step("group conversation: A invites C into the conversation with B (CAL)") {
				try await a.invite(emailC, into: emailB)
				try await waitFor("B sees C join") { inbox.contains { $0.hasPrefix("B<-\(emailA)") && $0.contains("joined(email: \"\(emailC)\"") } }
				try await waitFor("C is in with A and B") { Set(c.participants(inConversationWith: emailA)) == [emailA, emailB] }
			}
			try await step("group conversation: everyone gets everyone's messages") {
				await a.sendMessage(to: emailB, text: "Hi both, from A")
				await c.sendMessage(to: emailA, text: "Hello group, from C")
				try await waitFor("B and C get A's message") {
					inbox.contains { $0.hasPrefix("B<-") && $0.contains("Hi both, from A") }
						&& inbox.contains { $0.hasPrefix("C<-") && $0.contains("Hi both, from A") }
				}
				try await waitFor("A and B get C's message") {
					inbox.contains { $0.hasPrefix("A<-") && $0.contains("Hello group, from C") }
						&& inbox.contains { $0.hasPrefix("B<-") && $0.contains("Hello group, from C") }
				}
			}
			try await step("group conversation: C leaves and the others see it (BYE)") {
				c.signOut()
				try await waitFor("A sees C leave") { inbox.contains { $0.hasPrefix("A<-") && $0.contains("left(email: \"\(emailC)\")") } }
				guard a.participants(inConversationWith: emailB) == [emailB] else { throw MSNPError.unexpected("C still listed") }
			}
		}
		try await step("display picture: B fetches A's over P2P (msnobj in CHG → INVITE → data)") {
			let picture = randomData(7000)
			await a.setDisplayPicture(picture)
			// Escargot passes a new msnobj on only with a status change (core/backend.py me_update).
			try await a.setStatus(.away)
			try await waitFor("B sees A's msnobj") { b.contacts[emailA]?.displayPicture?.size == picture.count }
			try await a.setStatus(.online)
			b.requestDisplayPicture(of: emailA)
			try await waitFor("the picture arrives", timeout: 30) { b.displayPicture(of: emailA) == picture }
		}
		try await step("file transfer: A sends B a 300 KB file (INVITE → 200 OK → data → BYE)") {
			let payload = randomData(300_000)
			let source = scratch.appendingPathComponent("Vakantie ☀️.bin")
			try payload.write(to: source)
			let sent = try a.sendFile(source, to: emailB)
			try await waitFor("B is offered it") { transfers["B:\(sent.id)"]?.state == .offered }
			guard transfers["B:\(sent.id)"]?.name == "Vakantie ☀️.bin", transfers["B:\(sent.id)"]?.size == 300_000 else {
				throw MSNPError.unexpected("offer: \(String(describing: transfers["B:\(sent.id)"]))")
			}
			let target = scratch.appendingPathComponent("received.bin")
			b.acceptFile(sent.id, saveTo: target)
			try await waitFor("both sides complete", timeout: 90) {
				transfers["A:\(sent.id)"]?.state == .completed && transfers["B:\(sent.id)"]?.state == .completed
			}
			guard try Data(contentsOf: target) == payload else { throw MSNPError.unexpected("received file differs") }
		}
		try await step("file transfer: B declines one (603 Decline)") {
			let source = scratch.appendingPathComponent("unwanted.txt")
			try Data("no thanks".utf8).write(to: source)
			let sent = try a.sendFile(source, to: emailB)
			try await waitFor("B is offered it") { transfers["B:\(sent.id)"]?.state == .offered }
			b.declineFile(sent.id)
			try await waitFor("A sees the decline") { transfers["A:\(sent.id)"]?.state == .declined }
		}
		try await step("wink: B gets its preview (datacast ID 2 → msnobj → MSZIP cabinet)") {
			let preview = randomData(3000)
			try await a.sendWink(Wink.make(name: "Wave", thumbnail: preview, animation: randomData(20_000)), to: emailB)
			try await waitFor("B gets the wink", timeout: 30) { winks["B"] == preview }
		}
		try await step("B signs out and A sees Offline (FLN)") {
			b.signOut()
			try await waitFor("B offline") { a.contacts[emailB]?.status == .offline }
		}
		try await step("offline message: A writes to offline B (OIM Store2, lock key challenge)") {
			await a.sendMessage(to: emailB, text: "Are you there? Ping me when you're back (Y)")
			try await waitFor("stored") { inbox.contains { $0.hasPrefix("A<-\(emailB)") && $0.contains("storedOffline") } }
		}
		try await step("B signs in and gets it (Mail-Data → RSI GetMessage → DeleteMessages)") {
			let b2 = makeClient("B2")
			listen(b2, "B2")
			try await b2.signIn(email: emailB, password: password)
			try await waitFor("offline message arrives", timeout: 15) {
				inbox.contains { $0.hasPrefix("B2<-\(emailA)") && $0.contains("offlineMessage") && $0.contains("Ping me when you") && $0.contains("back (Y)") }
			}
			b2.signOut()
			let b3 = makeClient("B3")
			listen(b3, "B3")
			try await b3.signIn(email: emailB, password: password)
			try await Task.sleep(nanoseconds: 3_000_000_000)
			guard !inbox.contains(where: { $0.hasPrefix("B3<-") && $0.contains("offlineMessage") }) else {
				throw MSNPError.unexpected("the offline message wasn't deleted")
			}
			b3.signOut()
			try await waitFor("B offline again") { a.contacts[emailB]?.status == .offline }
		}
		try await step("A blocks and unblocks B (Sharing service)") {
			try await a.block(emailB)
			guard a.contacts[emailB]?.isBlocked == true else { throw MSNPError.unexpected("not blocked") }
			try await a.unblock(emailB)
			guard a.contacts[emailB]?.isBlocked == false else { throw MSNPError.unexpected("still blocked") }
		}
		try await step("contact list survives a fresh sign-in") {
			a.signOut()
			let a2 = makeClient("A2")
			try await a2.signIn(email: emailA, password: password)
			guard a2.contacts[emailB]?.isForward == true else { throw MSNPError.unexpected("B missing from A's list") }
			guard a2.displayName == "Alice ☕ on macOS" else { throw MSNPError.unexpected("name not roamed: \(a2.displayName)") }
			guard a2.personalMessage == "Ported with rea + Ghidra" else { throw MSNPError.unexpected("PSM not roamed: \(a2.personalMessage)") }
			a2.signOut()
		}
		print("All steps passed.")
	}
}

/// "-" means: read the password from $MSN_PASSWORD (keeps it out of argv).
func password(_ arg: String) -> String {
	arg == "-" ? (ProcessInfo.processInfo.environment["MSN_PASSWORD"] ?? "") : arg
}

@MainActor
func run() async {
	var cli = CLI()
	var args = Array(CommandLine.arguments.dropFirst())
	while let first = args.first, first.hasPrefix("-") {
		args.removeFirst()
		switch first {
		case "--local": cli.config = .localDev
		case "--escargot": cli.config = .escargot
		case "--host":
			// A dev server elsewhere, e.g. this Mac as seen from a VM: NS on 1863, HTTP on 8081.
			let h = args.removeFirst()
			let base = URL(string: "http://\(h):8081")!
			cli.config = ServerConfig(nsHost: h, loginBaseURL: base, contactsBaseURL: base)
		case "-v": cli.verbose = true
		case "--echo": cli.echo = true
		default: break
		}
	}
	do {
		switch args.first {
		case "check" where args.count >= 3:
			try await cli.check(args[1], password(args[2]), seconds: Double(args.count > 3 ? args[3] : "4") ?? 4)
		case "login" where args.count == 3:
			try await cli.login(args[1], password(args[2]))
		case "say" where args.count >= 5:
			// --picture FILE: a display picture; --invite EMAIL: make it a group conversation.
			var rest = args.filter { $0 != "--nudge" }
			func option(_ name: String) -> String? {
				guard let i = rest.firstIndex(of: name), i + 1 < rest.count else { return nil }
				defer { rest.removeSubrange(i...i + 1) }
				return rest[i + 1]
			}
			let picture = option("--picture").map { URL(fileURLWithPath: $0) }
			let invite = option("--invite")
			try await cli.say(rest[1], rest[2], to: rest[3], rest[4], nudge: args.contains("--nudge"),
			                  linger: Double(rest.count > 5 ? rest[5] : "5") ?? 5, picture: picture, invite: invite)
		case "sendfile" where args.count >= 5:
			// sendfile EMAIL PASSWORD TO FILE [SECONDS]: offers a file and reports what happens to it.
			let client = cli.makeClient("file")
			var last: FileTransfer.State?
			client.onEvent = { event in
				if case let .conversation(_, .file(t)) = event, t.state != last {
					last = t.state
					print("transfer \(t.name): \(t.state)")
				}
			}
			try await client.signIn(email: args[1], password: password(args[2]))
			try client.sendFile(URL(fileURLWithPath: args[4]), to: args[3].lowercased())
			let deadline = Date().addingTimeInterval(args.count > 5 ? Double(args[5]) ?? 60 : 60)
			while Date() < deadline, !(last?.isFinished ?? false) { try await Task.sleep(nanoseconds: 200_000_000) }
			client.signOut()
		case "wink" where args.count >= 5:
			// wink EMAIL PASSWORD TO PREVIEW.png [SECONDS]: sends a wink whose cabinet carries the image.
			let client = cli.makeClient("wink")
			try await client.signIn(email: args[1], password: password(args[2]))
			let preview = try Data(contentsOf: URL(fileURLWithPath: args[4]))
			try await client.sendWink(Wink.make(name: "Wave", thumbnail: preview), to: args[3].lowercased())
			print("wink sent to \(args[3])")
			try await Task.sleep(nanoseconds: UInt64((args.count > 5 ? Double(args[5]) ?? 20 : 20) * 1_000_000_000))
			client.signOut()
		case "e2e" where args.count == 4 || args.count == 5:
			try await cli.e2e(args[1], args[2], args[3], args.count == 5 ? args[4] : nil)
		default:
			print("usage: msnctl [--local|--escargot] [-v] check EMAIL PASSWORD [SECONDS] | login EMAIL PASSWORD [--echo] | say EMAIL PASSWORD TO TEXT [SECONDS] [--nudge] | e2e EMAIL_A EMAIL_B PASSWORD [EMAIL_C]")
			exit(2)
		}
		exit(0)
	} catch {
		print("error: \(error.localizedDescription)")
		exit(1)
	}
}

Task { await run() }
RunLoop.main.run()
