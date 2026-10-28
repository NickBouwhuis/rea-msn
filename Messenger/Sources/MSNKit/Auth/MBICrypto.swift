#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// MSNP15 SSO proof: answers `USR trid SSO S MBI_KEY_OLD <nonce>` using the
/// BinarySecret returned for `messengerclear.live.com`.
///
/// Blob layout (little-endian header, as built by msnmsgr.exe and checked by
/// the Escargot NS):
///   uStructHeaderSize=28, uCryptMode=1 (CBC), uCipherType=0x6603 (3DES),
///   uHashType=0x8004 (SHA1), uIVLen=8, uHashLen=20, uCipherLen=72,
///   then IV (8) + HMAC-SHA1 (20) + 3DES-CBC ciphertext (72).
public enum MBICrypto {
	public static func ssoResponse(binarySecret: String, nonce: String, iv: [UInt8]? = nil) throws -> String {
		guard let key1 = Data(base64Encoded: binarySecret) else {
			throw MSNPError.unexpected("BinarySecret is not base64")
		}
		let key2 = deriveKey(key1, "WS-SecureConversationSESSION KEY HASH")
		let key3 = deriveKey(key1, "WS-SecureConversationSESSION KEY ENCRYPTION")
		let nonceBytes = Data(nonce.utf8)

		let hash = Data(HMAC<Insecure.SHA1>.authenticationCode(for: nonceBytes, using: SymmetricKey(data: key2)))
		let ivBytes = iv ?? (0..<8).map { _ in UInt8.random(in: 0...255) }
		let cipher = try tripleDESCBC(key: key3, iv: Data(ivBytes), plaintext: nonceBytes)

		var blob = Data()
		for v: UInt32 in [28, 1, 0x6603, 0x8004, 8, 20, UInt32(cipher.count)] {
			withUnsafeBytes(of: v.littleEndian) { blob.append(contentsOf: $0) }
		}
		blob.append(contentsOf: ivBytes)
		blob.append(hash)
		blob.append(cipher)
		return blob.base64EncodedString()
	}

	/// WS-SecureConversation P_SHA1-style derivation, truncated to a 24-byte 3DES key.
	static func deriveKey(_ key: Data, _ magic: String) -> Data {
		let k = SymmetricKey(data: key)
		let m = Data(magic.utf8)
		let hash1 = Data(HMAC<Insecure.SHA1>.authenticationCode(for: m, using: k))
		let hash2 = Data(HMAC<Insecure.SHA1>.authenticationCode(for: hash1 + m, using: k))
		let hash3 = Data(HMAC<Insecure.SHA1>.authenticationCode(for: hash1, using: k))
		let hash4 = Data(HMAC<Insecure.SHA1>.authenticationCode(for: hash3 + m, using: k))
		return hash2.prefix(20) + hash4.prefix(4)
	}

	/// 3DES-CBC with PKCS#7 padding. A block-aligned nonce gains a full 8-byte
	/// 0x08 pad block, matching what the NS recomputes.
	static func tripleDESCBC(key: Data, iv: Data, plaintext: Data) throws -> Data {
		#if canImport(CommonCrypto)
		var out = Data(count: plaintext.count + kCCBlockSize3DES)
		var moved = 0
		let outCapacity = out.count
		let status = out.withUnsafeMutableBytes { outPtr in
			key.withUnsafeBytes { keyPtr in
				iv.withUnsafeBytes { ivPtr in
					plaintext.withUnsafeBytes { inPtr in
						CCCrypt(
							CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithm3DES), CCOptions(kCCOptionPKCS7Padding),
							keyPtr.baseAddress, kCCKeySize3DES, ivPtr.baseAddress,
							inPtr.baseAddress, plaintext.count,
							outPtr.baseAddress, outCapacity, &moved
						)
					}
				}
			}
		}
		guard status == kCCSuccess else { throw MSNPError.unexpected("3DES failed (\(status))") }
		return out.prefix(moved)
		#else
		return Data(TripleDES.encryptCBC(key: [UInt8](key), iv: [UInt8](iv), plaintext: [UInt8](plaintext)))
		#endif
	}
}
