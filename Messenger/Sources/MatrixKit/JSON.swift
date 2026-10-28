import Foundation

/// A JSON value. Matrix event content is open-ended, so it is read loosely:
/// a missing key or a value of the wrong type reads as `.null` / nil.
public enum JSON: Hashable, Sendable {
	case null
	case bool(Bool)
	case number(Double)
	case string(String)
	case array([JSON])
	case object([String: JSON])

	public subscript(key: String) -> JSON {
		if case let .object(o) = self { return o[key] ?? .null }
		return .null
	}

	public var string: String? { if case let .string(s) = self { return s }; return nil }
	public var bool: Bool? { if case let .bool(b) = self { return b }; return nil }
	public var int: Int? { if case let .number(n) = self { return Int(exactly: n.rounded()) }; return nil }
	public var array: [JSON] { if case let .array(a) = self { return a }; return [] }
	public var object: [String: JSON] { if case let .object(o) = self { return o }; return [:] }
	public var isNull: Bool { self == .null }

	public init(data: Data) throws {
		self = try JSONDecoder().decode(JSON.self, from: data)
	}

	public func encoded() -> Data {
		(try? JSONEncoder().encode(self)) ?? Data("null".utf8)
	}
}

extension JSON: Codable {
	public init(from decoder: Decoder) throws {
		let c = try decoder.singleValueContainer()
		if c.decodeNil() { self = .null }
		else if let b = try? c.decode(Bool.self) { self = .bool(b) }
		else if let n = try? c.decode(Double.self) { self = .number(n) }
		else if let s = try? c.decode(String.self) { self = .string(s) }
		else if let a = try? c.decode([JSON].self) { self = .array(a) }
		else { self = .object(try c.decode([String: JSON].self)) }
	}

	public func encode(to encoder: Encoder) throws {
		var c = encoder.singleValueContainer()
		switch self {
		case .null: try c.encodeNil()
		case let .bool(b): try c.encode(b)
		case let .number(n):
			if let i = Int(exactly: n) { try c.encode(i) } else { try c.encode(n) }
		case let .string(s): try c.encode(s)
		case let .array(a): try c.encode(a)
		case let .object(o): try c.encode(o)
		}
	}
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
	ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
	public init(stringLiteral value: String) { self = .string(value) }
	public init(integerLiteral value: Int) { self = .number(Double(value)) }
	public init(booleanLiteral value: Bool) { self = .bool(value) }
	public init(arrayLiteral elements: JSON...) { self = .array(elements) }
	public init(dictionaryLiteral elements: (String, JSON)...) {
		self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
	}
	public init(nilLiteral: ()) { self = .null }
}
