import CZlib
import Foundation

/// Microsoft Cabinet files, as WLM packages winks: a header, folders of data
/// blocks (stored or MSZIP-compressed) and a file table. Enough to read the
/// files out of a wink, and to make one.
public enum Cabinet {
	public enum CabinetError: Error {
		case notACabinet, unsupportedCompression(Int), corrupt
	}

	/// The files in a cabinet, by name.
	public static func files(in cab: Data) throws -> [String: Data] {
		let b = [UInt8](cab)
		guard b.count >= 36, b[0] == 0x4D, b[1] == 0x53, b[2] == 0x43, b[3] == 0x46 else { throw CabinetError.notACabinet }
		func u16(_ o: Int) throws -> Int {
			guard o + 2 <= b.count else { throw CabinetError.corrupt }
			return Int(b[o]) | Int(b[o + 1]) << 8
		}
		func u32(_ o: Int) throws -> Int {
			guard o + 4 <= b.count else { throw CabinetError.corrupt }
			return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
		}
		func cString(_ o: inout Int) throws -> String {
			guard let end = b[o...].firstIndex(of: 0) else { throw CabinetError.corrupt }
			defer { o = end + 1 }
			return String(decoding: b[o..<end], as: UTF8.self)
		}
		let filesOffset = try u32(16)
		let folderCount = try u16(26), fileCount = try u16(28), flags = try u16(30)
		var o = 36
		var folderReserve = 0, dataReserve = 0
		if flags & 0x4 != 0 {
			let headerReserve = try u16(36)
			folderReserve = Int(b[38])
			dataReserve = Int(b[39])
			o = 40 + headerReserve
		}
		if flags & 0x1 != 0 { _ = try cString(&o); _ = try cString(&o) }
		if flags & 0x2 != 0 { _ = try cString(&o); _ = try cString(&o) }

		var folders: [Data] = []
		for _ in 0..<folderCount {
			let start = try u32(o), blockCount = try u16(o + 4), compression = try u16(o + 6) & 0xF
			o += 8 + folderReserve
			var blocks: [(data: Data, size: Int)] = []
			var p = start
			for _ in 0..<blockCount {
				let packed = try u16(p + 4), unpacked = try u16(p + 6)
				let from = p + 8 + dataReserve
				guard from + packed <= b.count else { throw CabinetError.corrupt }
				blocks.append((Data(b[from..<from + packed]), unpacked))
				p = from + packed
			}
			switch compression {
			case 0: folders.append(blocks.reduce(into: Data()) { $0 += $1.data })
			case 1: folders.append(try inflateMSZIP(blocks))
			default: throw CabinetError.unsupportedCompression(compression)
			}
		}

		var out: [String: Data] = [:]
		o = filesOffset
		for _ in 0..<fileCount {
			let size = try u32(o), offset = try u32(o + 4), folder = try u16(o + 8)
			o += 16
			let name = try cString(&o)
			guard folder < folders.count, offset + size <= folders[folder].count else { throw CabinetError.corrupt }
			let f = folders[folder]
			out[name] = f.subdata(in: f.startIndex + offset..<f.startIndex + offset + size)
		}
		return out
	}

	/// MSZIP: each block is "CK" + a raw deflate stream, decompressed with the
	/// previous block's output as its dictionary.
	static func inflateMSZIP(_ blocks: [(data: Data, size: Int)]) throws -> Data {
		var out = Data()
		var dictionary = Data()
		for block in blocks {
			guard block.data.count >= 2, block.data[block.data.startIndex] == 0x43, block.data[block.data.startIndex + 1] == 0x4B else {
				throw CabinetError.corrupt
			}
			var input = [UInt8](block.data.dropFirst(2))
			var output = [UInt8](repeating: 0, count: block.size)
			var stream = z_stream()
			guard inflateInit2_(&stream, -15, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw CabinetError.corrupt }
			defer { inflateEnd(&stream) }
			if !dictionary.isEmpty {
				let d = [UInt8](dictionary.suffix(32768))
				_ = d.withUnsafeBufferPointer { inflateSetDictionary(&stream, $0.baseAddress, UInt32($0.count)) }
			}
			let result = input.withUnsafeMutableBufferPointer { inp in
				output.withUnsafeMutableBufferPointer { outp -> Int32 in
					stream.next_in = inp.baseAddress
					stream.avail_in = UInt32(inp.count)
					stream.next_out = outp.baseAddress
					stream.avail_out = UInt32(outp.count)
					return inflate(&stream, Z_FINISH)
				}
			}
			guard result == Z_STREAM_END || (result == Z_OK && stream.avail_out == 0) || result == Z_BUF_ERROR else { throw CabinetError.corrupt }
			let produced = Data(output.prefix(block.size - Int(stream.avail_out)))
			out += produced
			dictionary = out
		}
		return out
	}

