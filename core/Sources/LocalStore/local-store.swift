import Foundation
import Synchronization

/// Local-first metadata, operation queue, and content cache for one Stash volume.
///
/// Every call is answered from local SQLite and cache files and never touches the network.
/// One writer connection serializes mutations. A pool of WAL reader connections serves lookups.
public final class LocalStore: Sendable {
	public static let blockSize: Int64 = 1 << 20

	public let directory: URL
	public let cacheBudget: Int64
	let cachePath: String
	let stagingPath: String
	private let databasePath: String
	private let writer: Mutex<Connection>
	private let readers = Mutex<[Connection]>([])
	/// Striped per-item locks. Held while reading or writing an item's cache file,
	/// so a reader never mixes a bitmap with a file from another version. Always taken before the writer.
	private let fileLocks: [NSLock] = (0..<64).map { _ in NSLock() }
	/// Last-access times kept in memory so reads never take the writer. Flushed before eviction.
	private let accessTimes = Mutex<[Int64: Double]>([:])

	/// Opens or creates the store in `directory`.
	/// In-flight operations from a previous run return to pending, and staged files are deleted.
	public init(directory: URL, cacheBudget: Int64 = 10 << 30) throws {
		self.directory = directory
		self.cacheBudget = cacheBudget
		cachePath = directory.appendingPathComponent("cache").path
		stagingPath = directory.appendingPathComponent("staging").path
		databasePath = directory.appendingPathComponent("store.sqlite").path

		let files = FileManager.default
		try? files.removeItem(atPath: stagingPath)
		for path in [cachePath, stagingPath] {
			try files.createDirectory(atPath: path, withIntermediateDirectories: true)
		}

		let db = try Connection(path: databasePath)
		try db.execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL; PRAGMA fullfsync = ON")
		try Schema.migrate(db)
		// An interrupted operation may have reached S3, so it counts as an attempt.
		try db.run("UPDATE ops SET state = 0, attempts = attempts + 1 WHERE state = 1")
		try db.dropContentOpsOfTombstones()
		writer = Mutex(db)
	}

	// MARK: Connections

	/// Runs `body` in a read transaction on a pooled reader connection.
	func withReader<T>(_ body: (Connection) throws -> T) throws -> T {
		let db = try readers.withLock { $0.popLast() } ?? makeReader()
		defer { readers.withLock { if $0.count < 8 { $0.append(db) } } }
		try db.run("BEGIN")
		defer { try? db.run("COMMIT") }
		return try body(db)
	}

	/// Runs `body` in an immediate write transaction, then the file work it queued in `afterCommit`.
	func withWriter<T: Sendable>(_ body: (Connection) throws -> T) throws -> T {
		try writer.withLock { db in
			db.afterCommit = []
			defer { db.afterCommit = [] }
			try db.run("BEGIN IMMEDIATE")
			do {
				let result = try body(db)
				try db.run("COMMIT")
				for work in db.afterCommit { work() }
				return result
			} catch {
				try? db.run("ROLLBACK")
				throw error
			}
		}
	}

	func withFileLock<T>(_ id: Int64, _ body: () throws -> T) rethrows -> T {
		let lock = fileLocks[Int(UInt64(bitPattern: id) % UInt64(fileLocks.count))]
		lock.lock()
		defer { lock.unlock() }
		return try body()
	}

	private func makeReader() throws -> Connection {
		let db = try Connection(path: databasePath)
		try db.execute("PRAGMA query_only = ON")
		return db
	}

	func noteAccess(_ id: Int64) {
		let now = Date().timeIntervalSince1970
		accessTimes.withLock { $0[id] = now }
	}

	func takeAccessTimes() -> [Int64: Double] {
		accessTimes.withLock { times in
			defer { times = [:] }
			return times
		}
	}

	// MARK: Lookups

	/// Returns the item, including tombstones (`state == .deletedPending`).
	public func item(_ id: Int64) throws -> Item? {
		try withReader { try $0.item(id) }
	}

	/// Returns the live child named `name`. Names are compared byte for byte.
	public func lookup(parent: Int64, name: String) throws -> Item? {
		try withReader { try $0.lookup(parent, name) }
	}

	/// Returns live children sorted by name. Pass the last name of the previous page as `after`.
	public func children(of parent: Int64, after: String? = nil, limit: Int = 1_000) throws -> [Item] {
		try withReader { db in
			try db.query(
				"""
				SELECT \(Connection.itemColumns) FROM items
				WHERE parent_id = ? AND state != 3 AND name > ? ORDER BY name LIMIT ?
				""",
				parent, after ?? "", limit, map: Connection.item(from:))
		}
	}

	/// The remote keys of the item and its descendants, tombstones included.
	public func remoteKeys(inSubtreeOf id: Int64) throws -> [String] {
		try withReader { db in
			try db.subtreeIds(id).compactMap { try db.item($0)?.remoteKey }
		}
	}

	/// Returns the slash-separated path from the root, or `""` for the root.
	public func path(of id: Int64) throws -> String? {
		try withReader { try $0.path(id) }
	}
}
