import Foundation

/// One switchboard (chat) connection.
///
/// Outgoing: NS `XFR trid SB` → `USR trid email cki` → `CAL trid contact` → `JOI`.
/// Incoming: NS `RNG sessid host:port CKI cki inviter ...` → `ANS trid email cki sessid` → `IRO`… `ANS OK`.
@MainActor
public final class SwitchboardSession {
	public enum Event {
		case joined(email: String, displayName: String)
		case left(email: String)
		case message(from: String, displayName: String, MIMEMessage)
		case closed
	}

	public let myEmail: String
	public private(set) var participants: [String: String] = [:]  // email → friendly name
	/// Events that arrive before a handler is attached (e.g. the first MSG of an
	/// answered invite, which can come in the same read as `ANS OK`) are queued
	/// and delivered when it is set.
	public var onEvent: ((Event) -> Void)? {
		didSet {
			guard let onEvent else { return }
			let queued = backlog
			backlog.removeAll()
			queued.forEach(onEvent)
		}
	}
	private var backlog: [Event] = []

	private func emit(_ event: Event) {
		if let onEvent { onEvent(event) } else { backlog.append(event) }
	}
	public var log: ((String) -> Void)? {
		didSet { connection.log = log.map { l in { l("[SB] " + $0) } } }
	}

	private let connection: MSNPConnection
	private var joinWaiters: [String: [CheckedContinuation<Void, Error>]] = [:]
	private var chunks: [String: (total: Int, parts: [Int: Data], headers: MIMEMessage)] = [:]
	public private(set) var isClosed = false

	private init(host: String, port: UInt16, myEmail: String) {
		self.myEmail = myEmail
		connection = MSNPConnection(host: host, port: port)
		connection.onCommand = { [weak self] in self?.handle($0) }
		connection.onClose = { [weak self] _ in self?.didClose() }
	}

	nonisolated static func parseHostPort(_ s: String) -> (String, UInt16) {
		let parts = s.split(separator: ":")
		return (String(parts[0]), parts.count > 1 ? UInt16(parts[1]) ?? 1863 : 1863)
	}

	/// Opens a new switchboard after an `XFR ... SB` reply.
	public static func open(address: String, cookie: String, myEmail: String, log: ((String) -> Void)? = nil) async throws -> SwitchboardSession {
		let (host, port) = parseHostPort(address)
		let sb = SwitchboardSession(host: host, port: port, myEmail: myEmail)
		sb.log = log
		try await sb.connection.connect()
		_ = try await sb.connection.request("USR", [myEmail, cookie])
		return sb
	}

	/// Joins a switchboard we were invited to via `RNG`.
	public static func answer(address: String, cookie: String, sessionID: String, myEmail: String, log: ((String) -> Void)? = nil) async throws -> SwitchboardSession {
		let (host, port) = parseHostPort(address)
		let sb = SwitchboardSession(host: host, port: port, myEmail: myEmail)
		sb.log = log
		try await sb.connection.connect()
		_ = try await sb.connection.request("ANS", [myEmail, cookie, sessionID])
		return sb
	}

	/// Invites `email` and waits for their `JOI`.
	public func invite(_ email: String, timeout: TimeInterval = 20) async throws {
		let email = email.lowercased()
		if participants[email] != nil { return }
		_ = try await connection.request("CAL", [email])
		if participants[email] != nil { return }
		try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
			joinWaiters[email, default: []].append(cont)
			Task { [weak self] in
				try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
				guard let self, var waiters = self.joinWaiters[email], !waiters.isEmpty else { return }
				let c = waiters.removeFirst()
				self.joinWaiters[email] = waiters
				c.resume(throwing: MSNPError.timeout("\(email) to join the conversation"))
			}
		}
	}

	public func send(_ message: MIMEMessage, ack: String = "N") {
		connection.send("MSG", [ack], payload: message.encoded())
	}

	public func close() {
		connection.close()
	}

	private func handle(_ cmd: MSNPCommand) {
		switch cmd.name {
		case "IRO":
			// IRO trid index total email friendlyname [caps]
			if cmd.args.count >= 5 { addParticipant(cmd.args[3], cmd.args[4].msnpURLDecoded) }
		case "JOI":
			// JOI email friendlyname [caps]
			if cmd.args.count >= 2 { addParticipant(cmd.args[0], cmd.args[1].msnpURLDecoded) }
		case "BYE":
			guard let email = cmd.args.first?.lowercased() else { return }
			participants[email] = nil
			emit(.left(email: email))
			if participants.isEmpty { close() }
		case "MSG":
			// MSG email friendlyname length
			guard cmd.args.count >= 2, let payload = cmd.payload else { return }
			let from = cmd.args[0].lowercased()
			let name = cmd.args[1].msnpURLDecoded
			if let message = reassemble(MIMEMessage(parsing: payload)) {
				emit(.message(from: from, displayName: name, message))
			}
		default:
			break
		}
	}

	/// Multi-packet messages (capability 0x20): `Message-ID`, `Chunks` on the
	/// first part and `Chunk: n` on the rest.
	private func reassemble(_ m: MIMEMessage) -> MIMEMessage? {
		guard let id = m["Message-ID"] else { return m }
		if let total = m["Chunks"].flatMap(Int.init) {
			chunks[id] = (total, [0: m.body], m)
		} else if let n = m["Chunk"].flatMap(Int.init) {
			chunks[id]?.parts[n] = m.body
		}
		guard let entry = chunks[id], entry.parts.count == entry.total else { return nil }
		chunks[id] = nil
		var full = entry.headers
		full.body = (0..<entry.total).reduce(into: Data()) { $0 += entry.parts[$1] ?? Data() }
		return full
	}

	private func addParticipant(_ email: String, _ name: String) {
		let email = email.lowercased()
		guard email != myEmail.lowercased() else { return }
		participants[email] = name
		emit(.joined(email: email, displayName: name))
		for c in joinWaiters.removeValue(forKey: email) ?? [] { c.resume() }
	}

	private func didClose() {
		isClosed = true
		for (_, waiters) in joinWaiters { waiters.forEach { $0.resume(throwing: MSNPError.disconnected) } }
		joinWaiters.removeAll()
		emit(.closed)
	}
}
