import Foundation
import MSNKit

// msnctl — exercise MSNKit without the GUI.
//
//   msnctl [--local|--escargot|--host H] [-v] check EMAIL PASSWORD [SECONDS]   read-only sign-in summary
//   msnctl [--local|--escargot] [-v] [--echo] login EMAIL PASSWORD    sign in, print the list and IMs
//   PASSWORD "-" reads $MSN_PASSWORD
//   msnctl [--local] [-v] say EMAIL PASSWORD TO TEXT [SECONDS] [--nudge]
//   msnctl [--local] [-v] e2e EMAIL_A EMAIL_B PASSWORD      two-client end-to-end scenario

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
	func say(_ email: String, _ password: String, to peer: String, _ text: String, nudge: Bool, linger: Double) async throws {
		let client = makeClient("me")
		client.onEvent = { event in
			if case let .conversation(_, .message(_, name, reply, _)) = event { print("\(name) says: \(reply)") }
			if case let .conversation(_, .deliveryFailed(_, reason)) = event { print("not delivered: \(reason)") }
		}
		try await client.signIn(email: email, password: password)
		try await Task.sleep(nanoseconds: 1_500_000_000)
		client.sendTyping(to: peer)
		try await Task.sleep(nanoseconds: 1_500_000_000)
		await client.sendMessage(to: peer, text: text)
		if nudge {
			try await Task.sleep(nanoseconds: 1_000_000_000)
			try await client.sendNudge(to: peer)
		}
		try await Task.sleep(nanoseconds: UInt64(linger * 1_000_000_000))
		client.signOut()
	}

	/// Signs in two accounts and walks through the WLM feature set, checking
	/// each step arrives on the other side.
	func e2e(_ emailA: String, _ emailB: String, _ password: String) async throws {
		let a = makeClient("A"), b = makeClient("B")
		var inbox: [String] = []
		var addedPrompts: [String] = []
		var statusSeen: [String: Presence] = [:]
		for (client, tag) in [(a, "A"), (b, "B")] {
			client.onEvent = { event in
				switch event {
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

		func step(_ name: String, _ body: () async throws -> Void) async throws {
			do {
				try await body()
				print("PASS  \(name)")
			} catch {
				print("FAIL  \(name): \(error.localizedDescription)")
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
		try await step("B signs out and A sees Offline (FLN)") {
			b.signOut()
			try await waitFor("B offline") { a.contacts[emailB]?.status == .offline }
		}
		try await step("message to offline contact reports failure") {
			await a.sendMessage(to: emailB, text: "are you there?")
			try await waitFor("delivery failure") { inbox.contains { $0.hasPrefix("A<-\(emailB)") && $0.contains("deliveryFailed") } }
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
			let nudge = args.contains("--nudge")
			let rest = args.filter { $0 != "--nudge" }
			try await cli.say(rest[1], rest[2], to: rest[3], rest[4], nudge: nudge, linger: Double(rest.count > 5 ? rest[5] : "5") ?? 5)
		case "e2e" where args.count == 4:
			try await cli.e2e(args[1], args[2], args[3])
		default:
			print("usage: msnctl [--local|--escargot] [-v] check EMAIL PASSWORD [SECONDS] | login EMAIL PASSWORD [--echo] | say EMAIL PASSWORD TO TEXT [SECONDS] [--nudge] | e2e EMAIL_A EMAIL_B PASSWORD")
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
