import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MSNKit
@testable import MatrixKit

final class MatrixKitTests: XCTestCase {
	func testUserIDs() {
		XCTAssertEqual(MatrixID.serverName(of: "@alice:matrix.org"), "matrix.org")
		XCTAssertEqual(MatrixID.serverName(of: "@alice:localhost:8008"), "localhost:8008")
		XCTAssertEqual(MatrixID.localpart(of: "@alice:localhost:8008"), "alice")
		XCTAssertFalse(MatrixID.isUserID("alice@example.com"))
		XCTAssertFalse(MatrixID.isUserID("@alice"))
		XCTAssertFalse(MatrixID.isUserID("@:matrix.org"))
		XCTAssertFalse(MatrixID.isUserID("@al ice:matrix.org"))
	}

	func testPathSegmentsAreEscaped() {
		XCTAssertEqual(MatrixAPI.segment("@alice:localhost"), "%40alice%3Alocalhost")
		XCTAssertEqual(MatrixAPI.segment("!AbC/d+e:server"), "%21AbC%2Fd%2Be%3Aserver")
	}

	func testJSONRoundTrip() throws {
		let raw = #"{"a":[1,2.5,"x",true,null],"b":{"c":"d"},"n":1700000000000}"#
		let json = try JSON(data: Data(raw.utf8))
		XCTAssertEqual(json["a"].array.count, 5)
		XCTAssertEqual(json["a"].array[3].bool, true)
		XCTAssertEqual(json["b"]["c"].string, "d")
		XCTAssertEqual(json["n"].int, 1_700_000_000_000)
		XCTAssertTrue(json["missing"]["deeper"].isNull)
		XCTAssertEqual(try JSON(data: json.encoded()), json)
	}

	func testPresenceMapping() {
		XCTAssertEqual(Presence.online.matrixState, "online")
		XCTAssertEqual(Presence.busy.matrixState, "unavailable")
		XCTAssertEqual(Presence.appearOffline.matrixState, "offline")
		XCTAssertEqual(Presence(matrix: "online"), .online)
		XCTAssertEqual(Presence(matrix: "unavailable"), .away)
		XCTAssertEqual(Presence(matrix: "org.matrix.msc3026.busy"), .busy)
		XCTAssertEqual(Presence(matrix: nil), .offline)
	}

	func testPlainMessageHasNoHTML() {
		let content = MatrixMessage.content(text: "hi <there>", format: TextFormat())
		XCTAssertEqual(content["msgtype"].string, "m.text")
		XCTAssertEqual(content["body"].string, "hi <there>")
		XCTAssertTrue(content["formatted_body"].isNull)
		XCTAssertEqual(MatrixMessage.format(of: content), TextFormat())
	}

