import FSKit
import LocalStore

/// One item of the volume, keyed by its LocalStore id. Buffers writes until close, sync, or reclaim,
/// because each store write flushes to disk twice.
final class StashNode: FSItem {
	/// Pending writes are committed once they reach this size.
	static let maxPendingBytes = 8 << 20

	let id: Int64
	let isDirectory: Bool
	/// Content of a read-only file served by the volume itself, outside the store.
	let virtualContent: Data?
	private let lock = NSLock()
	private var pending: [(offset: Int64, data: Data)] = []
	private var pendingBytes = 0
	private var isOpenForWrite = false
	private var lastWrite = Date.distantPast
	private var lastReadEnd: Int64 = -1

	init(id: Int64, isDirectory: Bool, virtualContent: Data? = nil) {
		self.id = id
		self.isDirectory = isDirectory
		self.virtualContent = virtualContent
	}

	/// Store ids start at 1 for the root; FSKit's root is 2 and its parent 1.
	var fileID: FSItem.Identifier { FSItem.Identifier(rawValue: UInt64(id) + 1)! }

	static func fileID(parent: Int64?) -> FSItem.Identifier {
		parent.map { FSItem.Identifier(rawValue: UInt64($0) + 1)! } ?? .parentOfRoot
	}

	/// True while the file is being written, and shortly after, so the engine uploads it once it settles.
	var isBusy: Bool {
		lock.withLock { isOpenForWrite || !pending.isEmpty || Date().timeIntervalSince(lastWrite) < 2 }
	}

	/// The end of the furthest pending write, or 0.
	var pendingEnd: Int64 {
		lock.withLock { pending.map { $0.offset + Int64($0.data.count) }.max() ?? 0 }
	}

	/// Records a read. Returns true when it continues the previous one, so the file is being read in order.
	func noteRead(_ range: Range<Int64>) -> Bool {
		lock.withLock {
			defer { lastReadEnd = range.upperBound }
			return range.lowerBound == lastReadEnd
		}
	}

	/// Also counts as activity, which holds back the upload for a moment.
	func setOpenForWrite(_ isOpen: Bool) {
		lock.withLock {
			isOpenForWrite = isOpen
			lastWrite = Date()
		}
	}

	/// Buffers a write, appending to the previous one when contiguous. Returns true when the buffer should be committed.
	func buffer(_ data: Data, at offset: Int64) -> Bool {
		lock.withLock {
			lastWrite = Date()
			if let last = pending.last, last.offset + Int64(last.data.count) == offset {
				pending[pending.count - 1].data.append(data)
			} else {
				pending.append((offset, data))
			}
			pendingBytes += data.count
			return pendingBytes >= Self.maxPendingBytes || !isOpenForWrite
		}
	}

	/// Writes buffered data to the store in order. On failure the unwritten part stays buffered.
	func commit(to store: LocalStore) throws {
		try lock.withLock {
			while let next = pending.first {
				try store.write(id, offset: next.offset, data: next.data)
				pending.removeFirst()
				pendingBytes -= next.data.count
			}
		}
	}

	func discardPending() {
		lock.withLock {
			pending = []
			pendingBytes = 0
		}
	}
}
