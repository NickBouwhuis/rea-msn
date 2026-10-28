import Foundation

/// MSNSLP sessions over P2P v1, carried by switchboards: fetching and serving
/// msnobjs (display pictures, winks) and sending and receiving files. Follows
/// WLM 8.1's message flow as libpurple's MSN plugin interoperated with it:
/// every complete message except an ACK is acknowledged, and direct
/// connections are declined ("Listening: false"), so data always goes through
/// the switchboard.
@MainActor
final class P2PManager {
	/// Sends one P2P message to a contact, through a switchboard with them.
	var send: (_ peer: String, _ message: MIMEMessage) async throws -> Void = { _, _ in }
	var log: ((String) -> Void)?
	/// A fetched object (display picture or wink) arrived and matched its SHA1D.
	var onObject: ((_ peer: String, MSNObject, Data) -> Void)?
	var onTransfer: ((FileTransfer) -> Void)?

	let myEmail: String
	/// What we hand out by SHA1D: our display picture and winks we sent.
	var served: [String: Data] = [:]

	private var nextIdentifier = UInt32.random(in: 4..<0xFFFF_FF00)
	private var assembling: [String: (header: P2PHeader, data: Data)] = [:]
	private var sessions: [UInt32: Session] = [:]
	private var fetching: Set<String> = []

	static let sessionRequest = "application/x-msnmsgr-sessionreqbody"

	private final class Session {
		enum Kind {
			case fetch(MSNObject)
			case serve
			case sendFile(URL)
			case receiveFile
		}

		let id: UInt32
		let peer: String
		let callID: String
		let branch: String
		let appID: UInt32
		let kind: Kind
		var buffer = Data()
		var transfer: FileTransfer?
		var handle: FileHandle?
		/// Our outgoing data message, to recognise its ACK.
		var dataIdentifier: UInt32?
		var cancelled = false
		var lastProgress = Date.distantPast

		init(id: UInt32, peer: String, callID: String, branch: String, appID: UInt32, kind: Kind) {
			self.id = id
			self.peer = peer
			self.callID = callID
			self.branch = branch
			self.appID = appID
			self.kind = kind
		}
	}

	init(myEmail: String) {
		self.myEmail = myEmail.lowercased()
	}

	// MARK: - Starting sessions

	/// Asks `peer` for an object they advertised (display picture or wink).
	func fetch(_ object: MSNObject, from peer: String) {
		guard !fetching.contains(object.sha1d) else { return }
		fetching.insert(object.sha1d)
		let s = Session(id: Self.newSessionID(), peer: peer, callID: Self.guid(), branch: Self.guid(), appID: P2PApp.object, kind: .fetch(object))
		sessions[s.id] = s
		let context = (Data(object.xml.utf8) + Data([0])).base64EncodedString()
		let body = "EUF-GUID: \(SLPMessage.objectGUID)\r\nSessionID: \(s.id)\r\nAppID: \(P2PApp.object)\r\nContext: \(context)\r\n\r\n"
		Task {
			do {
				try await sendSLP("INVITE MSNMSGR:\(peer) MSNSLP/1.0", to: peer, branch: s.branch, cseq: 0, callID: s.callID,
				                  contentType: Self.sessionRequest, body: body)
			} catch {
				log?("[P2P] object request to \(peer) failed: \(error)")
				drop(s)
			}
			try? await Task.sleep(nanoseconds: 90_000_000_000)
			if sessions[s.id] === s { drop(s) }
		}
	}

	/// Offers a file; the transfer starts when `peer` accepts.
	func sendFile(_ url: URL, to peer: String) throws -> FileTransfer {
		let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
		let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
		let s = Session(id: Self.newSessionID(), peer: peer, callID: Self.guid(), branch: Self.guid(), appID: P2PApp.file, kind: .sendFile(url))
		let t = FileTransfer(id: String(s.id), peer: peer, name: url.lastPathComponent, size: size, incoming: false, state: .waiting, fileURL: url)
		s.transfer = t
		sessions[s.id] = s
		let context = FileContext.encode(name: url.lastPathComponent, size: size).base64EncodedString()
		let body = "EUF-GUID: \(SLPMessage.fileGUID)\r\nSessionID: \(s.id)\r\nAppID: \(P2PApp.file)\r\nContext: \(context)\r\n\r\n"
		Task {
			do {
				try await sendSLP("INVITE MSNMSGR:\(peer) MSNSLP/1.0", to: peer, branch: s.branch, cseq: 0, callID: s.callID,
				                  contentType: Self.sessionRequest, body: body)
			} catch {
				finish(s, .failed(error.localizedDescription))
			}
		}
		return t
	}

