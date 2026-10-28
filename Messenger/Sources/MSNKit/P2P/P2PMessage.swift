import Foundation

/// MSNC P2P v1, as WLM 8.1 sends it through the switchboard: a `MSG … D` with
/// `Content-Type: application/x-msnmsgrp2p` and `P2P-Dest`, whose body is a
/// 48-byte little-endian header, up to 1202 bytes of payload, and a big-endian
/// footer naming the application (0 for SLP, 1 for objects, 2 for files).
struct P2PHeader: Equatable {
	var sessionID: UInt32 = 0
	var identifier: UInt32 = 0
	var offset: UInt64 = 0
	var totalSize: UInt64 = 0
	var length: UInt32 = 0
	var flags: UInt32 = 0
	var ackIdentifier: UInt32 = 0
	var ackUniqueID: UInt32 = 0
	var ackDataSize: UInt64 = 0

	static let size = 48

	init() {}

	init?(_ d: Data) {
		guard d.count >= Self.size else { return nil }
		let b = [UInt8](d.prefix(Self.size))
		func u32(_ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[o + $1]) << (8 * $1) } }
		func u64(_ o: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(b[o + $1]) << (8 * $1) } }
		sessionID = u32(0); identifier = u32(4); offset = u64(8); totalSize = u64(16)
		length = u32(24); flags = u32(28); ackIdentifier = u32(32); ackUniqueID = u32(36); ackDataSize = u64(40)
	}

	var data: Data {
		var d = Data(capacity: Self.size)
		for v in [sessionID, identifier] { d.appendLE(v) }
		for v in [offset, totalSize] { d.appendLE(v) }
		for v in [length, flags, ackIdentifier, ackUniqueID] { d.appendLE(v) }
		d.appendLE(ackDataSize)
		return d
	}
}

enum P2PFlags {
	static let ack: UInt32 = 0x2
	static let bye: UInt32 = 0x40
	static let objectData: UInt32 = 0x20
	static let fileData: UInt32 = 0x0100_0030
}

enum P2PApp {
	static let session: UInt32 = 0
	static let object: UInt32 = 1
	static let file: UInt32 = 2
}

struct P2PPacket {
	var header: P2PHeader
	var payload: Data
	var footer: UInt32

	/// The most payload WLM puts in one switchboard message.
	static let maxPayload = 1202

	init(header: P2PHeader, payload: Data = Data(), footer: UInt32 = 0) {
		self.header = header
		self.payload = payload
		self.footer = footer
	}

	init?(_ body: Data) {
		guard let h = P2PHeader(body) else { return nil }
		header = h
		let start = body.startIndex + P2PHeader.size
		let end = min(body.endIndex, start + Int(h.length))
		payload = Data(body[start..<end])
		let f = body[end...].prefix(4)
		footer = f.count == 4 ? f.reduce(0) { $0 << 8 | UInt32($1) } : 0
	}

	func mime(to email: String) -> MIMEMessage {
		var body = header.data + payload
		body.append(contentsOf: [UInt8(footer >> 24 & 0xFF), UInt8(footer >> 16 & 0xFF), UInt8(footer >> 8 & 0xFF), UInt8(footer & 0xFF)])
		return MIMEMessage(headers: [
			("MIME-Version", "1.0"),
			("Content-Type", "application/x-msnmsgrp2p"),
			("P2P-Dest", email),
		], body: body)
	}
}

/// An MSNSLP message (SIP-like text carried in session 0): `INVITE`, `BYE`, or
/// a `MSNSLP/1.0 <code>` reply, whose body is `Key: value` lines ending in a NUL.
struct SLPMessage {
	var startLine: String
	var headers: [(String, String)]
	var body: String

	static let objectGUID = "{A4268EEC-FEC5-49E5-95C3-F126696BDBF6}"
	static let fileGUID = "{5D3E02AB-6190-11D3-BBBB-00C04F795683}"

	var method: String? {
		startLine.hasPrefix("MSNSLP/") ? nil : startLine.split(separator: " ").first.map(String.init)
	}

