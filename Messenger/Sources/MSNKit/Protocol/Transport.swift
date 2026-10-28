import Foundation
#if canImport(Network)
import Network
#endif
#if canImport(Glibc)
import Glibc
#endif

/// A connected TCP byte stream delivering on the main actor.
@MainActor
protocol ByteTransport: AnyObject {
	var onData: ((Data) -> Void)? { get set }
	var onClose: ((Error?) -> Void)? { get set }
	/// Connects to a numeric address (resolution happens in MSNPConnection).
	func connect(address: String, port: UInt16, timeout: TimeInterval) async throws
	func send(_ data: Data)
	/// Sends `data`, then closes once it is written.
	func sendAndClose(_ data: Data)
	func cancel()
}

@MainActor
func makeTransport() -> ByteTransport {
	#if canImport(Network)
	return NWTransport()
	#else
	return SocketTransport()
	#endif
}

#if canImport(Network)
/// Network.framework transport (macOS).
@MainActor
final class NWTransport: ByteTransport {
	var onData: ((Data) -> Void)?
	var onClose: ((Error?) -> Void)?
	private var conn: NWConnection?
	private var closed = false

	func connect(address: String, port: UInt16, timeout: TimeInterval) async throws {
		let tcp = NWProtocolTCP.Options()
		tcp.enableKeepalive = true
		tcp.connectionTimeout = Int(timeout)
		let conn = NWConnection(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port) ?? 1863,
		                        using: NWParameters(tls: nil, tcp: tcp))
		try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
			var resumed = false
			func finish(_ result: Result<Void, Error>) {
				guard !resumed else { return }
				resumed = true
				cont.resume(with: result)
			}
			conn.stateUpdateHandler = { [weak self] state in
				MainActor.assumeIsolated {
					guard let self else { return }
					switch state {
					case .ready:
						if !resumed {
							self.conn = conn
							self.receive()
						}
						finish(.success(()))
					case let .failed(error), let .waiting(error):
						if resumed, self.conn === conn {
							self.finishClose(error)
						} else {
							conn.cancel()
							finish(.failure(MSNPError.connectFailed("\(address): \(error.localizedDescription)")))
						}
					case .cancelled:
						if resumed, self.conn === conn { self.finishClose(nil) }
						finish(.failure(MSNPError.disconnected))
					default:
						break
					}
				}
			}
			conn.start(queue: .main)
			Task {
				try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000) + 2_000_000_000)
				if !resumed {
					conn.cancel()
					finish(.failure(MSNPError.timeout("connection to \(address)")))
				}
			}
		}
	}

	func send(_ data: Data) {
		conn?.send(content: data, completion: .contentProcessed { [weak self] error in
			MainActor.assumeIsolated {
				if let error { self?.finishClose(error) }
			}
		})
	}

	func sendAndClose(_ data: Data) {
		guard let conn else { return }
		closed = true
		conn.stateUpdateHandler = nil
		conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
	}

	func cancel() {
		closed = true
		conn?.stateUpdateHandler = nil
		conn?.cancel()
	}

	private func receive() {
		conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
			MainActor.assumeIsolated {
				guard let self, !self.closed else { return }
				if let data, !data.isEmpty { self.onData?(data) }
				if isComplete || error != nil {
					self.finishClose(error)
				} else {
					self.receive()
				}
			}
		}
	}

	private func finishClose(_ error: Error?) {
		guard !closed else { return }
		closed = true
		conn?.stateUpdateHandler = nil
		conn?.cancel()
		onClose?(error)
	}
}
#endif

/// POSIX socket transport with a Dispatch read source on the main queue.
/// Used on Linux; portable to macOS (tests can force it there).
@MainActor
final class SocketTransport: ByteTransport {
	var onData: ((Data) -> Void)?
	var onClose: ((Error?) -> Void)?
	private var fd: Int32 = -1
	private var source: DispatchSourceRead?
	private var closed = false

