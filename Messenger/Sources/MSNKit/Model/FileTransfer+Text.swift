import Foundation

extension FileTransfer {
	/// "12 KB", "3.4 MB", as the conversation window shows sizes.
	public var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }

	/// WLM's conversation text for this transfer, from msnmsgr's invitation
	/// strings in msgslang.dll (2043–2051, 2101–2104, 2234). `string` looks one
	/// up (falling back to the English given) so each app can use its skin.
	public func text(peerName: String, string: (Int, String) -> String) -> String {
		let activity = "the transfer of \"\(name)\" (\(sizeText))"
		func fill(_ id: Int, _ english: String) -> String {
			string(id, english)
				.replacingOccurrences(of: " (Alt+C)", with: "").replacingOccurrences(of: " (Alt+D)", with: "")
				.replacingOccurrences(of: " (Alt+Q)", with: "")
				.replacingOccurrences(of: "%1", with: peerName).replacingOccurrences(of: "%2", with: activity)
				.replacingOccurrences(of: "%3", with: string(2052, "Accept")).replacingOccurrences(of: "%4", with: string(2053, "Decline"))
				.replacingOccurrences(of: "%5", with: string(2054, "Cancel"))
		}
		switch (state, incoming) {
		case (.offered, _):
			return fill(2043, "%1 is inviting you to start %2. Do you want to %3 (Alt+C) or %4 (Alt+D) the invitation?")
		case (.waiting, _):
			return fill(2044, "You have invited %1 to start %2. Please wait for a response or %5 (Alt+Q) the pending invitation.")
		case (.transferring, _):
			let left = (size - min(transferred, size) + 1023) / 1024
			return "\"\(name)\" (\(sizeText)) – " + string(2234, "Transfer: %1!u! KB left").replacingOccurrences(of: "%1!u!", with: "\(left)")
		case (.completed, true):
			return string(2102, "You have successfully received %2 from %1.")
				.replacingOccurrences(of: "%1", with: peerName).replacingOccurrences(of: "%2", with: "\"\(name)\"")
		case (.completed, false):
			return string(2101, "Transfer of \"%2\" is complete.").replacingOccurrences(of: "%2", with: name)
		case (.declined, true):
			return fill(2051, "You have declined the invitation to start %2.")
		case (.declined, false):
			return fill(2047, "%1 has declined your invitation to start %2.")
		case (.cancelled, _):
			return cancelledByMe
				? fill(2050, "You have canceled your invitation to start %2.")
				: fill(2046, "%1 has canceled the invitation to start %2.")
		case (.failed, true):
			return string(2104, "You have failed to receive file \"%2\" from %1.")
				.replacingOccurrences(of: "%1", with: peerName).replacingOccurrences(of: "%2", with: name)
		case (.failed, false):
			return string(2103, "Sending of \"%2\" to %1 has failed.")
				.replacingOccurrences(of: "%1", with: peerName).replacingOccurrences(of: "%2", with: name)
		}
	}
}