	func testFormattedMessageRoundTrips() {
		var format = TextFormat()
		format.fontName = "Comic Sans MS"
		format.bold = true
		format.italic = true
		format.color = 0xFF0000
		let content = MatrixMessage.content(text: "a & b\nc", format: format)
		XCTAssertEqual(content["format"].string, "org.matrix.custom.html")
		XCTAssertEqual(content["formatted_body"].string,
		               ##"<font data-mx-color="#ff0000" color="#ff0000"><b><i>a &amp; b<br>c</i></b></font>"##)
		XCTAssertEqual(MatrixMessage.format(of: content), format)
	}

	func testNudge() {
		let nudge = MatrixMessage.nudge()
		XCTAssertTrue(MatrixMessage.isNudge(nudge))
		XCTAssertEqual(nudge["msgtype"].string, "m.emote")
		XCTAssertFalse(MatrixMessage.isNudge(MatrixMessage.content(text: "hi", format: TextFormat())))
	}

	func testIncomingText() {
		let emote: JSON = ["msgtype": "m.emote", "body": "waves"]
		XCTAssertEqual(MatrixMessage.text(of: emote, senderName: "Bob"), "* Bob waves")
		let image: JSON = ["msgtype": "m.image", "body": "cat.png"]
		XCTAssertEqual(MatrixMessage.text(of: image, senderName: "Bob"), "[Picture: cat.png]")
		let reply: JSON = [
			"msgtype": "m.text",
			"body": "> <@alice:localhost> are you there?\n> second line\n\nyes!",
			"m.relates_to": ["m.in_reply_to": ["event_id": "$abc"]],
		]
		XCTAssertEqual(MatrixMessage.text(of: reply, senderName: "Bob"), "yes!")
		let quote: JSON = ["msgtype": "m.text", "body": "> not a reply\n\nkeep it"]
		XCTAssertEqual(MatrixMessage.text(of: quote, senderName: "Bob"), "> not a reply\n\nkeep it")
	}

	@MainActor
	func testDeviceIDIsStablePerAccountAndMachine() {
		let a = MatrixClient.deviceID(for: "@alice:localhost", host: "mac")
		XCTAssertEqual(a, MatrixClient.deviceID(for: "@alice:localhost", host: "mac"))
		XCTAssertNotEqual(a, MatrixClient.deviceID(for: "@bob:localhost", host: "mac"))
		XCTAssertNotEqual(a, MatrixClient.deviceID(for: "@alice:localhost", host: "pc"))
		XCTAssertEqual(a.count, 10)
		XCTAssertTrue(a.hasPrefix("WLM"))
		XCTAssertTrue(a.allSatisfy { $0.isUppercase && $0.isASCII })
	}

	func testSSORedirectURL() {
		let api = MatrixAPI(baseURL: URL(string: "https://matrix.example.org")!)
		let url = api.ssoRedirectURL(returningTo: URL(string: "http://127.0.0.1:5000/callback/abc")!)
		XCTAssertEqual(url.absoluteString,
		               "https://matrix.example.org/_matrix/client/v3/login/sso/redirect?redirectUrl=http://127.0.0.1:5000/callback/abc")
	}

	func testLoopbackRedirectReturnsTheLoginToken() async throws {
		let redirect = try LoopbackRedirect()
		XCTAssertEqual(redirect.callbackURL.host, "127.0.0.1")
		async let token = redirect.wait(forQueryItem: "loginToken", page: "signed in")

		// Another path on the same port (a guessed callback) gets nothing.
		var wrong = URLComponents(url: redirect.callbackURL, resolvingAgainstBaseURL: false)!
		wrong.path = "/callback/guess"
		wrong.query = "loginToken=evil"
		let (_, miss) = try await URLSession.shared.data(from: wrong.url!)
		XCTAssertEqual((miss as? HTTPURLResponse)?.statusCode, 404)

		var right = URLComponents(url: redirect.callbackURL, resolvingAgainstBaseURL: false)!
		right.percentEncodedQuery = "loginToken=syt_abc%2B1"
		let (body, hit) = try await URLSession.shared.data(from: right.url!)
		XCTAssertEqual((hit as? HTTPURLResponse)?.statusCode, 200)
		XCTAssertEqual(String(decoding: body, as: UTF8.self), "signed in")
		let value = try await token
		XCTAssertEqual(value, "syt_abc+1")
	}

	func testLoopbackRedirectStopsOnCancel() async throws {
		let redirect = try LoopbackRedirect()
		let waiting = Task { try await redirect.wait(forQueryItem: "loginToken", page: "") }
		try await Task.sleep(nanoseconds: 100_000_000)
		redirect.stop()
		do {
			_ = try await waiting.value
			XCTFail("wait returned after stop")
		} catch is CancellationError {}
	}

	func testSyncFilterAsksOnlyForWhatTheClientUses() {
		let filter = MatrixClient.filter(timelineLimit: 1)
		XCTAssertEqual(filter["room"]["timeline"]["limit"].int, 1)
		XCTAssertEqual(filter["room"]["ephemeral"]["types"], ["m.typing"])
		XCTAssertEqual(filter["account_data"]["types"], ["m.direct", "m.ignored_user_list"])
	}
}
