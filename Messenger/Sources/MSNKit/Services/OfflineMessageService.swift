import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A message left while its recipient was offline (OIM).
public struct OfflineMessage: Equatable {
	public var id: String
	public var from: String
	public var displayName: String?
	public var text: String
	public var sent: Date?
}

/// Offline messages, as msnmsgr.exe's CHotmailService does them: Hotmail's RSI
/// service lists, fetches and deletes the ones waiting for us, and the OIM web
/// service stores one for an offline contact. SOAP bodies follow the templates
/// in msnmsgr.exe .data (0x35b440–0x35f0f8); Escargot serves both services at
/// WLM's original paths.
public struct OfflineMessageService {
	static let rsiNS = "http://www.hotmail.msn.com/ws/2004/09/oim/rsi"
	static let oimNS = "http://messenger.msn.com/ws/2004/09/oim/"
	static let storeAction = "http://messenger.live.com/ws/2006/09/oim/Store2"

	public enum StoreResult: Equatable {
		case stored
		/// The OIM service wants a lock key: the CHL algorithm applied to this challenge.
		case lockKeyChallenge(String)
	}

	public let config: ServerConfig
	/// The messenger.msn.com ticket, `t=…&p=…`.
	public let ticket: String
	public let session: URLSession

	public init(config: ServerConfig, ticket: String, session: URLSession = .shared) {
		self.config = config
		self.ticket = ticket
		self.session = session
	}

	private var cookie: (t: String, p: String) {
		var t = "", p = ""
		for part in ticket.split(separator: "&") {
			if part.hasPrefix("t=") { t = String(part.dropFirst(2)) }
			if part.hasPrefix("p=") { p = String(part.dropFirst(2)) }
		}
		return (t, p)
	}

	// MARK: RSI (receiving)

	/// The waiting messages' metadata, for when the NS's Mail-Data was "too-large".
	public func metadata() async throws -> [OfflineMessage] {
		let root = try await rsi("GetMetadata", "<GetMetadata xmlns=\"\(Self.rsiNS)\" />")
		guard let md = root.find("MD") else { return [] }
		return Self.messages(in: md)
	}

	/// One message, decoded; `nil` if the server no longer has it.
	public func message(_ id: String) async throws -> OfflineMessage? {
		let root = try await rsi("GetMessage", """
			<GetMessage xmlns="\(Self.rsiNS)"> <messageId>\(id.xmlEscaped)</messageId> \
			<alsoMarkAsRead>false</alsoMarkAsRead> </GetMessage>
			""")
		guard let raw = root.value("GetMessageResult"), !raw.isEmpty else { return nil }
		return Self.parseMessage(raw, id: id)
	}

	public func delete(_ ids: [String]) async throws {
		guard !ids.isEmpty else { return }
		let list = ids.map { "<messageId>\($0.xmlEscaped)</messageId>" }.joined(separator: " ")
		_ = try await rsi("DeleteMessages", "<DeleteMessages xmlns=\"\(Self.rsiNS)\"> <messageIds> \(list) </messageIds> </DeleteMessages>")
	}

	private func rsi(_ action: String, _ body: String) async throws -> XElement {
		let (t, p) = cookie
		let envelope = """
			<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" \
			xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Header>\
			<PassportCookie xmlns="\(Self.rsiNS)"> <t>\(t.xmlEscaped)</t> <p>\(p.xmlEscaped)</p> </PassportCookie>\
			</soap:Header><soap:Body>\(body)</soap:Body></soap:Envelope>
			"""
		let (status, root) = try await post(config.rsiURL, action: "\(Self.rsiNS)/\(action)", envelope)
		if let fault = root?.find("Fault") {
			throw ABError.fault(fault.value("faultstring") ?? "RSI fault")
		}
		guard status == 200, let root else { throw ABError.http(status) }
		return root
	}

	// MARK: OIM (sending)

