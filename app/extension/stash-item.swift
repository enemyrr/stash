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
		lock.withLock { pendingEndLocked }
	}

	/// Runs `body` with the end of the furthest pending write while no write is buffered or committed,
	/// so a size read from the store matches it.
	func withPendingEnd<T>(_ body: (Int64) throws -> T) rethrows -> T {
		try lock.withLock { try body(pendingEndLocked) }
	}

	private var pendingEndLocked: Int64 {
		pending.map { $0.offset + Int64($0.data.count) }.max() ?? 0
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

	/// Buffers a write, appending to the previous one when contiguous, and commits the buffer once it is full or
	/// the file is not open for writing. When that commit fails, this write is dropped and earlier ones stay buffered.
	func write(_ data: Data, at offset: Int64, to store: LocalStore) throws {
		try lock.withLock {
			lastWrite = Date()
			if let last = pending.last, last.offset + Int64(last.data.count) == offset {
				pending[pending.count - 1].data.append(data)
			} else {
				pending.append((offset, data))
			}
			pendingBytes += data.count
			guard pendingBytes >= Self.maxPendingBytes || !isOpenForWrite else { return }
			do {
				try commitLocked(to: store)
			} catch {
				// Committed in order, so this write is still the tail of the last entry.
				let last = pending.count - 1
				pending[last].data.removeLast(data.count)
				if pending[last].data.isEmpty { pending.removeLast() }
				pendingBytes -= data.count
				throw error
			}
		}
	}

	/// Writes buffered data to the store in order. On failure the unwritten part stays buffered.
	func commit(to store: LocalStore) throws {
		try lock.withLock { try commitLocked(to: store) }
	}

	/// Commits, then runs `body` before any other write is buffered, such as a truncate or a read of the size.
	func flushed<T>(to store: LocalStore, _ body: () throws -> T) throws -> T {
		try lock.withLock {
			try commitLocked(to: store)
			return try body()
		}
	}

	private func commitLocked(to store: LocalStore) throws {
		while let next = pending.first {
			try store.write(id, offset: next.offset, data: next.data)
			pending.removeFirst()
			pendingBytes -= next.data.count
		}
	}

	func discardPending() {
		lock.withLock {
			pending = []
			pendingBytes = 0
		}
	}
}
