#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// MSNP11+ `CHL` challenge response (sent back as `QRY trid <productID> 32\r\n<hash>`).
///
/// The algorithm mixes an MD5 of challenge+key with a 31-bit modular hash of
/// challenge+productID, then XORs the two together.
public enum MSNPChallenge {
	/// WLM 8.1.0178 credentials, recovered from msnmsgr.exe (see docs/RE-FINDINGS.md).
	public static var productID = "PROD0114ES4Z%Q5W"
	public static var productKey = "PK}_A_0N_K%O?A9S"

	public static func response(to challenge: String, productID: String = productID, productKey: String = productKey) -> String {
		let digest = Array(Insecure.MD5.hash(data: Data((challenge + productKey).utf8)))
		let md5Parts = (0..<4).map { littleEndianUInt32(digest, at: $0 * 4) }
		let masked = md5Parts.map { UInt64($0 & 0x7FFF_FFFF) }

		var chl = Array((challenge + productID).utf8)
		while chl.count % 8 != 0 { chl.append(UInt8(ascii: "0")) }
		let chlParts = stride(from: 0, to: chl.count, by: 4).map { UInt64(littleEndianUInt32(chl, at: $0)) }

		let mod: UInt64 = 0x7FFF_FFFF
		var high: UInt64 = 0
		var low: UInt64 = 0
		for i in stride(from: 0, to: chlParts.count - 1, by: 2) {
			var temp = (chlParts[i] &* 0x0E79_A9C1) % mod
			temp = (masked[0] &* (temp &+ high) &+ masked[1]) % mod
			high = (chlParts[i + 1] &+ temp) % mod
			high = (masked[2] &* high &+ masked[3]) % mod
			low = low &+ high &+ temp
		}
		high = (high &+ masked[1]) % mod
		low = (low &+ masked[3]) % mod

		let key = [UInt32(truncatingIfNeeded: high), UInt32(truncatingIfNeeded: low)]
		var out = [UInt8]()
		for i in 0..<4 {
			let v = md5Parts[i] ^ key[i % 2]
			out += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
		}
		return out.map { String(format: "%02x", $0) }.joined()
	}

	private static func littleEndianUInt32(_ bytes: [UInt8], at i: Int) -> UInt32 {
		UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
	}
}
