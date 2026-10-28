import XCTest
@testable import MSNKit

final class ProtocolTests: XCTestCase {
	// Challenge vectors come from re/scripts/wlm_challenge.py, a literal
	// translation of msnmsgr.exe FUN_004a0018/FUN_0049fcb8. Escargot's
	// gen_chal_response differs (XORs the masked MD5, always pads) but its QRY
	// check is disabled, so the binary's behaviour is the reference.

	func testChallengeMatchesDecompiledWLM81() {
		XCTAssertEqual(MSNPChallenge.response(to: "13038318816579321232"), "d29978c57727acabb46c60fc0166c5cb")
	}

	func testChallengeMatchesDecompiledWithMSN7Credentials() {
		let r = MSNPChallenge.response(to: "22210219642164014968", productID: "PROD0090YUAUV{B0", productKey: "YMM8C_H7KCQ2S_KL")
		XCTAssertEqual(r, "44646bb13d85766536143be3992d7774")
	}

	func testChallengePadsOnlyWhenUnaligned() {
		// challenge+productID = 32 bytes: WLM adds no '0' padding.
		XCTAssertEqual(MSNPChallenge.response(to: "1234567890123456"), "0d892417f5fa62c5f31ff562a1cc12f5")
	}

	// SSO vector produced by the Escargot server's own verification helpers
	// (front/msn/misc.py) inside devserver/, i.e. what the NS will accept.

	func testSSOResponseMatchesServer() throws {
		let blob = try MBICrypto.ssoResponse(
			binarySecret: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYX",
			nonce: "Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6MDE=",
			iv: [1, 2, 3, 4, 5, 6, 7, 8]
		)
		XCTAssertEqual(blob, "HAAAAAEAAAADZgAABIAAAAgAAAAUAAAASAAAAAECAwQFBgcIKUUxa5mD3w0m7O5S9GjISM3ArnL4464POzyNpbfH01NNQMKVG4bbAUxlvCFP6BIVkT/JQThTqHQWWp6ij9CGioB/uS5q9aJqNl3skXMadan9BNL0B7Dko6+xSl4=")
	}

	func testDecoderSplitsLinesAndPayloads() throws {
		var d = MSNPDecoder()
		d.append(Data("VER 1 MSNP15\r\nMSG Hotmail Hotmail 5\r\nhel".utf8))
		XCTAssertEqual(try d.next(), MSNPCommand("VER", ["1", "MSNP15"]))
		XCTAssertNil(try d.next(), "payload incomplete")
		d.append(Data("loQRY 10\r\nADL 7 OK\r\nNOT 3\r\nabcUBX bob@x.com 1 0\r\n".utf8))
		XCTAssertEqual(try d.next(), MSNPCommand("MSG", ["Hotmail", "Hotmail"], payload: Data("hello".utf8)))
		XCTAssertEqual(try d.next(), MSNPCommand("QRY", ["10"]))
		XCTAssertEqual(try d.next(), MSNPCommand("ADL", ["7", "OK"]))
		XCTAssertEqual(try d.next(), MSNPCommand("NOT", [], payload: Data("abc".utf8)))
		XCTAssertEqual(try d.next(), MSNPCommand("UBX", ["bob@x.com", "1"], payload: Data()))
		XCTAssertNil(try d.next())
	}

	func testTrIDExtraction() {
		XCTAssertEqual(MSNPCommand("USR", ["4", "OK", "a@b.c", "1", "0"]).trID, 4)
		XCTAssertEqual(MSNPCommand("911", ["4"]).errorCode, 911)
		XCTAssertNil(MSNPCommand("RNG", ["11752013", "1.2.3.4:1864"]).trID)
		XCTAssertNil(MSNPCommand("MSG", ["Hotmail", "Hotmail"]).trID)
	}

	func testEncodeAppendsPayloadLength() {
		let data = MSNPCommand("UUX", ["9"], payload: Data("<Data/>".utf8)).encoded()
		XCTAssertEqual(String(decoding: data, as: UTF8.self), "UUX 9 7\r\n<Data/>")
	}

