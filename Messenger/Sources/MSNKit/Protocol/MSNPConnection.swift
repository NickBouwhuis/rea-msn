import Foundation
#if canImport(Glibc)
import Glibc
#endif

public enum MSNPError: Error, LocalizedError, Equatable {
	case server(code: Int, command: String)
	case disconnected
	case connectFailed(String)
	case timeout(String)
	case unexpected(String)

	public var errorDescription: String? {
		switch self {
		case let .server(code, command): return "Server returned error \(code) for \(command) (\(MSNPError.describe(code)))"
		case .disconnected: return "The connection to the server was lost."
		case let .connectFailed(why): return "Could not connect to the server: \(why)"
		case let .timeout(what): return "Timed out waiting for \(what)."
		case let .unexpected(what): return "Unexpected server response: \(what)"
		}
	}

	static func describe(_ code: Int) -> String {
		switch code {
		case 201: return "invalid parameter"
		case 205: return "invalid principal"
		case 208: return "invalid principal"
		case 209: return "nickname change illegal"
		case 210: return "list full"
		case 215: return "already in list"
		case 216: return "not in list"
		case 217: return "user not online"
		case 241: return "invalid membership"
		case 280: return "switchboard failed"
		case 500, 601: return "internal server error"
		case 715: return "unexpected command"
		case 800: return "changing too rapidly"
		case 911: return "authentication failed"
		case 913: return "not allowed while offline"
		case 921, 922: return "server too busy"
		case 931: return "account suspended"
		default: return "unknown error"
		}
	}
}

/// A single MSNP TCP connection (NS or SB) with TrID bookkeeping.
///
/// Main-actor isolated: the transport delivers on the main queue, so all state
/// (decoder, TrID table) is touched from one executor without locks.
@MainActor
public final class MSNPConnection {
	public let host: String
	public let port: UInt16
	public var onCommand: ((MSNPCommand) -> Void)?
	public var onClose: ((Error?) -> Void)?
	public var log: ((String) -> Void)?

	private var transport: ByteTransport?
	/// Forces the POSIX transport (the Linux one) on macOS too, for tests.
	public static var forcePOSIXTransport = ProcessInfo.processInfo.environment["MSNKIT_POSIX_TRANSPORT"] != nil
	private var decoder = MSNPDecoder()
	private var nextTrID = 1
	private var pending: [Int: (name: String, continuation: CheckedContinuation<MSNPCommand, Error>)] = [:]
	private var closed = false

	/// Replies that share the request's TrID but are informational, not the answer.
	private static let intermediateReplies: Set<String> = ["ILN", "IRO", "GCF"]

	public init(host: String, port: UInt16) {
		self.host = host
		self.port = port
	}

	/// Resolves with getaddrinfo and tries each address in turn. Network.framework's
	/// own resolver can stall in `.preparing` behind some VPN/split-DNS setups,
	/// while the libc resolver (used by curl/nc) keeps working.
	public func connect() async throws {
		let addresses = try await Self.resolve(host, port: port)
		var lastError: Error = MSNPError.connectFailed("no addresses for \(host)")
		for address in addresses {
			guard !closed else { throw MSNPError.disconnected }
			let t: ByteTransport = Self.forcePOSIXTransport ? SocketTransport() : makeTransport()
			t.onData = { [weak self] in self?.received($0) }
			t.onClose = { [weak self] in self?.shutdown($0) }
			do {
				log?("--- \(host) [\(address)]:\(port) connecting")
				try await t.connect(address: address, port: port, timeout: 10)
				transport = t
				log?("--- \(host) [\(address)]:\(port) ready")
				return
			} catch {
				t.cancel()
				lastError = error
			}
		}
		throw lastError
	}

	nonisolated static func resolve(_ host: String, port: UInt16) async throws -> [String] {
		try await Task.detached {
			var hints = addrinfo()
			hints.ai_flags = AI_ADDRCONFIG
			hints.ai_family = AF_UNSPEC
			#if canImport(Glibc)
			hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
			hints.ai_protocol = Int32(IPPROTO_TCP)
			#else
			hints.ai_socktype = SOCK_STREAM
			hints.ai_protocol = IPPROTO_TCP
			#endif
			var result: UnsafeMutablePointer<addrinfo>?
			let rc = getaddrinfo(host, String(port), &hints, &result)
			guard rc == 0, let first = result else {
				throw MSNPError.connectFailed("cannot resolve \(host): \(String(cString: gai_strerror(rc)))")
			}
			defer { freeaddrinfo(first) }
			var v4: [String] = [], v6: [String] = []
			var cursor: UnsafeMutablePointer<addrinfo>? = first
			while let ai = cursor {
				var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
				if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
					let s = String(cString: buf)
					if ai.pointee.ai_family == AF_INET6 { v6.append(s) } else { v4.append(s) }
				}
				cursor = ai.pointee.ai_next
			}
			// IPv4 first: MSN-era servers are reliably reachable over v4.
			var seen = Set<String>()
			return (v4 + v6).filter { seen.insert($0).inserted }
		}.value
	}

	public func close() {
		guard !closed else { return }
		if let transport {
			transport.sendAndClose(MSNPCommand("OUT").encoded())
			closed = true
			failPending()
			onClose?(nil)
		} else {
			shutdown(nil)
		}
	}

	/// Sends a command, assigning the next TrID. Returns the TrID used.
	@discardableResult
	public func send(_ name: String, _ args: [String] = [], payload: Data? = nil) -> Int {
		let trID = nextTrID
		nextTrID += 1
		write(MSNPCommand(name, [String(trID)] + args, payload: payload))
		return trID
	}

	/// Sends a command without a TrID (e.g. `PNG`).
	public func sendRaw(_ command: MSNPCommand) {
		write(command)
	}

	/// Sends a command and waits for the reply carrying the same TrID.
	/// Numeric error replies are thrown as `MSNPError.server`.
	public func request(_ name: String, _ args: [String] = [], payload: Data? = nil, timeout: TimeInterval = 30) async throws -> MSNPCommand {
		guard !closed else { throw MSNPError.disconnected }
		let trID = nextTrID
		nextTrID += 1
		return try await withCheckedThrowingContinuation { cont in
			pending[trID] = (name, cont)
			write(MSNPCommand(name, [String(trID)] + args, payload: payload))
			Task { [weak self] in
				try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
				guard let self, let entry = self.pending.removeValue(forKey: trID) else { return }
				entry.continuation.resume(throwing: MSNPError.timeout("\(name) reply"))
			}
		}
	}

	private func write(_ command: MSNPCommand) {
		guard !closed else { return }
		log?(">>> \(command)")
		transport?.send(command.encoded())
	}

	private func received(_ data: Data) {
		decoder.append(data)
		do {
			while let command = try decoder.next() {
				dispatch(command)
			}
		} catch {
			shutdown(error)
		}
	}

	private func dispatch(_ command: MSNPCommand) {
		log?("<<< \(command)")
		if let trID = command.trID, !MSNPConnection.intermediateReplies.contains(command.name),
		   let entry = pending.removeValue(forKey: trID) {
			if let code = command.errorCode {
				entry.continuation.resume(throwing: MSNPError.server(code: code, command: entry.name))
			} else {
				entry.continuation.resume(returning: command)
			}
			return
		}
		onCommand?(command)
	}

	private func shutdown(_ error: Error?) {
		guard !closed else { return }
		closed = true
		transport?.cancel()
		failPending()
		onClose?(error)
	}

	private func failPending() {
		let waiting = pending
		pending.removeAll()
		for (_, entry) in waiting {
			entry.continuation.resume(throwing: MSNPError.disconnected)
		}
	}
}
