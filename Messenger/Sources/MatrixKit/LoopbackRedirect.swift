import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// A one-shot HTTP listener on 127.0.0.1 that catches the browser coming back
/// from the homeserver's sign-in page (the loopback redirect desktop apps use,
/// RFC 8252 §7.3). Only `callbackURL`, whose path carries a random secret, is
/// answered, so another web page can't hand us a login token of its own.
final class LoopbackRedirect: @unchecked Sendable {
	let callbackURL: URL
	private let fd: Int32
	private let path: String
	private let lock = NSLock()
	private var closed = false

	init() throws {
		#if os(Linux)
		let sock = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
		#else
		let sock = socket(AF_INET, SOCK_STREAM, 0)
		#endif
		guard sock >= 0 else { throw MatrixError.badResponse("can't open a local port for the browser sign-in") }
		var addr = sockaddr_in()
		#if !os(Linux)
		addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		#endif
		addr.sin_family = sa_family_t(AF_INET)
		addr.sin_port = 0
		addr.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
		var len = socklen_t(MemoryLayout<sockaddr_in>.size)
		let ok = withUnsafeMutablePointer(to: &addr) { p in
			p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(sock, $0, len) == 0 && listen(sock, 4) == 0 && getsockname(sock, $0, &len) == 0
			}
		}
		guard ok else {
			_ = Self.close(sock)
			throw MatrixError.badResponse("can't open a local port for the browser sign-in")
		}
		fd = sock
		path = "/callback/" + UUID().uuidString.lowercased()
		callbackURL = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: addr.sin_port))\(path)")!
	}

	deinit { stop() }

	func stop() {
		lock.lock()
		defer { lock.unlock() }
		guard !closed else { return }
		closed = true
		_ = Self.close(fd)
	}

	private var isStopped: Bool {
		lock.lock()
		defer { lock.unlock() }
		return closed
	}

	/// Serves requests until the callback arrives with `name` in its query and
	/// returns that value; answers it with `page`. Throws CancellationError once
	/// stopped, and gives up after `timeout`.
	func wait(forQueryItem name: String, page: String, timeout: TimeInterval = 600) async throws -> String {
		try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
			Thread.detachNewThread { [self] in
				let deadline = Date().addingTimeInterval(timeout)
				while true {
					if isStopped { return cont.resume(throwing: CancellationError()) }
					if Date() > deadline { return cont.resume(throwing: MatrixError.badResponse("the browser sign-in timed out")) }
					var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
					guard poll(&pfd, 1, 250) > 0 else { continue }
					let client = accept(fd, nil, nil)
					guard client >= 0 else { continue }
					let value = queryItem(name, in: Self.readRequestLine(client))
					if let value {
						Self.respond(client, status: "200 OK", body: page)
						_ = Self.close(client)
						stop()
						return cont.resume(returning: value)
					}
					Self.respond(client, status: "404 Not Found", body: "Not found")
					_ = Self.close(client)
				}
			}
		}
	}

	/// "GET /callback/…?loginToken=x HTTP/1.1" → the value of `name`, for our path only.
	private func queryItem(_ name: String, in requestLine: String) -> String? {
		let parts = requestLine.split(separator: " ")
		guard parts.count >= 2, parts[0] == "GET",
		      let url = URLComponents(string: "http://127.0.0.1" + parts[1]), url.path == path else { return nil }
		return url.queryItems?.first { $0.name == name }?.value
	}

	private static func readRequestLine(_ fd: Int32) -> String {
		var data = Data()
		var buf = [UInt8](repeating: 0, count: 2048)
		while data.count < 16_384, !data.contains(0x0A) {
			let n = read(fd, &buf, buf.count)
			if n <= 0 { break }
			data.append(contentsOf: buf[0..<n])
		}
		return String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
	}

	private static func respond(_ fd: Int32, status: String, body: String) {
		let response = Data("HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
		response.withUnsafeBytes { raw in
			var offset = 0
			while offset < raw.count {
				let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
				if n <= 0 { break }
				offset += n
			}
		}
	}

	private static func close(_ fd: Int32) -> Int32 {
		#if os(Linux)
		Glibc.close(fd)
		#else
		Darwin.close(fd)
		#endif
	}
}
