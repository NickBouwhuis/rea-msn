import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum MatrixError: Error, LocalizedError, Equatable {
	case badUserID(String)
	case noHomeserver(String)
	case unsupportedLogin
	case passwordRequired
	case authenticationFailed
	case encryptedRoom
	/// errcode/error from the homeserver, e.g. M_FORBIDDEN.
	case server(status: Int, code: String, message: String)
	case badResponse(String)

	public var errorDescription: String? {
		switch self {
		case let .badUserID(id): return "\"\(id)\" is not a Matrix ID. Matrix IDs look like @someone:matrix.org."
		case let .noHomeserver(name): return "Couldn't find the Matrix homeserver for \(name)."
		case .unsupportedLogin:
			return "This homeserver doesn't offer a way of signing in that this version of Messenger supports (password or web browser)."
		case .passwordRequired: return "Please type your password."
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

	/// The base URL without a trailing slash (well-known and the SDK may add one).
	private var base: String {
		var s = baseURL.absoluteString
		while s.hasSuffix("/") { s.removeLast() }
		return s
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
		let reply = try await data(method, path, query: query, body: body, timeout: timeout)
		return (try? JSON(data: reply)) ?? .null
	}

	/// A display-picture-sized thumbnail of an mxc:// URL, through authenticated
	/// media (v1.11), or the older unauthenticated endpoint on servers without it.
	public func thumbnail(_ mxc: String, size: Int = 96) async throws -> Data {
		guard mxc.hasPrefix("mxc://") else { throw MatrixError.badResponse("not an mxc:// URL: \(mxc)") }
		let parts = mxc.dropFirst("mxc://".count).split(separator: "/", maxSplits: 1).map(String.init)
		guard parts.count == 2 else { throw MatrixError.badResponse("bad mxc:// URL: \(mxc)") }
		let path = "/\(Self.segment(parts[0]))/\(Self.segment(parts[1]))"
		let query = ["width": String(size), "height": String(size), "method": "crop"]
		do {
			return try await data("GET", "/_matrix/client/v1/media/thumbnail" + path, query: query)
		} catch MatrixError.server(let status, _, _) where status == 404 || status == 400 {
			return try await data("GET", "/_matrix/media/v3/thumbnail" + path, query: query)
		}
	}

	/// The raw response body of a request; non-2xx statuses throw MatrixError.server.
	public func data(_ method: String, _ path: String, query: [String: String] = [:], body: JSON? = nil,
	                 timeout: TimeInterval = 30) async throws -> Data {
		let full = path.hasPrefix("/_matrix/") ? path : "/_matrix/client/v3" + path
		guard var components = URLComponents(string: base + full) else {
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
			if (200..<300).contains(status) { return data }
			let json = (try? JSON(data: data)) ?? .null
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

	/// The login types the homeserver offers, e.g. m.login.password, m.login.sso.
	public func loginFlows() async throws -> [String] {
		try await call("GET", "/login")["flows"].array.compactMap { $0["type"].string }
	}

	public func login(user: String, password: String, deviceID: String, deviceName: String) async throws -> Login {
		try await login([
			"type": "m.login.password",
			"identifier": ["type": "m.id.user", "user": .string(user)],
			"password": .string(password),
		], deviceID: deviceID, deviceName: deviceName)
	}

	/// Finishes a browser (SSO) sign-in with the loginToken the homeserver redirected back with.
	public func login(token: String, deviceID: String, deviceName: String) async throws -> Login {
		try await login(["type": "m.login.token", "token": .string(token)], deviceID: deviceID, deviceName: deviceName)
	}

	/// Where to send the browser for SSO; the homeserver comes back to `redirect` with ?loginToken=.
	public func ssoRedirectURL(returningTo redirect: URL) -> URL {
		var components = URLComponents(string: base + "/_matrix/client/v3/login/sso/redirect")!
		components.queryItems = [URLQueryItem(name: "redirectUrl", value: redirect.absoluteString)]
		return components.url!
	}

	private func login(_ credentials: JSON, deviceID: String, deviceName: String) async throws -> Login {
		var body = credentials.object
		body["device_id"] = .string(deviceID)
		body["initial_device_display_name"] = .string(deviceName)
		let reply: JSON
		do {
			reply = try await call("POST", "/login", body: .object(body))
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
