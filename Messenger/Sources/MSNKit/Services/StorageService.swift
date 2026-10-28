import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Roaming profile (display name + personal message) in the Storage service,
/// replacing abssm.dll's GetProfile/UpdateProfile (templates at abssm.dll
/// .rdata 0x4d3c4 and 0x51f14). `UUX`/`PRP` on the NS only change the live
/// session; this is what makes the values survive a sign-out.
public struct StorageService {
	public struct Profile: Equatable {
		public var resourceID: String?
		public var displayName: String?
		public var personalMessage: String?
	}

	static let ns = "http://www.msn.com/webservices/storage/w10"
	/// Not present as plain text in msnmsgr.exe; the Escargot server does not check it.
	static let applicationID = "Messenger Client 8.1"

	public let config: ServerConfig
	public let ticket: String
	public let session: URLSession

	public init(config: ServerConfig, ticket: String, session: URLSession = .shared) {
		self.config = config
		self.ticket = ticket
		self.session = session
	}

	public func getProfile(cid: String) async throws -> Profile {
		let root = try await call(action: "GetProfile", scenario: "Initial", body: """
			<GetProfile xmlns="\(Self.ns)"><profileHandle><Alias><Name>\(cid.xmlEscaped)</Name><NameSpace>MyCidStuff</NameSpace>\
			</Alias><RelationshipName>MyProfile</RelationshipName></profileHandle><profileAttributes><ResourceID>true</ResourceID>\
			<DateModified>true</DateModified><ExpressionProfileAttributes><ResourceID>true</ResourceID><DateModified>true</DateModified>\
			<DisplayName>true</DisplayName><DisplayNameLastModified>true</DisplayNameLastModified><PersonalStatus>true</PersonalStatus>\
			<PersonalStatusLastModified>true</PersonalStatusLastModified><StaticUserTilePublicURL>true</StaticUserTilePublicURL>\
			<Photo>true</Photo><Flags>true</Flags></ExpressionProfileAttributes></profileAttributes></GetProfile>
			""")
		return Self.parseProfile(root)
	}

	static func parseProfile(_ root: XElement) -> Profile {
		let result = root.find("GetProfileResult")
		let expression = result?.child("ExpressionProfile")
		return Profile(
			resourceID: result?.child("ResourceID")?.text.trimmingCharacters(in: .whitespaces),
			displayName: expression?.value("DisplayName"),
			personalMessage: expression?.value("PersonalStatus")
		)
	}

	/// Saves the roaming name and/or message; an empty message deletes it.
	public func updateProfile(resourceID: String, displayName: String? = nil, personalMessage: String? = nil) async throws {
		var fields = ""
		if let displayName { fields += "<DisplayName>\(displayName.xmlEscaped)</DisplayName>" }
		if let personalMessage, !personalMessage.isEmpty { fields += "<PersonalStatus>\(personalMessage.xmlEscaped)</PersonalStatus>" }
		var body = "<UpdateProfile xmlns=\"\(Self.ns)\"><profile><ResourceID>\(resourceID.xmlEscaped)</ResourceID>"
		body += "<ExpressionProfile><FreeText>Update</FreeText>\(fields)</ExpressionProfile></profile>"
		if personalMessage?.isEmpty == true {
			body += "<profileAttributesToDelete><ExpressionProfileAttributes><PersonalStatus>true</PersonalStatus>"
			body += "</ExpressionProfileAttributes></profileAttributesToDelete>"
		}
		body += "</UpdateProfile>"
		_ = try await call(action: "UpdateProfile", scenario: "RoamingIdentityChanged", body: body)
	}

	func call(action: String, scenario: String, body: String) async throws -> XElement {
		let envelope = """
			<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" \
			xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" \
			xmlns:soapenc="http://schemas.xmlsoap.org/soap/encoding/"><soap:Header>\
			<StorageApplicationHeader xmlns="\(Self.ns)"><ApplicationID>\(Self.applicationID)</ApplicationID>\
			<Scenario>\(scenario)</Scenario></StorageApplicationHeader>\
			<StorageUserHeader xmlns="\(Self.ns)"><Puid>0</Puid><TicketToken>\(ticket.xmlEscaped)</TicketToken></StorageUserHeader>\
			</soap:Header><soap:Body>\(body)</soap:Body></soap:Envelope>
			"""
		var req = URLRequest(url: config.storageServiceURL)
		req.httpMethod = "POST"
		req.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
		req.setValue("\"\(Self.ns)/\(action)\"", forHTTPHeaderField: "SOAPAction")
		req.httpBody = Data(envelope.utf8)
		req.timeoutInterval = 30

		let (data, response) = try await session.data(for: req)
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		let root = try? XElement.parse(data)
		if let fault = root?.find("Fault") {
			throw ABError.fault(fault.value("faultstring") ?? "storage SOAP fault")
		}
		guard (200..<300).contains(status), let root else { throw ABError.http(status) }
		return root
	}
}