	func connect(address: String, port: UInt16, timeout: TimeInterval) async throws {
		let fd = try await Task.detached { () throws -> Int32 in
			var hints = addrinfo()
			hints.ai_flags = AI_NUMERICHOST
			#if canImport(Glibc)
			hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
			#else
			hints.ai_socktype = SOCK_STREAM
			#endif
			var res: UnsafeMutablePointer<addrinfo>?
			guard getaddrinfo(address, String(port), &hints, &res) == 0, let ai = res else {
				throw MSNPError.connectFailed("bad address \(address)")
			}
			defer { freeaddrinfo(res) }
			let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
			guard fd >= 0 else { throw MSNPError.connectFailed("socket: \(String(cString: strerror(errno)))") }
			var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
			setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
			var on: Int32 = 1
			setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, socklen_t(MemoryLayout<Int32>.size))
			guard Glue.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 else {
				let why = String(cString: strerror(errno))
				_ = Glue.close(fd)
				throw MSNPError.connectFailed("\(address): \(why)")
			}
			return fd
		}.value
		self.fd = fd
		let flags = fcntl(fd, F_GETFL)
		_ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
		let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
		src.setEventHandler { [weak self] in
			MainActor.assumeIsolated { self?.readAvailable() }
		}
		source = src
		src.resume()
	}

	private func readAvailable() {
		var buf = [UInt8](repeating: 0, count: 65536)
		while !closed {
			let n = Glue.read(fd, &buf, buf.count)
			if n > 0 {
				onData?(Data(buf[0..<n]))
			} else if n == 0 {
				finishClose(nil)
				return
			} else {
				if errno == EAGAIN || errno == EWOULDBLOCK { return }
				finishClose(MSNPError.connectFailed(String(cString: strerror(errno))))
				return
			}
		}
	}

	func send(_ data: Data) {
		guard fd >= 0, !closed else { return }
		var offset = 0
		let bytes = [UInt8](data)
		while offset < bytes.count {
			let n = bytes[offset...].withUnsafeBytes { Glue.write(fd, $0.baseAddress, $0.count) }
			if n > 0 {
				offset += n
			} else if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
				var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
				_ = poll(&p, 1, 5000)
			} else {
				finishClose(MSNPError.disconnected)
				return
			}
		}
	}

	func sendAndClose(_ data: Data) {
		send(data)
		cancel()
	}

	func cancel() {
		guard !closed else { return }
		closed = true
		source?.cancel()
		if fd >= 0 { _ = Glue.close(fd) }
		fd = -1
	}

	private func finishClose(_ error: Error?) {
		guard !closed else { return }
		cancel()
		onClose?(error)
	}
}

/// libc calls whose names collide with methods in scope.
private enum Glue {
	#if canImport(Glibc)
	static func connect(_ fd: Int32, _ a: UnsafePointer<sockaddr>!, _ l: socklen_t) -> Int32 { Glibc.connect(fd, a, l) }
	static func read(_ fd: Int32, _ b: UnsafeMutableRawPointer, _ n: Int) -> Int { Glibc.read(fd, b, n) }
	static func write(_ fd: Int32, _ b: UnsafeRawPointer?, _ n: Int) -> Int { Glibc.write(fd, b, n) }
	static func close(_ fd: Int32) -> Int32 { Glibc.close(fd) }
	#else
	static func connect(_ fd: Int32, _ a: UnsafePointer<sockaddr>!, _ l: socklen_t) -> Int32 { Darwin.connect(fd, a, l) }
	static func read(_ fd: Int32, _ b: UnsafeMutableRawPointer, _ n: Int) -> Int { Darwin.read(fd, b, n) }
	static func write(_ fd: Int32, _ b: UnsafeRawPointer?, _ n: Int) -> Int { Darwin.write(fd, b, n) }
	static func close(_ fd: Int32) -> Int32 { Darwin.close(fd) }
	#endif
}
