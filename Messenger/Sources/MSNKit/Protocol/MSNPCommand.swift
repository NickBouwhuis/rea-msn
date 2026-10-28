import Foundation

/// One MSNP line, optionally followed by a length-prefixed payload.
///
/// Wire format (observed in msnmsgr.exe and the Escargot NS/SB):
///   `NAME [trid] arg1 arg2 ...[ payloadLength]\r\n[payload bytes]`
public struct MSNPCommand: Equatable, CustomStringConvertible {
	public var name: String
	public var args: [String]
	public var payload: Data?

	public init(_ name: String, _ args: [String] = [], payload: Data? = nil) {
		self.name = name
		self.args = args
		self.payload = payload
	}

	/// Transaction ID, when the first argument is one.
	public var trID: Int? {
		guard !MSNPCommand.commandsWithoutTrID.contains(name), let first = args.first else { return nil }
		return Int(first)
	}

	/// Numeric server error (e.g. `911 4`).
	public var errorCode: Int? {
		name.allSatisfy(\.isNumber) ? Int(name) : nil
	}

	public var payloadString: String {
		payload.map { String(decoding: $0, as: UTF8.self) } ?? ""
	}

	public var description: String {
		var s = ([name] + args).joined(separator: " ")
		if let payload { s += " <\(payload.count) bytes>" }
		return s
	}

	/// Serialized bytes; the payload length is appended as the final argument.
	public func encoded() -> Data {
		var parts = [name] + args
		if let payload { parts.append(String(payload.count)) }
		var data = Data((parts.joined(separator: " ") + "\r\n").utf8)
		if let payload { data.append(payload) }
		return data
	}

	/// Commands whose first numeric argument is not a TrID.
	static let commandsWithoutTrID: Set<String> = ["RNG", "MSG", "NLN", "FLN", "UBX", "JOI", "BYE", "NOT", "IPG", "UBN"]

	/// Commands that may carry a payload when their last argument is a byte count.
	static let payloadCommands: Set<String> = [
		"MSG", "UBX", "UBN", "GCF", "NOT", "IPG", "ADL", "RML", "FQY", "UUN", "UUX", "SDG", "NFY", "PUT", "DEL",
	]

	/// Whether `name args` announces a payload, and its size.
	static func payloadLength(name: String, args: [String]) -> Int? {
		guard let last = args.last, let n = Int(last), n >= 0 else { return nil }
		if payloadCommands.contains(name) {
			// NOT/IPG carry only the length; everything else needs at least one other argument
			// (so `QRY 10` or `ADL 5 OK` are never mistaken for payload headers).
			return (args.count >= 2 || name == "NOT" || name == "IPG") ? n : nil
		}
		// MSNP13+ errors can echo the offending payload: `241 7 123\r\n<ml>...`.
		if name.allSatisfy(\.isNumber), args.count == 2, Int(args[0]) != nil {
			return n
		}
		return nil
	}
}

/// Incremental decoder for an MSNP byte stream.
public struct MSNPDecoder {
	private var buffer = Data()

	public init() {}

	public mutating func append(_ data: Data) {
		buffer.append(data)
	}

	/// Returns the next complete command, or nil when more bytes are needed.
	public mutating func next() throws -> MSNPCommand? {
		guard let nl = buffer.firstIndex(of: 0x0A) else { return nil }
		let lineData = buffer[buffer.startIndex..<nl]
		let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
		let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
		guard let name = parts.first else {
			buffer.removeSubrange(buffer.startIndex...nl)
			return try next()
		}
		let args = Array(parts.dropFirst())
		let bodyStart = buffer.index(after: nl)
		if let length = MSNPCommand.payloadLength(name: name, args: args) {
			guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
			let bodyEnd = buffer.index(bodyStart, offsetBy: length)
			let payload = Data(buffer[bodyStart..<bodyEnd])
			buffer.removeSubrange(buffer.startIndex..<bodyEnd)
			return MSNPCommand(name, Array(args.dropLast()), payload: payload)
		}
		buffer.removeSubrange(buffer.startIndex..<bodyStart)
		return MSNPCommand(name, args)
	}
}

extension String {
	/// MSNP argument encoding: friendly names travel URL-encoded.
	public var msnpURLEncoded: String {
		var allowed = CharacterSet.alphanumerics
		allowed.insert(charactersIn: "-_.!~*'()")
		return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
	}

	public var msnpURLDecoded: String {
		removingPercentEncoding ?? self
	}
}
