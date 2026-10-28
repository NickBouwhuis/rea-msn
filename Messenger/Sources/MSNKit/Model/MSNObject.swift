#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// An `<msnobj …/>` descriptor: what a contact's display picture (type 3) or a
/// wink (type 8) is, sent in `CHG`/`NLN` and in P2P invitations. The data is
/// fetched peer-to-peer and identified by `SHA1D`, the SHA-1 of its bytes.
public struct MSNObject: Hashable, Codable {
	public enum Kind: Int, Codable {
		case customEmoticon = 2, displayPicture = 3, background = 5, wink = 8
	}

	public var creator: String
	public var size: Int
	public var type: Int
	public var location: String
	public var friendly: String
	public var sha1d: String
	public var sha1c: String?
	/// Any other attributes (e.g. winks' `stamp`), kept for re-encoding.
	public var extra: [String: String] = [:]
	/// The descriptor exactly as its creator sent it; WLM compares invitations'
	/// context against its own string, so requests echo this when known.
	public var original: String?

	public var kind: Kind? { Kind(rawValue: type) }

	/// Describes `data` as our own object of `kind`, with WLM's defaults for the
	/// location and (empty, base64 "AAA=") friendly name.
	public init(creator: String, data: Data, kind: Kind, location: String = "TFR2C2.tmp", friendly: String = "AAA=") {
		self.creator = creator
		size = data.count
		type = kind.rawValue
		self.location = location
		self.friendly = friendly
		sha1d = Data(Insecure.SHA1.hash(data: data)).base64EncodedString()
		sha1c = computedSHA1C
	}

	/// SHA1C: the SHA-1 of the other fields, concatenated with their names.
	public var computedSHA1C: String {
		let fields = "Creator\(creator)Size\(size)Type\(type)Location\(location)Friendly\(friendly)SHA1D\(sha1d)"
		return Data(Insecure.SHA1.hash(data: Data(fields.utf8))).base64EncodedString()
	}

	/// Parses `<msnobj Creator="…" Size="…" …/>`, URL-decoded or not.
	public init?(_ raw: String) {
		var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		if s.hasPrefix("%3C") || s.hasPrefix("%3c") { s = s.removingPercentEncoding ?? s }
		guard s.hasPrefix("<msnobj") else { return nil }
		var attrs: [String: String] = [:]
		var rest = s.dropFirst("<msnobj".count)
		while let eq = rest.firstIndex(of: "=") {
			let key = rest[..<eq].trimmingCharacters(in: .whitespaces)
			let afterEq = rest[rest.index(after: eq)...]
			guard let q1 = afterEq.firstIndex(of: "\""),
			      let q2 = afterEq[afterEq.index(after: q1)...].firstIndex(of: "\"") else { break }
			attrs[key] = String(afterEq[afterEq.index(after: q1)..<q2]).xmlUnescaped
			rest = afterEq[afterEq.index(after: q2)...]
		}
		guard let creator = attrs.removeValue(forKey: "Creator"), let sha1d = attrs.removeValue(forKey: "SHA1D"),
		      let type = attrs.removeValue(forKey: "Type").flatMap(Int.init) else { return nil }
		self.creator = creator
		self.sha1d = sha1d
		self.type = type
		size = attrs.removeValue(forKey: "Size").flatMap(Int.init) ?? 0
		location = attrs.removeValue(forKey: "Location") ?? "0"
		friendly = attrs.removeValue(forKey: "Friendly") ?? "AAA="
		sha1c = attrs.removeValue(forKey: "SHA1C")
		extra = attrs
		original = s
	}

	public var xml: String {
		if let original { return original }
		var s = "<msnobj Creator=\"\(creator.xmlEscaped)\" Size=\"\(size)\" Type=\"\(type)\" Location=\"\(location.xmlEscaped)\" "
		s += "Friendly=\"\(friendly.xmlEscaped)\" SHA1D=\"\(sha1d.xmlEscaped)\""
		if let sha1c { s += " SHA1C=\"\(sha1c.xmlEscaped)\"" }
		for (k, v) in extra.sorted(by: { $0.key < $1.key }) { s += " \(k)=\"\(v.xmlEscaped)\"" }
		return s + "/>"
	}

	/// Whether `data` is this object's content.
	public func matches(_ data: Data) -> Bool {
		Data(Insecure.SHA1.hash(data: data)).base64EncodedString() == sha1d
	}

	/// A file name for caching the data, from SHA1D (base64 made path-safe).
	public var cacheName: String {
		sha1d.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
	}
}

extension String {
	var xmlUnescaped: String {
		replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
			.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
			.replacingOccurrences(of: "&amp;", with: "&")
	}
}