	var status: Int? {
		guard startLine.hasPrefix("MSNSLP/") else { return nil }
		return startLine.split(separator: " ").dropFirst().first.flatMap { Int($0) }
	}

	subscript(name: String) -> String? {
		headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
	}

	var contentType: String { self["Content-Type"] ?? "" }
	var callID: String { self["Call-ID"] ?? "" }

	/// `branch={…}` from the Via header.
	var branch: String {
		guard let via = self["Via"], let r = via.range(of: "branch=") else { return "" }
		return String(via[r.upperBound...]).trimmingCharacters(in: .whitespaces)
	}

	/// A body field, e.g. `SessionID` or `Context`.
	func field(_ name: String) -> String? {
		for line in body.components(separatedBy: "\r\n") {
			guard let colon = line.firstIndex(of: ":") else { continue }
			if line[..<colon].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame {
				return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
			}
		}
		return nil
	}

	init(startLine: String, headers: [(String, String)], body: String) {
		self.startLine = startLine
		self.headers = headers
		self.body = body
	}

	init?(_ data: Data) {
		let text = String(decoding: data, as: UTF8.self)
		guard let split = text.range(of: "\r\n\r\n") else { return nil }
		var lines = text[..<split.lowerBound].components(separatedBy: "\r\n")
		guard !lines.isEmpty else { return nil }
		startLine = lines.removeFirst()
		headers = lines.compactMap { line in
			guard let colon = line.firstIndex(of: ":") else { return nil }
			return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
		}
		body = String(text[split.upperBound...]).replacingOccurrences(of: "\0", with: "")
	}

	/// Builds the wire form; Content-Length counts the body's terminating NUL.
	static func make(_ startLine: String, to: String, from: String, branch: String, cseq: Int, callID: String,
	                 contentType: String, body: String) -> Data {
		let content = Data(body.utf8) + Data([0])
		let head = """
			\(startLine)\r
			To: <msnmsgr:\(to)>\r
			From: <msnmsgr:\(from)>\r
			Via: MSNSLP/1.0/TLP ;branch=\(branch)\r
			CSeq: \(cseq) \r
			Call-ID: \(callID)\r
			Max-Forwards: 0\r
			Content-Type: \(contentType)\r
			Content-Length: \(content.count)\r
			\r

			"""
		return Data(head.utf8) + content
	}
}

/// The 574-byte context of a file transfer invitation (version 2, as WLM 8.1
/// sends it): sizes, a flag for whether a preview follows, and the file name in
/// UTF-16LE.
enum FileContext {
	static let size = 574

	static func encode(name: String, size fileSize: UInt64) -> Data {
		var d = Data()
		d.appendLE(UInt32(size))
		d.appendLE(UInt32(2))
		d.appendLE(fileSize)
		d.appendLE(UInt32(1))  // no preview
		var nameBytes = Data(count: 520)
		for (i, unit) in name.utf16.prefix(259).enumerated() {
			nameBytes[2 * i] = UInt8(unit & 0xFF)
			nameBytes[2 * i + 1] = UInt8(unit >> 8)
		}
		d.append(nameBytes)
		d.append(Data(count: 30))
		d.appendLE(UInt32(0xFFFF_FFFF))
		return d
	}

	static func decode(_ d: Data) -> (name: String, size: UInt64)? {
		let b = [UInt8](d)
		guard b.count >= 20 + 520 else { return nil }
		let version = (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[4 + $1]) << (8 * $1) }
		guard version == 2 || version == 3 else { return nil }
		let size = (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[8 + $1]) << (8 * $1) }
		var units: [UInt16] = []
		for i in 0..<260 {
			let u = UInt16(b[20 + 2 * i]) | UInt16(b[21 + 2 * i]) << 8
			if u == 0 { break }
			units.append(u)
		}
		return (String(decoding: units, as: UTF16.self), size)
	}
}

extension Data {
	mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
		var le = v.littleEndian
		Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
	}
}