	/// Makes a single-folder cabinet, MSZIP-compressed unless `compress` is false.
	public static func make(_ files: [(name: String, data: Data)], compress: Bool = true) -> Data {
		let folder = files.reduce(into: Data()) { $0 += $1.data }
		var blocks = Data()
		var blockCount = 0
		var offset = 0
		repeat {
			let chunk = folder.subdata(in: offset..<min(offset + 32768, folder.count))
			let packed = compress ? Data("CK".utf8) + deflateRaw(chunk) : chunk
			blocks.appendLE(UInt32(0))
			blocks.appendLE(UInt16(packed.count))
			blocks.appendLE(UInt16(chunk.count))
			blocks += packed
			blockCount += 1
			offset += chunk.count
		} while offset < folder.count

		var fileTable = Data()
		var position = 0
		for f in files {
			fileTable.appendLE(UInt32(f.data.count))
			fileTable.appendLE(UInt32(position))
			fileTable.appendLE(UInt16(0))
			fileTable.appendLE(UInt16(0x5A21))  // date
			fileTable.appendLE(UInt16(0))
			fileTable.appendLE(UInt16(0x20))  // archive
			fileTable += Data(f.name.utf8) + Data([0])
			position += f.data.count
		}
		let headerSize = 36, folderSize = 8
		let filesAt = headerSize + folderSize
		let dataAt = filesAt + fileTable.count
		var cab = Data("MSCF".utf8)
		cab.appendLE(UInt32(0))
		cab.appendLE(UInt32(dataAt + blocks.count))
		cab.appendLE(UInt32(0))
		cab.appendLE(UInt32(filesAt))
		cab.appendLE(UInt32(0))
		cab += Data([3, 1])
		cab.appendLE(UInt16(1))
		cab.appendLE(UInt16(files.count))
		cab.appendLE(UInt16(0))
		cab.appendLE(UInt16(0))
		cab.appendLE(UInt16(0))
		cab.appendLE(UInt32(dataAt))
		cab.appendLE(UInt16(blockCount))
		cab.appendLE(UInt16(compress ? 1 : 0))
		return cab + fileTable + blocks
	}

	static func deflateRaw(_ data: Data) -> Data {
		var stream = z_stream()
		guard deflateInit2_(&stream, 6, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
			return Data()
		}
		defer { deflateEnd(&stream) }
		var input = [UInt8](data)
		var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, UInt(data.count))) + 16)
		let produced = input.withUnsafeMutableBufferPointer { inp in
			output.withUnsafeMutableBufferPointer { outp -> Int in
				stream.next_in = inp.baseAddress
				stream.avail_in = UInt32(inp.count)
				stream.next_out = outp.baseAddress
				stream.avail_out = UInt32(outp.count)
				_ = deflate(&stream, Z_FINISH)
				return outp.count - Int(stream.avail_out)
			}
		}
		return Data(output.prefix(produced))
	}
}

/// WLM winks: a cabinet whose content.xml names a Flash animation and a
/// preview image (`<item type="thumbnail" file="…"/>`).
public enum Wink {
	public static func thumbnail(fromCabinet cab: Data) -> Data? {
		guard let files = try? Cabinet.files(in: cab) else { return nil }
		let byLowercased = Dictionary(files.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
		if let xml = byLowercased["content.xml"], let root = try? XElement.parse(xml) {
			let items = root.descendants(named: "item")
			for type in ["thumbnail", "preview"] {
				if let file = items.first(where: { $0.attributes["type"]?.lowercased() == type })?.attributes["file"],
				   let data = byLowercased[file.lowercased()] {
					return data
				}
			}
		}
		let images = [".png", ".gif", ".jpg", ".jpeg"]
		return files.first { file in images.contains { file.key.lowercased().hasSuffix($0) } }?.value
	}

	/// A minimal wink cabinet around a preview image (and an optional animation).
	public static func make(name: String, thumbnail: Data, animation: Data = Data()) -> Data {
		let xml = """
			<?xml version="1.0"?><package xmlns="http://messenger.msn.com/messengercontent/2004" contenttype="D" \
			contentid="\(UUID().uuidString)" contentname="\(name.xmlEscaped)"><item contenttype="P" file="preview.png" \
			type="thumbnail" mimetype="image/png"/><item contenttype="A" file="animation.swf" type="animation" \
			mimetype="application/x-shockwave-flash"/></package>
			"""
		return Cabinet.make([("content.xml", Data(xml.utf8)), ("preview.png", thumbnail), ("animation.swf", animation)])
	}
}
