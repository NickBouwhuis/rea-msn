import Foundation

/// Where to connect. WLM hard-codes Microsoft hostnames and Escargot's
/// switcher DLL rewrites them at the socket/WinINet layer (see
/// docs/RE-FINDINGS.md §2); a native port simply targets the server directly,
/// keeping Microsoft's original URL paths.
public struct ServerConfig: Codable, Equatable, Hashable {
	/// Notification Server host (was messenger.hotmail.com:1863).
	public var nsHost: String
	public var nsPort: UInt16
	/// Base URL for Passport RST (was https://login.live.com).
	public var loginBaseURL: URL
	/// Base URL for ABCH SOAP (was https://omega.contacts.msn.com).
	public var contactsBaseURL: URL

	public init(nsHost: String, nsPort: UInt16 = 1863, loginBaseURL: URL, contactsBaseURL: URL) {
		self.nsHost = nsHost
		self.nsPort = nsPort
		self.loginBaseURL = loginBaseURL
		self.contactsBaseURL = contactsBaseURL
	}

	/// The value the NINA & Escargot Patcher writes into msnmsgr.exe-escargot.ini.
	public static let escargot = ServerConfig(
		nsHost: "msnmsgr.escargot.chat",
		loginBaseURL: URL(string: "https://msnmsgr.escargot.chat")!,
		contactsBaseURL: URL(string: "https://msnmsgr.escargot.chat")!
	)

	/// The Dockerized dev server in devserver/.
	public static let localDev = ServerConfig(
		nsHost: "127.0.0.1",
		loginBaseURL: URL(string: "http://127.0.0.1:8081")!,
		contactsBaseURL: URL(string: "http://127.0.0.1:8081")!
	)

	public var rstURL: URL { loginBaseURL.appendingPathComponent("RST.srf") }
	public var abServiceURL: URL { contactsBaseURL.appendingPathComponent("abservice/abservice.asmx") }
	public var sharingServiceURL: URL { contactsBaseURL.appendingPathComponent("abservice/SharingService.asmx") }
	/// Was https://tkrdr.storage.msn.com/storageservice/SchematizedStore.asmx.
	public var storageServiceURL: URL { contactsBaseURL.appendingPathComponent("storageservice/SchematizedStore.asmx") }
}
