import Foundation

/// `X-MMS-IM-Format` text style, e.g. `FN=Segoe%20UI; EF=B; CO=ff; CS=0; PF=22`.
public struct TextFormat: Hashable, Codable {
	public var fontName: String = "Segoe UI"
	public var bold = false
	public var italic = false
	public var underline = false
	public var strikethrough = false
	/// RGB as 0xRRGGBB (the wire format is BGR hex).
	public var color: UInt32 = 0

	public init() {}

	public init(header: String) {
		for field in header.split(separator: ";") {
			let kv = field.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
			guard kv.count == 2 else { continue }
			switch kv[0] {
			case "FN": fontName = kv[1].msnpURLDecoded
			case "EF":
				bold = kv[1].contains("B"); italic = kv[1].contains("I")
				underline = kv[1].contains("U"); strikethrough = kv[1].contains("S")
			case "CO":
				let bgr = UInt32(kv[1], radix: 16) ?? 0
				color = (bgr & 0xFF) << 16 | (bgr & 0xFF00) | (bgr >> 16) & 0xFF
			default: break
			}
		}
	}

	public var header: String {
		var ef = ""
		if bold { ef += "B" }
		if italic { ef += "I" }
		if underline { ef += "U" }
		if strikethrough { ef += "S" }
		let bgr = (color & 0xFF) << 16 | (color & 0xFF00) | (color >> 16) & 0xFF
		return "FN=\(fontName.msnpURLEncoded); EF=\(ef); CO=\(String(bgr, radix: 16)); CS=0; PF=22"
	}
}

/// A switchboard `MSG` body: MIME-style headers, blank line, content.
public struct MIMEMessage {
	public var headers: [(String, String)]
	public var body: Data

	public init(headers: [(String, String)], body: Data = Data()) {
		self.headers = headers
		self.body = body
	}

	public subscript(name: String) -> String? {
		headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
	}

	public var contentType: String {
		(self["Content-Type"] ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
	}

	public var bodyString: String { String(decoding: body, as: UTF8.self) }

	public init(parsing data: Data) {
		let sep = Data("\r\n\r\n".utf8)
		let headerData: Data
		if let r = data.range(of: sep) {
			headerData = data[data.startIndex..<r.lowerBound]
			body = Data(data[r.upperBound...])
		} else {
			headerData = data
			body = Data()
		}
		headers = String(decoding: headerData, as: UTF8.self)
			.components(separatedBy: "\r\n")
			.compactMap { line in
				guard let colon = line.firstIndex(of: ":") else { return nil }
				return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
			}
	}

	public func encoded() -> Data {
		var s = ""
		for (k, v) in headers { s += "\(k): \(v)\r\n" }
		s += "\r\n"
		return Data(s.utf8) + body
	}

	// MARK: - Message kinds observed in msnmsgr.exe .rdata

	/// "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\n" (0x12bf90)
	public static func text(_ text: String, format: TextFormat) -> MIMEMessage {
		MIMEMessage(headers: [
			("MIME-Version", "1.0"),
			("Content-Type", "text/plain; charset=UTF-8"),
			("X-MMS-IM-Format", format.header),
		], body: Data(text.utf8))
	}

	public static func typing(_ email: String) -> MIMEMessage {
		MIMEMessage(headers: [
			("MIME-Version", "1.0"),
			("Content-Type", "text/x-msmsgscontrol"),
			("TypingUser", email),
		], body: Data("\r\n".utf8))
	}

	public static func nudge() -> MIMEMessage {
		MIMEMessage(headers: [
			("MIME-Version", "1.0"),
			("Content-Type", "text/x-msnmsgr-datacast"),
		], body: Data("ID: 1\r\n\r\n".utf8))
	}
}

/// Personal status message payload for `UUX`/`UBX`.
public struct PersonalInfo: Equatable {
	public var personalMessage = ""
	public var currentMedia = ""
	public var machineGUID: String?

	public init(personalMessage: String = "", currentMedia: String = "", machineGUID: String? = nil) {
		self.personalMessage = personalMessage
		self.currentMedia = currentMedia
		self.machineGUID = machineGUID
	}

	public init(xml: Data) {
		guard let root = try? XElement.parse(xml) else { return }
		personalMessage = root.value("PSM") ?? ""
		currentMedia = PersonalInfo.decodeMedia(root.value("CurrentMedia") ?? "")
		machineGUID = root.value("MachineGuid")
	}

	public var xml: String {
		var s = "<Data><PSM>\(personalMessage.xmlEscaped)</PSM><CurrentMedia></CurrentMedia>"
		if let machineGUID { s += "<MachineGuid>\(machineGUID)</MachineGuid>" }
		return s + "</Data>"
	}

	/// `\0Music\01\0{0} - {1}\0Title\0Artist\0Album\0...` → "Artist - Title"
	static func decodeMedia(_ raw: String) -> String {
		let parts = raw.components(separatedBy: "\\0")
		guard parts.count > 4, parts[2] == "1" else { return "" }
		var template = parts[3]
		for (i, value) in parts.dropFirst(4).enumerated() {
			template = template.replacingOccurrences(of: "{\(i)}", with: value)
		}
		return template.trimmingCharacters(in: .whitespaces)
	}
}
