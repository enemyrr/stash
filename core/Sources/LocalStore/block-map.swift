import Foundation

/// Present-blocks bitmap, one bit per block, stored as a BLOB.
struct BlockBitmap: Equatable {
	private(set) var bytes: [UInt8]

	init(_ data: Data? = nil) {
		bytes = data.map { Array($0) } ?? []
	}

	/// `nil` when no block is present, so empty bitmaps store as NULL.
	var data: Data? {
		bytes.contains { $0 != 0 } ? Data(bytes) : nil
	}

	subscript(block: Int) -> Bool {
		get {
			let byte = block / 8
			return byte < bytes.count && bytes[byte] & (1 << (block % 8)) != 0
		}
		set {
			let byte = block / 8
			if byte >= bytes.count {
				guard newValue else { return }
				bytes.append(contentsOf: repeatElement(0, count: byte - bytes.count + 1))
			}
			if newValue { bytes[byte] |= 1 << (block % 8) } else { bytes[byte] &= ~(1 << (block % 8)) }
		}
	}

	/// Clears every block at or past `count`.
	mutating func truncate(toBlocks count: Int) {
		let keepBytes = (count + 7) / 8
		if bytes.count > keepBytes { bytes.removeLast(bytes.count - keepBytes) }
		for block in count..<max(count, bytes.count * 8) { self[block] = false }
	}
}

/// The cache-related columns of one item, plus the block math over them.
struct CacheInfo {
	static let blockSize = LocalStore.blockSize

	let id: Int64
	let isDirectory: Bool
	var size: Int64
	var remoteSize: Int64
	var state: ItemState
	let remoteEtag: String?
	let cacheEtag: String?
	let cachedBytes: Int64
	var blocks: BlockBitmap

	static func blockCount(_ size: Int64) -> Int { Int((size + blockSize - 1) / blockSize) }

	static func blocks(touching range: Range<Int64>) -> ClosedRange<Int> {
		Int(range.lowerBound / blockSize)...Int((range.upperBound - 1) / blockSize)
	}

	var blockCount: Int { Self.blockCount(size) }

	/// The bytes of `block` that come from the remote version. `nil` past `remoteSize`.
	func remoteBacked(_ block: Int) -> Range<Int64>? {
		let start = Int64(block) * Self.blockSize
		guard start < remoteSize else { return nil }
		return start..<min(start + Self.blockSize, remoteSize)
	}

	/// Clean blocks are valid only for the remote version they were fetched from.
	/// Blocks of a dirty item hold local data and are always valid.
	var cachedBlocksAreCurrent: Bool { state.isDirty || cacheEtag == remoteEtag }

	func isPresent(_ block: Int) -> Bool {
		remoteBacked(block) == nil || (blocks[block] && cachedBlocksAreCurrent)
	}

	/// Merged remote-backed ranges of the absent blocks that overlap `range`.
	func missingRanges(in range: Range<Int64>) -> [Range<Int64>] {
		guard !range.isEmpty else { return [] }
		var ranges: [Range<Int64>] = []
		for block in Self.blocks(touching: range) where !isPresent(block) {
			guard let backed = remoteBacked(block) else { continue }
			if let last = ranges.last, last.upperBound == backed.lowerBound {
				ranges[ranges.count - 1] = last.lowerBound..<backed.upperBound
			} else {
				ranges.append(backed)
			}
		}
		return ranges
	}

	var isFullyResident: Bool {
		(0..<blockCount).allSatisfy(isPresent)
	}

	var missingRanges: [Range<Int64>] { missingRanges(in: 0..<size) }

	/// Bytes held by the explicitly present blocks of `bitmap` for a file of `size`.
	static func cachedBytes(_ bitmap: BlockBitmap, size: Int64) -> Int64 {
		var total: Int64 = 0
		for block in 0..<blockCount(size) where bitmap[block] {
			total += min(blockSize, size - Int64(block) * blockSize)
		}
		return total
	}

	var contentState: ContentState {
		if isFullyResident { return .full }
		return (0..<blockCount).contains { blocks[$0] && remoteBacked($0) != nil } ? .partial : .none
	}
}
