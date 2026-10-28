import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Bits used by MSNP13+ `ADL`/`RML` (`l` attribute) and the Sharing service roles.
public struct MSNList: OptionSet, Hashable, Codable {
	public let rawValue: Int
	public init(rawValue: Int) { self.rawValue = rawValue }

	public static let forward = MSNList(rawValue: 1)   // FL: my contacts
	public static let allow = MSNList(rawValue: 2)     // AL
	public static let block = MSNList(rawValue: 4)     // BL
	public static let reverse = MSNList(rawValue: 8)   // RL: people who have me
	public static let pending = MSNList(rawValue: 16)  // PL: awaiting my approval

	public init?(role: String) {
		switch role {
		case "Allow": self = .allow
		case "Block": self = .block
		case "Reverse": self = .reverse
		case "Pending": self = .pending
		default: return nil
		}
	}

	public var role: String? {
		switch self {
		case .allow: return "Allow"
		case .block: return "Block"
		case .reverse: return "Reverse"
		case .pending: return "Pending"
		default: return nil
		}
	}
}

public struct ABContact: Hashable {
	public var contactID: String
	public var email: String
	public var displayName: String
	public var isMessengerUser: Bool
	public var groupIDs: [String]
}

public struct ABGroup: Hashable {
	public var groupID: String
	public var name: String
}

public struct AddressBook {
	public var contacts: [ABContact] = []
	public var groups: [ABGroup] = []
	/// Membership lists from the Sharing service, keyed by lowercased e-mail.
	public var memberships: [String: MSNList] = [:]
	public var memberDisplayNames: [String: String] = [:]
	/// Roaming friendly name from the `contactType=Me` entry.
	public var meDisplayName: String?
	/// Privacy mode from the Me entry's `MSN.IM.BLP` annotation (1 = AL, 2 = BL), if set.
	public var privacyMode: String?
}

public enum ABError: Error, LocalizedError {
	case fault(String)
	case http(Int)

	public var errorDescription: String? {
		switch self {
		case let .fault(s): return "Address book error: \(s)"
		case let .http(c): return "Address book service returned HTTP \(c)."
		}
	}
}

/// ABCH SOAP client (replaces abssm.dll). Request bodies are the format strings
/// recovered from abssm.dll .rdata (e.g. `<ABFindAll ...>` at 0x11520).
public struct ABService {
	/// `ABApplicationHeader/ApplicationId`, a UTF-16 string in msnmsgr.exe.
	public static let applicationID = "996CDE1E-AA53-4477-B943-2BE802EA6166"
	static let ns = "http://www.msn.com/webservices/AddressBook"
	static let defaultAB = "00000000-0000-0000-0000-000000000000"

	public let config: ServerConfig
	public var ticket: String
	public let session: URLSession

	public init(config: ServerConfig, ticket: String, session: URLSession = .shared) {
		self.config = config
		self.ticket = ticket
		self.session = session
	}

	// MARK: - Reads

	public func fetchAddressBook() async throws -> AddressBook {
		async let membershipXML = call(
			sharing: true, action: "FindMembership", scenario: "Initial",
			body: """
			<FindMembership xmlns="\(Self.ns)"><serviceFilter><Types><ServiceType>Messenger</ServiceType><ServiceType>Invitation</ServiceType><ServiceType>SocialNetwork</ServiceType><ServiceType>Space</ServiceType><ServiceType>Profile</ServiceType></Types></serviceFilter></FindMembership>
			"""
		)
		async let abXML = call(
			sharing: false, action: "ABFindAll", scenario: "Initial",
			body: """
			<ABFindAll xmlns="\(Self.ns)"><abId>\(Self.defaultAB)</abId><abView>Full</abView><deltasOnly>false</deltasOnly><dynamicItemView>Gleam</dynamicItemView></ABFindAll>
			"""
		)
		var book = AddressBook()
		let (members, ab) = try await (membershipXML, abXML)
		Self.parseMemberships(members, into: &book)
		Self.parseAddressBook(ab, into: &book)
		return book
	}

	static func parseMemberships(_ root: XElement, into book: inout AddressBook) {
		for service in root.descendants(named: "Service") {
			guard service.value("Info/Handle/Type") == "Messenger" else { continue }
			for membership in service.descendants(named: "Membership") {
				guard let role = membership.value("MemberRole"), let list = MSNList(role: role) else { continue }
				for member in membership.descendants(named: "Member") {
					guard let email = (member.value("PassportName") ?? member.value("Email"))?.lowercased() else { continue }
					book.memberships[email, default: []].insert(list)
					if let dn = member.value("DisplayName") { book.memberDisplayNames[email] = dn }
				}
			}
		}
	}

