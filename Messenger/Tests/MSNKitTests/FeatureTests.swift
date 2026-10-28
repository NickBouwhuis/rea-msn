import XCTest
@testable import MSNKit

/// Wire formats behind group chats, offline messages, display pictures, file
/// transfer and winks. The end-to-end runs (msnctl e2e) cover the flows.
final class FeatureTests: XCTestCase {
	func testMSNObjectSHA1CMatchesTheDocumentedExample() throws {
		// The msnobj example from the MSN protocol wiki (MSNC display pictures).
		let raw = """
			<msnobj Creator="buddy1@hotmail.com" Size="24539" Type="3" Location="TFR2C.tmp" Friendly="AAA=" \
			SHA1D="trC8SlFx2sWQxZMIBAWSEnXc8oQ=" SHA1C="U32o6bosZzluJq82eAtMpx5dIEI="/>
			"""
		let object = try XCTUnwrap(MSNObject(raw))
		XCTAssertEqual(object.kind, .displayPicture)
		XCTAssertEqual(object.size, 24539)
		XCTAssertEqual(object.computedSHA1C, object.sha1c)
		// URL-encoded, as it comes in NLN, and echoed back verbatim.
		let encoded = try XCTUnwrap(MSNObject(raw.msnpURLEncoded))
		XCTAssertEqual(encoded.xml, raw)
	}

	func testOwnMSNObjectDescribesItsData() {
		let data = Data((0..<500).map { UInt8($0 & 0xFF) })
		let object = MSNObject(creator: "alice@example.com", data: data, kind: .displayPicture)
		XCTAssertTrue(object.matches(data))
		XCTAssertFalse(object.matches(data.dropLast()))
		XCTAssertEqual(MSNObject(object.xml)?.sha1d, object.sha1d)
		XCTAssertEqual(object.sha1c, object.computedSHA1C)
	}

	func testP2PHeaderRoundTrip() {
		var h = P2PHeader()
		h.sessionID = 0x1234_5678
		h.identifier = 42
		h.offset = 1202
		h.totalSize = 1 << 33
		h.length = 1202
		h.flags = P2PFlags.fileData
		h.ackIdentifier = 7
		h.ackUniqueID = 8
		h.ackDataSize = 9
		XCTAssertEqual(h.data.count, 48)
		XCTAssertEqual(P2PHeader(h.data), h)
		// Little-endian on the wire.
		XCTAssertEqual([UInt8](h.data.prefix(4)), [0x78, 0x56, 0x34, 0x12])
	}

	func testP2PPacketKeepsPayloadAndBigEndianFooter() throws {
		var h = P2PHeader()
		h.length = 3
		h.totalSize = 3
		let mime = P2PPacket(header: h, payload: Data([1, 2, 3]), footer: P2PApp.file).mime(to: "bob@example.com")
		XCTAssertEqual(mime["P2P-Dest"], "bob@example.com")
		XCTAssertEqual([UInt8](mime.body.suffix(4)), [0, 0, 0, 2])
		let parsed = try XCTUnwrap(P2PPacket(MIMEMessage(parsing: mime.encoded()).body))
		XCTAssertEqual(parsed.payload, Data([1, 2, 3]))
		XCTAssertEqual(parsed.footer, P2PApp.file)
	}

	func testSLPInviteRoundTrip() throws {
		let wire = SLPMessage.make("INVITE MSNMSGR:bob@example.com MSNSLP/1.0", to: "bob@example.com", from: "alice@example.com",
		                           branch: "{B}", cseq: 0, callID: "{C}", contentType: "application/x-msnmsgr-sessionreqbody",
		                           body: "EUF-GUID: \(SLPMessage.fileGUID)\r\nSessionID: 99\r\nAppID: 2\r\n\r\n")
		XCTAssertEqual(wire.last, 0)
		let m = try XCTUnwrap(SLPMessage(wire))
		XCTAssertEqual(m.method, "INVITE")
		XCTAssertEqual(m.callID, "{C}")
		XCTAssertEqual(m.branch, "{B}")
		XCTAssertEqual(m.field("SessionID"), "99")
		XCTAssertEqual(m.field("EUF-GUID"), SLPMessage.fileGUID)
		// Content-Length counts the body including its NUL.
		let body = "EUF-GUID: \(SLPMessage.fileGUID)\r\nSessionID: 99\r\nAppID: 2\r\n\r\n"
		XCTAssertEqual(m["Content-Length"], String(body.utf8.count + 1))
		XCTAssertEqual(SLPMessage(Data("MSNSLP/1.0 603 Decline\r\nCall-ID: {C}\r\n\r\n".utf8))?.status, 603)
	}

