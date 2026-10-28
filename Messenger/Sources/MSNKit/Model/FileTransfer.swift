import Foundation

/// A file sent or received through the switchboard (MSNSLP file transfer).
public struct FileTransfer: Identifiable, Equatable {
	public enum State: Equatable {
		/// Incoming, waiting for us to accept or decline.
		case offered
		/// Outgoing, waiting for the contact to accept.
		case waiting
		case transferring
		case completed
		case declined
		case cancelled
		case failed(String)

		public var isFinished: Bool {
			switch self {
			case .offered, .waiting, .transferring: return false
			default: return true
			}
		}
	}

	public let id: String
	public let peer: String
	public let name: String
	public let size: UInt64
	public let incoming: Bool
	public var state: State
	public var transferred: UInt64 = 0
	/// Where the file is (outgoing) or was saved (incoming, once accepted).
	public var fileURL: URL?
	/// For `.cancelled`: whether we cancelled it (rather than the contact).
	public var cancelledByMe = false

	public var progress: Double { size == 0 ? 1 : Double(transferred) / Double(size) }
}