	@MainActor
	func testADLGroupsByDomain() {
		let p = MessengerClient.adlPayloads([("bob@example.com", 3), ("carol@example.com", 1), ("dan@live.com", 4)], initial: true)
		XCTAssertEqual(p, [#"<ml l="1"><d n="example.com"><c n="bob" l="3" t="1"/><c n="carol" l="1" t="1"/></d><d n="live.com"><c n="dan" l="4" t="1"/></d></ml>"#])
		XCTAssertEqual(MessengerClient.adlPayloads([], initial: true), [#"<ml l="1"></ml>"#])
	}

	@MainActor
	func testADLSplitsLargeLists() {
		let entries = (0..<600).map { ("user\($0)@example.com", 3) }
		let payloads = MessengerClient.adlPayloads(entries, initial: false)
		XCTAssertGreaterThan(payloads.count, 1)
		for p in payloads {
			XCTAssertLessThanOrEqual(p.utf8.count, 7500)
			XCTAssertNoThrow(try XElement.parse(p))
		}
		XCTAssertEqual(payloads.joined().components(separatedBy: "<c ").count - 1, 600)
	}

	func testMIMERoundTripAndFormat() {
		var f = TextFormat()
		f.bold = true
		f.color = 0xFF8000
		let m = MIMEMessage.text("hi there", format: f)
		let parsed = MIMEMessage(parsing: m.encoded())
		XCTAssertEqual(parsed.contentType, "text/plain")
		XCTAssertEqual(parsed.bodyString, "hi there")
		let pf = TextFormat(header: parsed["X-MMS-IM-Format"]!)
		XCTAssertTrue(pf.bold)
		XCTAssertEqual(pf.color, 0xFF8000)
		XCTAssertTrue(parsed["X-MMS-IM-Format"]!.contains("CO=80ff"), "wire colour is BGR")
	}

	func testPersonalMessageAndMedia() {
		let xml = #"<Data><PSM>Hello &amp; welcome</PSM><CurrentMedia>\0Music\01\0{0} - {1}\0Song\0Band\0\0</CurrentMedia></Data>"#
		let info = PersonalInfo(xml: Data(xml.utf8))
		XCTAssertEqual(info.personalMessage, "Hello & welcome")
		XCTAssertEqual(info.currentMedia, "Song - Band")
	}

	func testPassportParsesTokensAndFaults() throws {
		let ok = """
		<S:Envelope xmlns:S="http://schemas.xmlsoap.org/soap/envelope/"><S:Header><psf:pp xmlns:psf="x"><psf:PUID>ABC</psf:PUID><psf:reqstatus>0x0</psf:reqstatus></psf:pp></S:Header><S:Body>
		<wst:RequestSecurityTokenResponseCollection xmlns:wst="t" xmlns:wsse="s" xmlns:wsp="p" xmlns:wsa="a">
		<wst:RequestSecurityTokenResponse><wsp:AppliesTo><wsa:EndpointReference><wsa:Address>messengerclear.live.com</wsa:Address></wsa:EndpointReference></wsp:AppliesTo>
		<wst:RequestedSecurityToken><wsse:BinarySecurityToken Id="Compact1">t=abc&amp;p=</wsse:BinarySecurityToken></wst:RequestedSecurityToken>
		<wst:RequestedProofToken><wst:BinarySecret>c2VjcmV0</wst:BinarySecret></wst:RequestedProofToken></wst:RequestSecurityTokenResponse>
		<wst:RequestSecurityTokenResponse><wsp:AppliesTo><wsa:EndpointReference><wsa:Address>contacts.msn.com</wsa:Address></wsa:EndpointReference></wsp:AppliesTo>
		<wst:RequestedSecurityToken><wsse:BinarySecurityToken Id="Compact2">t=def&amp;p=</wsse:BinarySecurityToken></wst:RequestedSecurityToken></wst:RequestSecurityTokenResponse>
		</wst:RequestSecurityTokenResponseCollection></S:Body></S:Envelope>
		"""
		let tokens = try PassportAuth.parse(Data(ok.utf8))
		XCTAssertEqual(tokens.messengerClear?.ticket, "t=abc&p=")
		XCTAssertEqual(tokens.messengerClear?.binarySecret, "c2VjcmV0")
		XCTAssertEqual(tokens.contacts?.ticket, "t=def&p=")
		XCTAssertEqual(tokens.puid, "ABC")

		let fault = #"<S:Envelope xmlns:S="s"><S:Body><S:Fault><faultcode>wsse:FailedAuthentication</faultcode></S:Fault></S:Body></S:Envelope>"#
		XCTAssertThrowsError(try PassportAuth.parse(Data(fault.utf8)))
	}

	func testAddressBookParsing() throws {
		let members = try XElement.parse("""
		<FindMembershipResponse><FindMembershipResult><Services><Service><Memberships>
		<Membership><MemberRole>Allow</MemberRole><Members><Member><PassportName>Bob@Example.com</PassportName></Member></Members></Membership>
		<Membership><MemberRole>Reverse</MemberRole><Members><Member><PassportName>bob@example.com</PassportName><DisplayName>Bobby</DisplayName></Member></Members></Membership>
		</Memberships><Info><Handle><Type>Messenger</Type></Handle></Info></Service></Services></FindMembershipResult></FindMembershipResponse>
		""")
		let ab = try XElement.parse("""
		<ABFindAllResponse><ABFindAllResult><groups><Group><groupId>g1</groupId><groupInfo><name>Friends</name></groupInfo></Group></groups>
		<contacts><Contact><contactId>c1</contactId><contactInfo><passportName>bob@example.com</passportName><displayName>Bob</displayName>
		<isMessengerUser>true</isMessengerUser><groupIds><guid>g1</guid></groupIds></contactInfo></Contact>
		<Contact><contactId>me</contactId><contactInfo><contactType>Me</contactType><displayName>Alice</displayName></contactInfo></Contact></contacts>
		</ABFindAllResult></ABFindAllResponse>
		""")
		var book = AddressBook()
		ABService.parseMemberships(members, into: &book)
		ABService.parseAddressBook(ab, into: &book)
		XCTAssertEqual(book.memberships["bob@example.com"], [.allow, .reverse])
		XCTAssertEqual(book.contacts, [ABContact(contactID: "c1", email: "bob@example.com", displayName: "Bob", isMessengerUser: true, groupIDs: ["g1"])])
		XCTAssertEqual(book.groups, [ABGroup(groupID: "g1", name: "Friends")])
		XCTAssertEqual(book.meDisplayName, "Alice")
	}
}

#if canImport(CommonCrypto)
import CommonCrypto

/// The pure-Swift 3DES (used on Linux) must match CommonCrypto byte for byte.
final class TripleDESTests: XCTestCase {
	func testMatchesCommonCrypto() throws {
		for len in [0, 1, 7, 8, 9, 64, 72, 100] {
			let key = (0..<24).map { _ in UInt8.random(in: 0...255) }
			let iv = (0..<8).map { _ in UInt8.random(in: 0...255) }
			let pt = (0..<len).map { _ in UInt8.random(in: 0...255) }
			let ours = TripleDES.encryptCBC(key: key, iv: iv, plaintext: pt)
			let theirs = try MBICrypto.tripleDESCBC(key: Data(key), iv: Data(iv), plaintext: Data(pt))
			XCTAssertEqual(Data(ours), theirs, "length \(len)")
		}
	}
}
#endif
