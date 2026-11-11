import Foundation
import MSNKit

/// The file transfers of a Matrix session, for both clients. Matrix has no
/// offers to wait for: a sent file is uploaded and announced in a message, and
/// accepting a received one downloads it.
@MainActor
final class MatrixTransfers {
	/// Called with the conversation a transfer belongs to whenever it changes.
	var report: ((_ conversation: String, FileTransfer) -> Void)?
	private var entries: [String: (transfer: FileTransfer, conversation: String)] = [:]
	private var tasks: [String: Task<Void, Never>] = [:]

	func add(_ transfer: FileTransfer, in conversation: String) {
		entries[transfer.id] = (transfer, conversation)
		report?(conversation, transfer)
	}

	func state(of id: String) -> FileTransfer.State? {
		entries[id]?.transfer.state
	}

	/// Runs transfer `id`'s upload or download: it ends completed (at the URL
	/// `work` returns, if any), cancelled or failed.
	func run(_ id: String, _ work: @escaping () async throws -> URL?) {
		change(id) { $0.state = .transferring }
		tasks[id] = Task {
			var result: Result<URL?, Error>
			do { result = .success(try await work()) } catch { result = .failure(error) }
			if Task.isCancelled { result = .failure(CancellationError()) }
			self.tasks[id] = nil
			self.change(id) { t in
				switch result {
				case let .success(url):
					t.fileURL = url ?? t.fileURL
					t.transferred = t.size
					t.state = .completed
				case .failure(is CancellationError):
					t.state = .cancelled
					t.cancelledByMe = true
				case let .failure(error):
					t.state = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
				}
			}
		}
	}

	func decline(_ id: String) {
		guard state(of: id) == .offered else { return }
		change(id) { $0.state = .declined }
	}

	func cancel(_ id: String) {
		if let task = tasks[id] { return task.cancel() }
		guard state(of: id)?.isFinished == false else { return }
		change(id) { t in
			t.state = .cancelled
			t.cancelledByMe = true
		}
	}

	func reset() {
		for task in tasks.values { task.cancel() }
		tasks = [:]
		entries = [:]
	}

	private func change(_ id: String, _ body: (inout FileTransfer) -> Void) {
		guard var entry = entries[id] else { return }
		body(&entry.transfer)
		entries[id] = entry
		report?(entry.conversation, entry.transfer)
	}
}
