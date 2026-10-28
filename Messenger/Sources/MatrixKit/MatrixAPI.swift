import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum MatrixError: Error, LocalizedError, Equatable {
	case badUserID(String)
	case noHomeserver(String)
	case passwordLoginUnsupported
	case authenticationFailed
	case encryptedRoom
	/// errcode/error from the homeserver, e.g. M_FORBIDDEN.
	case server(status: Int, code: String, message: String)
	case badResponse(String)

	public var errorDescription: String? {
		switch self {
		case let .badUserID(id): return "\"\(id)\" is not a Matrix ID. Matrix IDs look like @someone:matrix.org."
		case let .noHomeserver(name): return "Couldn't find the Matrix homeserver for \(name)."
		case .passwordLoginUnsupported:
			return "This homeserver only allows signing in through a web browser, which this version of Messenger doesn't support yet."
		case .authenticationFailed: return "The Matrix ID or password is incorrect."
		case .encryptedRoom:
			return "This conversation is end-to-end encrypted, which this version of Messenger doesn't support yet."
		case let .server(status, code, message): return "The homeserver returned \(code) (HTTP \(status)): \(message)"
		case let .badResponse(why): return "The homeserver sent an unexpected response (\(why))."
		}
	}
}

/// Matrix IDs: `@localpart:server.name`, where the server name may carry a port.
public enum MatrixID {
	public static func isUserID(_ s: String) -> Bool {
		serverName(of: s) != nil
	}

	public static func serverName(of userID: String) -> String? {
		guard userID.hasPrefix("@"), let colon = userID.firstIndex(of: ":") else { return nil }
		let local = userID[userID.index(after: userID.startIndex)..<colon]
		let server = userID[userID.index(after: colon)...]
		guard !local.isEmpty, !server.isEmpty, !userID.contains(where: \.isWhitespace) else { return nil }
		return String(server)
	}

	public static func localpart(of userID: String) -> String {
		guard userID.hasPrefix("@"), let colon = userID.firstIndex(of: ":") else { return userID }
		return String(userID[userID.index(after: userID.startIndex)..<colon])
	}
}

/// The client-server API over HTTPS (v3 endpoints).
public struct MatrixAPI: Sendable {
	public let baseURL: URL
	public var accessToken: String?
	public let session: URLSession

	public init(baseURL: URL, accessToken: String? = nil, session: URLSession = .shared) {
		self.baseURL = baseURL
		self.accessToken = accessToken
		self.session = session
	}

	/// `/.well-known/matrix/client` on the server name, else the server name itself.
	public static func discover(serverName: String, session: URLSession = .shared) async throws -> URL {
		var candidates: [URL] = []
		if let wellKnown = URL(string: "https://\(serverName)/.well-known/matrix/client") {
			var req = URLRequest(url: wellKnown)
			req.timeoutInterval = 10
			if let (data, response) = try? await session.data(for: req),
			   (response as? HTTPURLResponse)?.statusCode == 200,
			   let base = (try? JSON(data: data))?["m.homeserver"]["base_url"].string,
			   let url = URL(string: base.hasSuffix("/") ? String(base.dropLast()) : base) {
				candidates.append(url)
			}
		}
		if let direct = URL(string: "https://\(serverName)") { candidates.append(direct) }
		for base in candidates {
			let api = MatrixAPI(baseURL: base, session: session)
			if (try? await api.call("GET", "/_matrix/client/versions", timeout: 10))?["versions"].array.isEmpty == false {
				return base
			}
		}
		throw MatrixError.noHomeserver(serverName)
	}

	/// Percent-encodes a user ID, room ID or event type for use as one path segment.
	public static func segment(_ s: String) -> String {
		var allowed = CharacterSet.alphanumerics
		allowed.insert(charactersIn: "-._~")
		return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
	}

	/// `path` is either a full `/_matrix/...` path or one relative to `/_matrix/client/v3`.
	public func call(_ method: String, _ path: String, query: [String: String] = [:], body: JSON? = nil,
	                 timeout: TimeInterval = 30) async throws -> JSON {
		let full = path.hasPrefix("/_matrix/") ? path : "/_matrix/client/v3" + path
		guard var components = URLComponents(string: baseURL.absoluteString + full) else {
			throw MatrixError.badResponse("bad URL \(full)")
		}
		if !query.isEmpty {
			components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
			// URLComponents leaves "+" alone, which servers read as a space.
			components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
		}
		guard let url = components.url else { throw MatrixError.badResponse("bad URL \(full)") }
		var req = URLRequest(url: url)
		req.httpMethod = method
		req.timeoutInterval = timeout
		if let accessToken { req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
		if let body {
			req.setValue("application/json", forHTTPHeaderField: "Content-Type")
			req.httpBody = body.encoded()
		}
		for attempt in 1... {
			let (data, response) = try await session.data(for: req)
			let http = response as? HTTPURLResponse
			let status = http?.statusCode ?? 0
			let json = (try? JSON(data: data)) ?? .null
			if (200..<300).contains(status) { return json }
			// M_LIMIT_EXCEEDED: servers rate-limit presence (Synapse: one change per
			// 10 s) and messages; wait as told, a few times, rather than fail.
			if status == 429, attempt < 4 {
				let ms = json["retry_after_ms"].int ?? http?.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init).map { $0 * 1000 } ?? 1000
				try await Task.sleep(nanoseconds: UInt64(min(max(ms, 100), 20_000)) * 1_000_000)
				continue
			}
			throw MatrixError.server(status: status, code: json["errcode"].string ?? "HTTP \(status)",
			                         message: json["error"].string ?? String(decoding: data.prefix(200), as: UTF8.self))
		}
		fatalError("unreachable")
	}

	public struct Login: Sendable {
		public var userID: String
		public var accessToken: String
		public var deviceID: String
	}

	public func login(user: String, password: String, deviceID: String, deviceName: String) async throws -> Login {
		let flows = try await call("GET", "/login")["flows"].array.compactMap { $0["type"].string }
		guard flows.contains("m.login.password") else { throw MatrixError.passwordLoginUnsupported }
		let body: JSON = [
			"type": "m.login.password",
			"identifier": ["type": "m.id.user", "user": .string(user)],
			"password": .string(password),
			"device_id": .string(deviceID),
			"initial_device_display_name": .string(deviceName),
		]
		let reply: JSON
		do {
			reply = try await call("POST", "/login", body: body)
		} catch MatrixError.server(_, "M_FORBIDDEN", _) {
			throw MatrixError.authenticationFailed
		}
		guard let userID = reply["user_id"].string, let token = reply["access_token"].string else {
			throw MatrixError.badResponse("login reply without user_id/access_token")
		}
		return Login(userID: userID, accessToken: token, deviceID: reply["device_id"].string ?? deviceID)
	}

	/// Long-polls `/sync`. `timeout` is how long the server may hold the request (ms).
	public func sync(since: String?, filter: JSON, timeout: Int, setPresence: String) async throws -> JSON {
		var query = ["filter": String(decoding: filter.encoded(), as: UTF8.self), "timeout": String(timeout), "set_presence": setPresence]
		if let since { query["since"] = since }
		return try await call("GET", "/sync", query: query, timeout: TimeInterval(timeout / 1000 + 30))
	}
}
