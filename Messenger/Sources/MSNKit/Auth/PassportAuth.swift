import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Tokens returned by Passport `RST.srf` (WS-Trust RequestMultipleSecurityTokens).
public struct PassportTokens {
	public struct Token {
		public let ticket: String
		public let binarySecret: String?
		public let expires: Date?
	}

	public var byTarget: [String: Token] = [:]
	public var cid: String?
	public var puid: String?

	public subscript(target: String) -> Token? { byTarget[target] }

	/// Ticket for the NS (`USR SSO S`) plus the proof key for the MBI blob.
	public var messengerClear: Token? { byTarget["messengerclear.live.com"] }
	/// Ticket for ABCH SOAP (`ABAuthHeader/TicketToken`).
	public var contacts: Token? { byTarget["contacts.msn.com"] }
	/// Ticket for the Storage service (roaming name/personal message).
	public var storage: Token? { byTarget["storage.msn.com"] }
}

public enum PassportError: Error, LocalizedError {
	case authenticationFailed
	case badResponse(String)
	case http(Int)

	public var errorDescription: String? {
		switch self {
		case .authenticationFailed: return "The e-mail address or password is incorrect."
		case let .badResponse(why): return "The sign-in service sent an unexpected response (\(why))."
		case let .http(code): return "The sign-in service returned HTTP \(code)."
		}
	}
}

/// Native replacement for msidcrl40.dll's `LogonIdentityEx` path.
public struct PassportAuth {
	/// (service target, policy) pairs, from the table next to
	/// `messengerclear.live.com`/`MBI_KEY_OLD` in msnmsgr.exe .rdata (0x16ed60–0x16efd4).
	public static let serviceTargets: [(String, String?)] = [
		("http://Passport.NET/tb", nil),
		("messengerclear.live.com", "MBI_KEY_OLD"),
		("messenger.msn.com", "?id=507"),
		("contacts.msn.com", "MBI"),
		("storage.msn.com", "MBI"),
		("spaces.live.com", "MBI"),
		("messengersecure.live.com", "MBI_SSL"),
	]

	/// `ps:HostingApp`; a binary GUID at file offset 0x141968 in msnmsgr.exe.
	public static let hostingApp = "{7108E71A-9926-4FCB-BCC9-9A9D3F32E423}"

	public let config: ServerConfig
	public let session: URLSession

	public init(config: ServerConfig, session: URLSession = .shared) {
		self.config = config
		self.session = session
	}

	public func requestTokens(email: String, password: String) async throws -> PassportTokens {
		var req = URLRequest(url: config.rstURL)
		req.httpMethod = "POST"
		req.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
		req.httpBody = Data(Self.envelope(email: email, password: password).utf8)
		req.timeoutInterval = 30

		let (data, response) = try await session.data(for: req)
		if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode), http.statusCode != 500 {
			throw PassportError.http(http.statusCode)
		}
		return try Self.parse(data)
	}

	static func envelope(email: String, password: String) -> String {
		var tokens = ""
		for (i, (target, policy)) in serviceTargets.enumerated() {
			tokens += "<wst:RequestSecurityToken Id=\"RST\(i)\">"
				+ "<wst:RequestType>http://schemas.xmlsoap.org/ws/2004/04/security/trust/Issue</wst:RequestType>"
				+ "<wsp:AppliesTo><wsa:EndpointReference><wsa:Address>\(target)</wsa:Address></wsa:EndpointReference></wsp:AppliesTo>"
			if let policy {
				tokens += "<wsse:PolicyReference URI=\"\(policy.xmlEscaped)\"></wsse:PolicyReference>"
			}
			tokens += "</wst:RequestSecurityToken>"
		}
		return """
		<?xml version="1.0" encoding="UTF-8"?>\
		<Envelope xmlns="http://schemas.xmlsoap.org/soap/envelope/" xmlns:wsse="http://schemas.xmlsoap.org/ws/2003/06/secext" \
		xmlns:saml="urn:oasis:names:tc:SAML:1.0:assertion" xmlns:wsp="http://schemas.xmlsoap.org/ws/2002/12/policy" \
		xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" \
		xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/03/addressing" xmlns:wssc="http://schemas.xmlsoap.org/ws/2004/04/sc" \
		xmlns:wst="http://schemas.xmlsoap.org/ws/2004/04/trust">\
		<Header><ps:AuthInfo xmlns:ps="http://schemas.microsoft.com/Passport/SoapServices/PPCRL" Id="PPAuthInfo">\
		<ps:HostingApp>\(hostingApp)</ps:HostingApp><ps:BinaryVersion>4</ps:BinaryVersion><ps:UIVersion>1</ps:UIVersion>\
		<ps:Cookies></ps:Cookies><ps:RequestParams>AQAAAAIAAABsYwQAAAAxMDMz</ps:RequestParams></ps:AuthInfo>\
		<wsse:Security><wsse:UsernameToken Id="user"><wsse:Username>\(email.xmlEscaped)</wsse:Username>\
		<wsse:Password>\(password.xmlEscaped)</wsse:Password></wsse:UsernameToken></wsse:Security></Header>\
		<Body><ps:RequestMultipleSecurityTokens xmlns:ps="http://schemas.microsoft.com/Passport/SoapServices/PPCRL" Id="RSTS">\
		\(tokens)</ps:RequestMultipleSecurityTokens></Body></Envelope>
		"""
	}

	static func parse(_ data: Data) throws -> PassportTokens {
		let root = try XElement.parse(data)
		if root.find("Fault") != nil || root.value("pp/reqstatus").map({ $0 != "0x0" }) == true {
			throw PassportError.authenticationFailed
		}
		var result = PassportTokens()
		let iso = ISO8601DateFormatter()
		for rstr in root.descendants(named: "RequestSecurityTokenResponse") {
			guard let target = rstr.value("AppliesTo/EndpointReference/Address"),
			      let ticket = rstr.value("RequestedSecurityToken/BinarySecurityToken") else { continue }
			result.byTarget[target] = .init(
				ticket: ticket,
				binarySecret: rstr.value("RequestedProofToken/BinarySecret"),
				expires: rstr.value("LifeTime/Expires").flatMap { iso.date(from: $0) }
			)
		}
		result.puid = root.value("pp/PUID")
		for prop in root.descendants(named: "credProperty") where prop.attributes["Name"] == "CID" {
			result.cid = prop.text
		}
		guard result.messengerClear != nil else {
			throw PassportError.badResponse("no messengerclear.live.com token")
		}
		return result
	}
}