	static func parseAddressBook(_ root: XElement, into book: inout AddressBook) {
		for g in root.descendants(named: "Group") {
			guard let id = g.value("groupId"), let name = g.value("groupInfo/name") else { continue }
			book.groups.append(ABGroup(groupID: id, name: name))
		}
		for c in root.descendants(named: "Contact") {
			guard let id = c.value("contactId"), let info = c.child("contactInfo") else { continue }
			if info.value("contactType") == "Me" {
				book.meDisplayName = info.value("displayName")
				for a in info.descendants(named: "Annotation") where a.value("Name") == "MSN.IM.BLP" {
					book.privacyMode = ["1": "AL", "2": "BL"][a.value("Value") ?? ""]
				}
				continue
			}
			guard let email = info.value("passportName")?.lowercased() else { continue }
			book.contacts.append(ABContact(
				contactID: id,
				email: email,
				displayName: info.value("displayName") ?? email,
				isMessengerUser: info.value("isMessengerUser") != "false",
				groupIDs: info.child("groupIds")?.children("guid").map { $0.text } ?? []
			))
		}
	}

	// MARK: - Writes

	/// Adds `email` to the address book (forward list); returns the new contact GUID.
	@discardableResult
	public func addContact(email: String) async throws -> String? {
		let root = try await call(
			sharing: false, action: "ABContactAdd", scenario: "ContactSave",
			body: """
			<ABContactAdd xmlns="\(Self.ns)"><abId>\(Self.defaultAB)</abId><contacts><Contact xmlns="\(Self.ns)"><contactInfo><contactType>LivePending</contactType><passportName>\(email.xmlEscaped)</passportName><isMessengerUser>true</isMessengerUser><MessengerMemberInfo><DisplayName>\(email.xmlEscaped)</DisplayName></MessengerMemberInfo></contactInfo></Contact></contacts><options><EnableAllowListManagement>true</EnableAllowListManagement></options></ABContactAdd>
			"""
		)
		return root.value("ABContactAddResult/guid")
	}

	public func deleteContact(contactID: String) async throws {
		_ = try await call(
			sharing: false, action: "ABContactDelete", scenario: "Timer",
			body: """
			<ABContactDelete xmlns="\(Self.ns)"><abId>\(Self.defaultAB)</abId><contacts><Contact><contactId>\(contactID.xmlEscaped)</contactId></Contact></contacts></ABContactDelete>
			"""
		)
	}

	public func addMember(email: String, list: MSNList) async throws {
		try await membership(action: "AddMember", email: email, list: list)
	}

	public func deleteMember(email: String, list: MSNList) async throws {
		try await membership(action: "DeleteMember", email: email, list: list)
	}

	private func membership(action: String, email: String, list: MSNList) async throws {
		guard let role = list.role else { return }
		_ = try await call(
			sharing: true, action: action, scenario: "BlockUnblock",
			body: """
			<\(action) xmlns="\(Self.ns)"><serviceHandle><Id>0</Id><Type>Messenger</Type><ForeignId></ForeignId></serviceHandle><memberships><Membership><MemberRole>\(role)</MemberRole><Members><Member xsi:type="PassportMember" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><Type>Passport</Type><State>Accepted</State><PassportName>\(email.xmlEscaped)</PassportName></Member></Members></Membership></memberships></\(action)>
			"""
		)
	}

	// MARK: - Transport

	func call(sharing: Bool, action: String, scenario: String, body: String) async throws -> XElement {
		let envelope = """
			<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:soapenc="http://schemas.xmlsoap.org/soap/encoding/"><soap:Header><ABApplicationHeader xmlns="\(Self.ns)"><ApplicationId>\(Self.applicationID)</ApplicationId><IsMigration>false</IsMigration><PartnerScenario>\(scenario)</PartnerScenario></ABApplicationHeader><ABAuthHeader xmlns="\(Self.ns)"><ManagedGroupRequest>false</ManagedGroupRequest><TicketToken>\(ticket.xmlEscaped)</TicketToken></ABAuthHeader></soap:Header><soap:Body>\(body)</soap:Body></soap:Envelope>
			"""

		var req = URLRequest(url: sharing ? config.sharingServiceURL : config.abServiceURL)
		req.httpMethod = "POST"
		req.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
		req.setValue("\"\(Self.ns)/\(action)\"", forHTTPHeaderField: "SOAPAction")
		req.httpBody = Data(envelope.utf8)
		req.timeoutInterval = 30

		let (data, response) = try await session.data(for: req)
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		let root = try? XElement.parse(data)
		if let fault = root?.find("Fault") {
			throw ABError.fault(fault.value("faultstring") ?? fault.value("errorcode") ?? "SOAP fault")
		}
		guard (200..<300).contains(status), let root else { throw ABError.http(status) }
		return root
	}
}