	func accept(_ id: String, saveTo url: URL) {
		guard let s = session(id), case .receiveFile = s.kind, var t = s.transfer, t.state == .offered else { return }
		FileManager.default.createFile(atPath: url.path, contents: nil)
		guard let handle = try? FileHandle(forWritingTo: url) else {
			finish(s, .failed("Couldn't write to \(url.path)."))
			decline(s)
			return
		}
		s.handle = handle
		t.state = .transferring
		t.fileURL = url
		s.transfer = t
		onTransfer?(t)
		Task {
			try? await sendSLP("MSNSLP/1.0 200 OK", to: s.peer, branch: s.branch, cseq: 1, callID: s.callID,
			                   contentType: Self.sessionRequest, body: "SessionID: \(s.id)\r\n\r\n")
			if t.size == 0 { complete(s) }
		}
	}

	func decline(_ id: String) {
		guard let s = session(id), s.transfer?.state == .offered else { return }
		decline(s)
		finish(s, .declined)
	}

	func cancel(_ id: String) {
		guard let s = session(id), let t = s.transfer, !t.state.isFinished else { return }
		if t.state == .offered { return decline(id) }
		s.cancelled = true
		s.transfer?.cancelledByMe = true
		Task { try? await sendBYE(s) }
		finish(s, .cancelled)
	}

	/// A contact signed out: their transfers can't go on.
	func peerWentOffline(_ peer: String) {
		for s in sessions.values where s.peer == peer {
			if let t = s.transfer, !t.state.isFinished {
				finish(s, t.state == .waiting ? .failed("\(peer) signed out.") : .cancelled)
			} else {
				drop(s)
			}
		}
	}

	/// Signing out: every unfinished transfer fails.
	func reset() {
		for s in sessions.values where s.transfer?.state.isFinished == false {
			finish(s, .failed("You signed out."))
		}
		sessions.removeAll()
		assembling.removeAll()
		fetching.removeAll()
	}

	// MARK: - Incoming

	func handle(from peer: String, _ mime: MIMEMessage) {
		guard (mime["P2P-Dest"] ?? "").lowercased() == myEmail, let packet = P2PPacket(mime.body) else { return }
		let h = packet.header
		if h.flags & P2PFlags.ack != 0 {
			acknowledged(h, from: peer)
			return
		}
		if h.sessionID == 0 {
			// SLP, possibly in several chunks of one message.
			let key = "\(peer)#\(h.identifier)"
			var entry = assembling[key] ?? (h, Data())
			entry.data.append(packet.payload)
			guard UInt64(entry.data.count) >= h.totalSize else {
				assembling[key] = entry
				return
			}
			assembling[key] = nil
			let message = SLPMessage(entry.data)
			Task {
				await sendACK(to: peer, for: h)
				if let message { handleSLP(message, from: peer) }
			}
			return
		}
		guard let s = sessions[h.sessionID], s.peer == peer else { return }
		if h.flags == 0, h.totalSize == 4, packet.payload.count == 4 {
			// Data preparation, ahead of an object.
			Task { await sendACK(to: peer, for: h) }
			return
		}
		received(packet, in: s)
	}

	private func handleSLP(_ m: SLPMessage, from peer: String) {
		if let method = m.method {
			switch method {
			case "INVITE" where m.contentType == Self.sessionRequest:
				invited(m, from: peer)
			case "INVITE" where m.contentType == "application/x-msnmsgr-transreqbody":
				// A direct-connection proposal: decline it, so data stays on the switchboard.
				let nonce = m.body.contains("Hashed-Nonce") ? "Hashed-Nonce" : "Nonce"
				let body = "Bridge: TCPv1\r\nListening: false\r\n\(nonce): {00000000-0000-0000-0000-000000000000}\r\n\r\n"
				Task {
					try? await sendSLP("MSNSLP/1.0 200 OK", to: peer, branch: m.branch, cseq: 1, callID: m.callID,
					                   contentType: "application/x-msnmsgr-transrespbody", body: body)
				}
			case "BYE":
				if let s = session(callID: m.callID, peer: peer) { closedByPeer(s) }
			default:
				log?("[P2P] ignoring \(m.startLine)")
			}
			return
		}
		guard let status = m.status, let s = session(callID: m.callID, peer: peer) else { return }
		if status == 200 {
			if m.contentType == Self.sessionRequest, case let .sendFile(url) = s.kind { startSending(s, url) }
		} else {
			finish(s, status == 603 ? .declined : .failed("The contact's Messenger answered \(status)."))
		}
	}