	/// Stores `text` for `to`. Messages to one contact share a run ID and count
	/// up from sequence 1; the first attempt has no lock key, and the service
	/// answers with the challenge to compute it from.
	public func store(from: String, displayName: String, to: String, text: String,
	                  runID: String, sequence: Int, lockKey: String) async throws -> StoreResult {
		let friendly = "=?utf-8?B?\(Data(displayName.utf8).base64EncodedString())?="
		let body = Data(text.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
		let envelope = """
			<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" \
			xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Header>\
			<From memberName="\(from.xmlEscaped)" friendlyName="\(friendly)" xml:lang="en-US" proxy="MSNMSGR" \
			xmlns="\(Self.oimNS)" msnpVer="MSNP15" buildVer="\(ClientIdentity.clientVersion)"/> \
			<To memberName="\(to.xmlEscaped)" xmlns="\(Self.oimNS)"/> \
			<Ticket passport="\(ticket.xmlEscaped)" appid="\(MSNPChallenge.productID.xmlEscaped)" lockkey="\(lockKey.xmlEscaped)" \
			xmlns="\(Self.oimNS)"/> \
			<Sequence xmlns="http://schemas.xmlsoap.org/ws/2003/03/rm"><Identifier \
			xmlns="http://schemas.xmlsoap.org/ws/2002/07/utility">http://messenger.msn.com</Identifier>\
			<MessageNumber>\(sequence)</MessageNumber></Sequence></soap:Header><soap:Body>\
			<MessageType xmlns="\(Self.oimNS)">text</MessageType> \
			<Content xmlns="\(Self.oimNS)">MIME-Version: 1.0\r
			Content-Type: text/plain; charset=UTF-8\r
			Content-Transfer-Encoding: base64\r
			X-OIM-Message-Type: OfflineMessage\r
			X-OIM-Run-Id: \(runID)\r
			X-OIM-Sequence-Num: \(sequence)\r
			\r
			\(body)</Content> </soap:Body></soap:Envelope>
			"""
		let (status, root) = try await post(config.oimURL, action: Self.storeAction, envelope)
		if let fault = root?.find("Fault") {
			if let challenge = root?.value("LockKeyChallenge"), !challenge.isEmpty {
				return .lockKeyChallenge(challenge.trimmingCharacters(in: .whitespacesAndNewlines))
			}
			throw ABError.fault(fault.value("faultcode") ?? fault.value("faultstring") ?? "OIM fault")
		}
		guard status == 200 else { throw ABError.http(status) }
		return .stored
	}

	private func post(_ url: URL, action: String, _ envelope: String) async throws -> (Int, XElement?) {
		var req = URLRequest(url: url)
		req.httpMethod = "POST"
		req.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
		req.setValue("\"\(action)\"", forHTTPHeaderField: "SOAPAction")
		req.httpBody = Data(envelope.utf8)
		req.timeoutInterval = 30
		let (data, response) = try await session.data(for: req)
		return ((response as? HTTPURLResponse)?.statusCode ?? 0, try? XElement.parse(data))
	}

	// MARK: Parsing

	/// `Mail-Data` from the NS (`<MD>…<M><E>from</E><I>id</I><N>name</N>…</M></MD>`);
	/// `nil` for "too-large", when the list has to come from `metadata()`.
	public static func parseMailData(_ text: String) -> [OfflineMessage]? {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed == "too-large" { return nil }
		guard let md = try? XElement.parse(trimmed) else { return [] }
		return messages(in: md)
	}

	static func messages(in md: XElement) -> [OfflineMessage] {
		md.children("M").compactMap { m in
			guard let from = m.value("E"), let id = m.value("I") else { return nil }
			let sent = m.value("RT").flatMap { ISO8601DateFormatter.oim.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
			return OfflineMessage(id: id, from: from.lowercased(), displayName: m.value("N").map(decodeWord), text: "", sent: sent)
		}
	}

	/// The RFC 822 message from `GetMessage`: headers, blank line, base64 body.
	static func parseMessage(_ raw: String, id: String) -> OfflineMessage {
		let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
		let parts = normalized.components(separatedBy: "\n\n")
		var headers: [String: String] = [:]
		var lastKey: String?
		for line in (parts.first ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
			if line.first == " " || line.first == "\t", let k = lastKey {
				headers[k, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
			} else if let colon = line.firstIndex(of: ":") {
				let k = line[..<colon].lowercased()
				headers[k] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
				lastKey = k
			}
		}
		let bodyText = parts.dropFirst().joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
		var text = bodyText
		if headers["content-transfer-encoding"]?.lowercased() == "base64",
		   let data = Data(base64Encoded: bodyText.replacingOccurrences(of: "\n", with: ""), options: .ignoreUnknownCharacters) {
			text = String(decoding: data, as: UTF8.self)
		}
		// From: =?utf-8?B?…?= <alice@example.com>
		var from = "", name: String?
		if let raw = headers["from"] {
			if let lt = raw.lastIndex(of: "<"), let gt = raw.lastIndex(of: ">"), lt < gt {
				from = String(raw[raw.index(after: lt)..<gt])
				let n = raw[..<lt].trimmingCharacters(in: .whitespaces)
				if !n.isEmpty { name = decodeWord(n) }
			} else {
				from = raw
			}
		}
		let sent = headers["date"].flatMap { DateFormatter.oimDate.date(from: $0) }
		return OfflineMessage(id: id, from: from.lowercased(), displayName: name, text: text, sent: sent)
	}

	/// RFC 2047 encoded word (`=?utf-8?B?…?=` or `?Q?`), or the text as is.
	static func decodeWord(_ s: String) -> String {
		let t = s.trimmingCharacters(in: .whitespaces)
		guard t.hasPrefix("=?"), t.hasSuffix("?="), case let parts = t.dropFirst(2).dropLast(2).split(separator: "?", maxSplits: 2), parts.count == 3 else {
			return s
		}
		let payload = String(parts[2])
		switch parts[1].uppercased() {
		case "B":
			return Data(base64Encoded: payload).map { String(decoding: $0, as: UTF8.self) } ?? s
		case "Q":
			// "_" is a space and "=XX" a hex byte; the rest is literal ASCII.
			var bytes: [UInt8] = []
			var chars = Array(payload.utf8)[...]
			while let c = chars.popFirst() {
				if c == UInt8(ascii: "="), chars.count >= 2, let b = UInt8(String(decoding: chars.prefix(2), as: UTF8.self), radix: 16) {
					bytes.append(b)
					chars = chars.dropFirst(2)
				} else {
					bytes.append(c == UInt8(ascii: "_") ? 0x20 : c)
				}
			}
			return String(decoding: bytes, as: UTF8.self)
		default:
			return s
		}
	}
}

extension ISO8601DateFormatter {
	/// Mail-Data `<RT>`: 2026-10-28T14:20:09.000Z (fractional seconds optional).
	static let oim: ISO8601DateFormatter = {
		let f = ISO8601DateFormatter()
		f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return f
	}()
}

extension DateFormatter {
	/// The OIM's `Date:` header, e.g. "28 Oct 2026 07:20:09 -0800".
	static let oimDate: DateFormatter = {
		let f = DateFormatter()
		f.locale = Locale(identifier: "en_US_POSIX")
		f.dateFormat = "d MMM yyyy HH:mm:ss Z"
		return f
	}()
}
