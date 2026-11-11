#if canImport(MatrixRustSDK)
import Foundation
import MatrixRustSDK
#if canImport(Security)
import Security
#endif

/// A signed-in Matrix session on this machine: the SDK's tokens, plus where
/// its local store lives and the passphrase that encrypts it. Keeping the
/// session (rather than the password) is what keeps this device, and with it
/// the encryption keys and its verification, across launches.
public struct StoredMatrixSession: Codable, Sendable {
	public var userID: String
	public var deviceID: String
	public var homeserverURL: String
	public var accessToken: String
	public var refreshToken: String?
	public var oauthData: String?
	public var slidingSync: Bool
	/// Folder for this session's SQLite stores (named per session).
	public var storeName: String
	public var storePassphrase: String

	init(_ session: Session, storeName: String, storePassphrase: String) {
		userID = session.userId
		deviceID = session.deviceId
		homeserverURL = session.homeserverUrl
		accessToken = session.accessToken
		refreshToken = session.refreshToken
		oauthData = session.oauthData
		slidingSync = session.slidingSyncVersion == .native
		self.storeName = storeName
		self.storePassphrase = storePassphrase
	}

	var session: Session {
		Session(accessToken: accessToken, refreshToken: refreshToken, userId: userID, deviceId: deviceID,
		        homeserverUrl: homeserverURL, oauthData: oauthData, slidingSyncVersion: slidingSync ? .native : .none)
	}

	/// The same session with tokens the SDK refreshed.
	func updating(_ session: Session) -> StoredMatrixSession {
		StoredMatrixSession(session, storeName: storeName, storePassphrase: storePassphrase)
	}
}

public protocol MatrixSessionStore: AnyObject, Sendable {
	func load(_ userID: String) -> StoredMatrixSession?
	func save(_ session: StoredMatrixSession)
	func delete(_ userID: String)
}

#if canImport(Security)
/// Sessions in the login Keychain (one generic-password item per account).
public final class KeychainMatrixSessionStore: MatrixSessionStore, @unchecked Sendable {
	private let service: String

	public init(service: String = "MessengerMac.Matrix") {
		self.service = service
	}

	private func query(_ userID: String) -> [String: Any] {
		[kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: userID]
	}

	public func load(_ userID: String) -> StoredMatrixSession? {
		var q = query(userID)
		q[kSecReturnData as String] = true
		q[kSecMatchLimit as String] = kSecMatchLimitOne
		var item: CFTypeRef?
		guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
		return try? JSONDecoder().decode(StoredMatrixSession.self, from: data)
	}

	public func save(_ session: StoredMatrixSession) {
		guard let data = try? JSONEncoder().encode(session) else { return }
		let q = query(session.userID)
		if SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
			var add = q
			add[kSecValueData as String] = data
			add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
			SecItemAdd(add as CFDictionary, nil)
		}
	}

	public func delete(_ userID: String) {
		SecItemDelete(query(userID) as CFDictionary)
	}
}
#endif

/// Sessions in a folder only the user can read, a file per account (Linux).
/// shortcut: a private file, not the desktop's keyring; move to libsecret
/// (as the GTK app's remembered passwords are) if other local users or
/// backups of the home folder are a concern.
public final class FileMatrixSessionStore: MatrixSessionStore, @unchecked Sendable {
	private let directory: URL

	public init(directory: URL) {
		self.directory = directory
	}

	private func file(_ userID: String) -> URL {
		directory.appendingPathComponent(MatrixAPI.segment(userID) + ".json")
	}

	public func load(_ userID: String) -> StoredMatrixSession? {
		(try? Data(contentsOf: file(userID))).flatMap { try? JSONDecoder().decode(StoredMatrixSession.self, from: $0) }
	}

	public func save(_ session: StoredMatrixSession) {
		guard let data = try? JSONEncoder().encode(session) else { return }
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		let path = file(session.userID).path
		// Created private, then filled: never readable by others, even briefly.
		if !FileManager.default.fileExists(atPath: path) {
			FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
		}
		try? data.write(to: URL(fileURLWithPath: path))
	}

	public func delete(_ userID: String) {
		try? FileManager.default.removeItem(at: file(userID))
	}
}

/// Sessions for this process only (msnctl, tests): every run is a new device.
public final class MemoryMatrixSessionStore: MatrixSessionStore, @unchecked Sendable {
	private var sessions: [String: StoredMatrixSession] = [:]
	private let lock = NSLock()

	public init() {}

	public func load(_ userID: String) -> StoredMatrixSession? {
		lock.lock()
		defer { lock.unlock() }
		return sessions[userID]
	}

	public func save(_ session: StoredMatrixSession) {
		lock.lock()
		defer { lock.unlock() }
		sessions[session.userID] = session
	}

	public func delete(_ userID: String) {
		lock.lock()
		defer { lock.unlock() }
		sessions[userID] = nil
	}
}
#endif