	func testFileContextIsWLM81Version2() throws {
		let context = FileContext.encode(name: "Vakantie foto's ☀️.jpg", size: 5_000_000_000)
		XCTAssertEqual(context.count, 574)
		let decoded = try XCTUnwrap(FileContext.decode(context))
		XCTAssertEqual(decoded.name, "Vakantie foto's ☀️.jpg")
		XCTAssertEqual(decoded.size, 5_000_000_000)
		XCTAssertEqual([UInt8](context.suffix(4)), [0xFF, 0xFF, 0xFF, 0xFF])
	}

	func testCabinetRoundTripStoredAndMSZIP() throws {
		let big = Data((0..<100_000).map { UInt8(($0 * 7) & 0xFF) })
		for compress in [false, true] {
			let cab = Cabinet.make([("content.xml", Data("<package/>".utf8)), ("big.bin", big)], compress: compress)
			let files = try Cabinet.files(in: cab)
			XCTAssertEqual(files["content.xml"], Data("<package/>".utf8))
			XCTAssertEqual(files["big.bin"], big, "compress: \(compress)")
		}
	}

	func testWinkThumbnailComesFromContentXML() {
		let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
		let cab = Wink.make(name: "Hi", thumbnail: png, animation: Data(repeating: 9, count: 4000))
		XCTAssertEqual(Wink.thumbnail(fromCabinet: cab), png)
	}

	func testMailDataListsOfflineMessages() throws {
		let md = """
			<MD><E><I>0</I><IU>0</IU><O>0</O><OU>0</OU></E><Q><QTM>409600</QTM><QNM>204800</QNM></Q>\
			<M><T>11</T><S>6</S><RT>2026-10-28T14:20:09.000Z</RT><RS>0</RS><SZ>900</SZ><E>Alice@Example.com</E>\
			<I>1ab2</I><F>00000000-0000-0000-0000-000000000009</F><N>=?utf-8?B?QWxpY2Ug4piV?=</N></M></MD>
			"""
		let list = try XCTUnwrap(OfflineMessageService.parseMailData(md))
		XCTAssertEqual(list.count, 1)
		XCTAssertEqual(list[0].from, "alice@example.com")
		XCTAssertEqual(list[0].id, "1ab2")
		XCTAssertEqual(list[0].displayName, "Alice ☕")
		XCTAssertNotNil(list[0].sent)
		XCTAssertNil(OfflineMessageService.parseMailData("too-large"))
	}

	func testOfflineMessageBodyIsDecoded() {
		let raw = "From: =?utf-8?B?QWxpY2U=?= <alice@example.com>\r\nTo: bob@example.com\r\nDate: 28 Oct 2026 07:20:09 -0800\r\n"
			+ "Content-Transfer-Encoding: base64\r\n\r\n" + Data("Hoi Bob, tot morgen! (Y)".utf8).base64EncodedString()
		let m = OfflineMessageService.parseMessage(raw, id: "x")
		XCTAssertEqual(m.from, "alice@example.com")
		XCTAssertEqual(m.displayName, "Alice")
		XCTAssertEqual(m.text, "Hoi Bob, tot morgen! (Y)")
		XCTAssertNotNil(m.sent)
		XCTAssertEqual(OfflineMessageService.decodeWord("=?utf-8?Q?Caf=C3=A9_au_lait?="), "Café au lait")
	}
}
