import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Minimal namespace-agnostic XML DOM. SOAP responses from Passport/ABCH mix
/// prefixes freely, so elements are matched by local name only.
public final class XElement {
	public let name: String
	public var attributes: [String: String]
	public var children: [XElement] = []
	public var text = ""
	public weak var parent: XElement?

	init(name: String, attributes: [String: String]) {
		self.name = name
		self.attributes = attributes
	}

	public static func parse(_ data: Data) throws -> XElement {
		let builder = Builder()
		let parser = XMLParser(data: data)
		parser.delegate = builder
		parser.shouldProcessNamespaces = false
		guard parser.parse(), let root = builder.root else {
			throw MSNPError.unexpected("Malformed XML: \(parser.parserError?.localizedDescription ?? "no root")")
		}
		return root
	}

	public static func parse(_ string: String) throws -> XElement {
		try parse(Data(string.utf8))
	}

	/// First direct child with the given local name.
	public func child(_ name: String) -> XElement? {
		children.first { $0.name == name }
	}

	public func children(_ name: String) -> [XElement] {
		children.filter { $0.name == name }
	}

	/// First descendant (depth-first) matching a `/`-separated local-name path.
	public func find(_ path: String) -> XElement? {
		let parts = path.split(separator: "/").map(String.init)
		return find(parts[...])
	}

	private func find(_ parts: ArraySlice<String>) -> XElement? {
		guard let first = parts.first else { return self }
		for el in descendants(named: first) {
			if let hit = el.findDirect(parts.dropFirst()) { return hit }
		}
		return nil
	}

	private func findDirect(_ parts: ArraySlice<String>) -> XElement? {
		guard let first = parts.first else { return self }
		for c in children(first) {
			if let hit = c.findDirect(parts.dropFirst()) { return hit }
		}
		return nil
	}

	public func descendants(named name: String) -> [XElement] {
		var out: [XElement] = []
		var stack = children.reversed() as [XElement]
		while let el = stack.popLast() {
			if el.name == name { out.append(el) }
			stack.append(contentsOf: el.children.reversed())
		}
		return out
	}

	/// Trimmed text of a descendant path, or nil when absent/empty.
	public func value(_ path: String) -> String? {
		guard let el = find(path) else { return nil }
		let t = el.text.trimmingCharacters(in: .whitespacesAndNewlines)
		return t.isEmpty ? nil : t
	}

	private final class Builder: NSObject, XMLParserDelegate {
		var root: XElement?
		var stack: [XElement] = []

		func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
			let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
			var attrs: [String: String] = [:]
			for (k, v) in attributeDict {
				attrs[k.split(separator: ":").last.map(String.init) ?? k] = v
			}
			let el = XElement(name: local, attributes: attrs)
			el.parent = stack.last
			stack.last?.children.append(el)
			if root == nil { root = el }
			stack.append(el)
		}

		func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
			_ = stack.popLast()
		}

		func parser(_ parser: XMLParser, foundCharacters string: String) {
			stack.last?.text += string
		}

		func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
			stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
		}
	}
}

extension String {
	public var xmlEscaped: String {
		var s = ""
		s.reserveCapacity(count)
		for ch in self {
			switch ch {
			case "&": s += "&amp;"
			case "<": s += "&lt;"
			case ">": s += "&gt;"
			case "\"": s += "&quot;"
			case "'": s += "&apos;"
			default: s.append(ch)
			}
		}
		return s
	}
}