	private func invited(_ m: SLPMessage, from peer: String) {
		guard let id = m.field("SessionID").flatMap(UInt32.init) else { return }
		let appID = m.field("AppID").flatMap(UInt32.init) ?? P2PApp.object
		let context = m.field("Context").flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
		switch m.field("EUF-GUID")?.uppercased() {
		case SLPMessage.objectGUID:
			let descriptor = context.map { String(decoding: $0, as: UTF8.self).replacingOccurrences(of: "\0", with: "") }
			guard let object = descriptor.flatMap(MSNObject.init), let data = served[object.sha1d] else {
				return declineInvite(m, from: peer, session: id)
			}
			let s = Session(id: id, peer: peer, callID: m.callID, branch: m.branch, appID: appID, kind: .serve)
			sessions[id] = s
			Task {
				do {
					try await sendSLP("MSNSLP/1.0 200 OK", to: peer, branch: m.branch, cseq: 1, callID: m.callID,
					                  contentType: Self.sessionRequest, body: "SessionID: \(id)\r\n\r\n")
					try await sendMessage(to: peer, session: id, flags: 0, footer: appID, payload: Data(count: 4))
					s.dataIdentifier = try await sendMessage(to: peer, session: id, flags: P2PFlags.objectData, footer: appID, payload: data)
				} catch {
					log?("[P2P] serving \(object.sha1d) to \(peer) failed: \(error)")
					drop(s)
				}
			}
		case SLPMessage.fileGUID:
			guard let context, let info = FileContext.decode(context) else {
				return declineInvite(m, from: peer, session: id)
			}
			let s = Session(id: id, peer: peer, callID: m.callID, branch: m.branch, appID: appID, kind: .receiveFile)
			let name = (info.name as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "_")
			s.transfer = FileTransfer(id: String(id), peer: peer, name: name.isEmpty ? "file" : name, size: info.size, incoming: true, state: .offered)
			sessions[id] = s
			onTransfer?(s.transfer!)
		default:
			declineInvite(m, from: peer, session: id)
		}
	}

	private func received(_ packet: P2PPacket, in s: Session) {
		let h = packet.header
		switch s.kind {
		case let .fetch(object):
			s.buffer.append(packet.payload)
			guard UInt64(s.buffer.count) >= h.totalSize else { return }
			drop(s)
			Task {
				await sendACK(to: s.peer, for: h)
				try? await sendBYE(s)
			}
			if object.matches(s.buffer) {
				onObject?(s.peer, object, s.buffer)
			} else {
				log?("[P2P] \(s.peer)'s object doesn't match its SHA1D")
			}
		case .receiveFile:
			guard var t = s.transfer, t.state == .transferring, let handle = s.handle else { return }
			do {
				try handle.seek(toOffset: h.offset)
				try handle.write(contentsOf: packet.payload)
			} catch {
				finish(s, .failed(error.localizedDescription))
				return
			}
			t.transferred = max(t.transferred, h.offset + UInt64(packet.payload.count))
			s.transfer = t
			if t.transferred >= t.size {
				Task {
					await sendACK(to: s.peer, for: h)
					complete(s)
				}
			} else {
				progress(s)
			}
		default:
			break
		}
	}

	private func acknowledged(_ h: P2PHeader, from peer: String) {
		guard let s = sessions.values.first(where: { $0.peer == peer && $0.dataIdentifier == h.ackIdentifier }) else { return }
		switch s.kind {
		case .sendFile:
			if var t = s.transfer {
				t.transferred = t.size
				s.transfer = t
			}
			finish(s, .completed)
		case .serve:
			drop(s)
		default:
			break
		}
	}

	private func closedByPeer(_ s: Session) {
		if let t = s.transfer, !t.state.isFinished {
			finish(s, t.state == .waiting ? .declined : .cancelled)
		} else {
			drop(s)
		}
	}

	// MARK: - File data

	private func startSending(_ s: Session, _ url: URL) {
		guard var t = s.transfer, t.state == .waiting else { return }
		t.state = .transferring
		s.transfer = t
		onTransfer?(t)
		Task {
			do {
				let handle = try FileHandle(forReadingFrom: url)
				defer { try? handle.close() }
				var h = P2PHeader()
				h.sessionID = s.id
				h.identifier = newIdentifier()
				h.totalSize = t.size
				h.flags = P2PFlags.fileData
				h.ackIdentifier = UInt32.random(in: 0..<0xFFFF_FF00)
				s.dataIdentifier = h.identifier
				var offset: UInt64 = 0
				while offset < t.size, !s.cancelled {
					guard let chunk = try handle.read(upToCount: P2PPacket.maxPayload), !chunk.isEmpty else { break }
					h.offset = offset
					h.length = UInt32(chunk.count)
					try await send(s.peer, P2PPacket(header: h, payload: chunk, footer: P2PApp.file).mime(to: s.peer))
					offset += UInt64(chunk.count)
					if var current = s.transfer {
						current.transferred = offset
						s.transfer = current
					}
					progress(s)
					// Don't flood the switchboard: about 1 MB/s at most.
					try await Task.sleep(nanoseconds: 1_000_000)
				}
				// Done once the receiver acknowledges the whole message.
			} catch {
				finish(s, .failed(error.localizedDescription))
			}
		}
	}

	private func progress(_ s: Session) {
		guard let t = s.transfer, Date().timeIntervalSince(s.lastProgress) > 0.1 else { return }
		s.lastProgress = Date()
		onTransfer?(t)
	}

	/// The last byte of an incoming file arrived: close it and end the session.
	private func complete(_ s: Session) {
		try? s.handle?.close()
		s.handle = nil
		if var t = s.transfer {
			t.transferred = t.size
			s.transfer = t
		}
		finish(s, .completed)
		Task { try? await sendBYE(s) }
	}

	private func finish(_ s: Session, _ state: FileTransfer.State) {
		if var t = s.transfer, !t.state.isFinished {
			t.state = state
			s.transfer = t
			if t.incoming, state != .completed, let url = t.fileURL {
				try? s.handle?.close()
				try? FileManager.default.removeItem(at: url)
			}
			onTransfer?(t)
		}
		s.cancelled = true
		drop(s)
	}

	private func drop(_ s: Session) {
		if sessions[s.id] === s { sessions[s.id] = nil }
		if case let .fetch(object) = s.kind { fetching.remove(object.sha1d) }
	}

	// MARK: - Sending

	private func decline(_ s: Session) {
		Task {
			try? await sendSLP("MSNSLP/1.0 603 Decline", to: s.peer, branch: s.branch, cseq: 1, callID: s.callID,
			                   contentType: Self.sessionRequest, body: "SessionID: \(s.id)\r\n\r\n")
		}
	}

	private func declineInvite(_ m: SLPMessage, from peer: String, session id: UInt32) {
		Task {
			try? await sendSLP("MSNSLP/1.0 603 Decline", to: peer, branch: m.branch, cseq: 1, callID: m.callID,
			                   contentType: Self.sessionRequest, body: "SessionID: \(id)\r\n\r\n")
		}
	}

	private func sendBYE(_ s: Session) async throws {
		try await sendSLP("BYE MSNMSGR:\(s.peer) MSNSLP/1.0", to: s.peer, branch: Self.guid(), cseq: 0, callID: s.callID,
		                  contentType: "application/x-msnmsgr-sessionclosebody", body: "\r\n")
	}

	private func sendSLP(_ start: String, to peer: String, branch: String, cseq: Int, callID: String,
	                     contentType: String, body: String) async throws {
		let data = SLPMessage.make(start, to: peer, from: myEmail, branch: branch, cseq: cseq, callID: callID,
		                           contentType: contentType, body: body)
		try await sendMessage(to: peer, session: 0, flags: 0, footer: P2PApp.session, payload: data)
	}

	/// Sends `payload` as one P2P message, in as many switchboard messages as it takes.
	@discardableResult
	private func sendMessage(to peer: String, session: UInt32, flags: UInt32, footer: UInt32, payload: Data) async throws -> UInt32 {
		var h = P2PHeader()
		h.sessionID = session
		h.identifier = newIdentifier()
		h.totalSize = UInt64(payload.count)
		h.flags = flags
		h.ackIdentifier = UInt32.random(in: 0..<0xFFFF_FF00)
		var offset = 0
		repeat {
			let n = min(P2PPacket.maxPayload, payload.count - offset)
			h.offset = UInt64(offset)
			h.length = UInt32(n)
			let chunk = payload.subdata(in: payload.startIndex + offset..<payload.startIndex + offset + n)
			try await send(peer, P2PPacket(header: h, payload: chunk, footer: footer).mime(to: peer))
			offset += n
		} while offset < payload.count
		return h.identifier
	}

	private func sendACK(to peer: String, for h: P2PHeader) async {
		var a = P2PHeader()
		a.sessionID = h.sessionID
		a.identifier = newIdentifier()
		a.totalSize = h.totalSize
		a.flags = P2PFlags.ack
		a.ackIdentifier = h.identifier
		a.ackUniqueID = h.ackIdentifier
		a.ackDataSize = h.totalSize
		try? await send(peer, P2PPacket(header: a).mime(to: peer))
	}

	// MARK: - Helpers

	private func newIdentifier() -> UInt32 {
		defer { nextIdentifier &+= 1 }
		return nextIdentifier
	}

	private func session(_ id: String) -> Session? {
		UInt32(id).flatMap { sessions[$0] }
	}

	private func session(callID: String, peer: String) -> Session? {
		sessions.values.first { $0.callID == callID && $0.peer == peer }
	}

	private static func newSessionID() -> UInt32 { UInt32.random(in: 1..<0x7FFF_FFFF) }

	private static func guid() -> String { "{\(UUID().uuidString)}" }
}
