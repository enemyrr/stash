import Foundation

/// The durable operation queue the sync engine drains to S3.
///
/// Ordering: moves and deletes are barriers. A barrier runs only when every earlier operation has
/// finished, and nothing after it runs until it completes. Uploads and mkdirs between barriers run
/// in parallel, at most one per item.
extension LocalStore {
	/// Returns up to `limit` operations that are ready to run. Does not claim them.
	public func nextBatch(limit: Int, now: Date = Date()) throws -> [SyncOperation] {
		guard limit > 0 else { return [] }
		let now = now.timeIntervalSince1970
		return try withReader { db in
			var batch: [SyncOperation] = []
			var busyItems = Set<Int64>()
			try db.each("SELECT \(Connection.operationColumns), retry_after FROM ops ORDER BY id") { row in
				let op = Connection.operation(from: row)
				// Uploads and mkdirs of local-only items wait here until the item moves out, if ever.
				if !op.kind.isBarrier, isLocalOnlyKey(op.key) { return true }
				let isReady = !op.isInFlight && row.double(7) <= now
				if op.kind.isBarrier {
					if isReady && busyItems.isEmpty { batch.append(op) }
					return false
				}
				if isReady && !busyItems.contains(op.itemId) { batch.append(op) }
				busyItems.insert(op.itemId)
				return batch.count < limit
			}
			return batch
		}
	}

	/// Claims pending operations and returns the ones claimed, with current keys.
	/// An upload is claimed only when its content is fully cached. Its `contentURL` then points to a
	/// stable copy, so later local writes do not change what is being sent.
	/// A failure to claim one operation leaves it pending; the call throws only when nothing was claimed.
	public func markInFlight(_ ids: [Int64]) throws -> [SyncOperation] {
		var claimed: [SyncOperation] = []
		var firstError: (any Error)?
		for id in ids {
			do {
				if let op = try claim(id) { claimed.append(op) }
			} catch {
				firstError = firstError ?? error
			}
		}
		if claimed.isEmpty, let firstError { throw firstError }
		return claimed
	}

	private func claim(_ id: Int64) throws -> SyncOperation? {
		guard let itemId = try withReader({ try $0.operation(id)?.itemId }) else { return nil }
		return try withFileLock(itemId) {
			try withWriter { db -> SyncOperation? in
				guard let op = try db.operation(id), !op.isInFlight else { return nil }
				var contentURL: URL?
				if op.kind == .upload {
					let info = try db.cacheInfo(op.itemId)
					guard info.isFullyResident else { return nil }
					contentURL = try snapshotContent(op.itemId, size: info.size, opId: id)
				}
				try db.run("UPDATE ops SET state = 1 WHERE id = ?", id)
				var claimed = try db.operation(id)
				claimed?.contentURL = contentURL
				return claimed
			}
		}
	}

	/// Records that the operation reached S3. `etag` is the new object's ETag for uploads.
	public func complete(_ opId: Int64, etag: String? = nil) throws {
		try withWriter { db in
			guard let op = try db.operation(opId) else { return }
			try db.run("DELETE FROM ops WHERE id = ?", opId)
			db.unlinkAfterCommit(stagingFile(opId))
			let now = Date().timeIntervalSince1970

			switch op.kind {
			case .upload, .mkdir:
				try db.run(
					"UPDATE items SET remote_key = ?, remote_etag = ?, synced_at = ? WHERE id = ?",
					op.key, etag, now, op.itemId)
				guard let item = try db.item(op.itemId), item.state.isDirty else { return }
				let isSettled = try db.first(
					"SELECT 1 FROM ops WHERE item_id = ? AND kind IN (0, 1) LIMIT 1", op.itemId) { _ in true } == nil
				if op.kind == .upload {
					// The upload sent fully cached content, so every block is now local data of a known version.
					let info = try db.cacheInfo(op.itemId)
					var blocks = BlockBitmap()
					for block in 0..<info.blockCount where info.isPresent(block) { blocks[block] = true }
					try db.saveCache(
						info, blocks: blocks, size: info.size, remoteSize: isSettled ? info.size : info.remoteSize,
						cacheEtag: etag)
				}
				if isSettled { try db.run("UPDATE items SET state = 0 WHERE id = ?", op.itemId) }
			case .move:
				try db.moveRemoteKeys(from: op.fromKey ?? "", to: op.key, now: now)
				try db.run("UPDATE items SET state = 0 WHERE id = ? AND state = 4", op.itemId)
				try db.markListingStale(forKey: op.fromKey ?? "", now: now)
				try db.markListingStale(forKey: op.key, now: now)
			case .delete:
				try db.markListingStale(forKey: op.key, now: now)
				if let item = try db.item(op.itemId), item.state == .deletedPending {
					try purgeSubtree(db, item.id)
				}
			}
		}
	}

	/// Returns the operation to pending. It will not be offered again before `retryAfter`.
	public func fail(_ opId: Int64, retryAfter: Date) throws {
		try withWriter { db in
			try db.run(
				"UPDATE ops SET state = 0, attempts = attempts + 1, retry_after = ? WHERE id = ?",
				retryAfter.timeIntervalSince1970, opId)
			try db.dropContentOpsOfTombstones()
			db.unlinkAfterCommit(stagingFile(opId))
		}
	}

	/// Every queued operation, in order.
	public func queuedOperations() throws -> [SyncOperation] {
		try withReader { db in
			try db.query("SELECT \(Connection.operationColumns) FROM ops ORDER BY id", map: Connection.operation(from:))
		}
	}

	private func stagingFile(_ opId: Int64) -> String { stagingPath + "/upload-" + String(opId) }

	/// Clones the cache file (APFS copy-on-write, copy elsewhere) to the staging area.
	private func snapshotContent(_ itemId: Int64, size: Int64, opId: Int64) throws -> URL {
		let path = stagingFile(opId)
		unlink(path)
		if copyfile(cacheFile(itemId), path, nil, copyfile_flags_t(COPYFILE_CLONE)) != 0 {
			guard errno == ENOENT else { throw StoreError.io(errno: errno) }
			let fd = open(path, O_WRONLY | O_CREAT, 0o600)
			guard fd >= 0 else { throw StoreError.io(errno: errno) }
			close(fd)
		}
		guard Darwin.truncate(path, off_t(size)) == 0 else { throw StoreError.io(errno: errno) }
		return URL(fileURLWithPath: path)
	}
}

extension Connection {
	static let operationColumns = "id, kind, item_id, key, from_key, attempts, state"

	static func operation(from row: Row) -> SyncOperation {
		SyncOperation(
			id: row.int64(0), kind: OperationKind(rawValue: row.int(1)) ?? .upload, itemId: row.int64(2),
			key: row.string(3), fromKey: row.optionalString(4), attempts: row.int(5), isInFlight: row.int(6) == 1)
	}

	func operation(_ id: Int64) throws -> SyncOperation? {
		try first("SELECT \(Self.operationColumns) FROM ops WHERE id = ?", id, map: Self.operation(from:))
	}

	/// Appends an operation, coalescing with what is already queued:
	/// - an upload joins a pending upload of the same item, which reads the latest content when it runs;
	/// - a move right after a pending move of the same item extends it, or cancels it on a round trip.
	func enqueue(_ kind: OperationKind, itemId: Int64, key: String, fromKey: String? = nil) throws {
		switch kind {
		case .upload:
			let isQueued = try first(
				"SELECT 1 FROM ops WHERE item_id = ? AND kind = 0 AND state = 0 LIMIT 1", itemId) { _ in true } != nil
			if isQueued { return }
		case .move:
			if let last = try first("SELECT \(Self.operationColumns) FROM ops ORDER BY id DESC LIMIT 1", map: Self.operation(from:)),
				last.kind == .move, !last.isInFlight, last.itemId == itemId, last.key == fromKey
			{
				if last.fromKey == key {
					try run("DELETE FROM ops WHERE id = ?", last.id)
				} else {
					try run("UPDATE ops SET key = ? WHERE id = ?", key, last.id)
				}
				return
			}
		case .mkdir, .delete:
			break
		}
		try run("INSERT INTO ops (kind, item_id, key, from_key) VALUES (?, ?, ?, ?)", kind.rawValue, itemId, key, fromKey)
	}

	/// Moves the subtree's pending operations to the end of the queue and rewrites keys under `oldPrefix`.
	/// `contentOnly` leaves moves and deletes in place.
	func requeuePendingOps(under id: Int64, replacingPrefix oldPrefix: String, with newPrefix: String, contentOnly: Bool = false) throws {
		var ops: [SyncOperation] = []
		for itemId in try subtreeIds(id) {
			ops += try query(
				"SELECT \(Self.operationColumns) FROM ops WHERE item_id = ? AND state = 0", itemId, map: Self.operation(from:))
		}
		if contentOnly { ops.removeAll { $0.kind.isBarrier } }
		try requeue(ops, replacingPrefix: oldPrefix, with: newPrefix)
	}

	/// Moves pending operations to the end of the queue, keeping their order.
	func requeue(_ ops: [SyncOperation], replacingPrefix oldPrefix: String? = nil, with newPrefix: String? = nil) throws {
		for op in ops.sorted(by: { $0.id < $1.id }) {
			var key = op.key
			if let oldPrefix, let newPrefix, key.utf8.starts(with: oldPrefix.utf8) {
				key = newPrefix + String(decoding: key.utf8.dropFirst(oldPrefix.utf8.count), as: UTF8.self)
			}
			try run(
				"""
				INSERT INTO ops (kind, item_id, key, from_key, attempts, retry_after)
				SELECT kind, item_id, ?, from_key, attempts, retry_after FROM ops WHERE id = ?
				""",
				key, op.id)
			try run("DELETE FROM ops WHERE id = ?", op.id)
		}
	}

	/// Points `remote_key`s at their new location after a server-side move.
	func moveRemoteKeys(from: String, to: String, now: Double) throws {
		if from.hasSuffix("/") {
			let upperBound = String(from.dropLast()) + "0"  // "0" sorts right after "/"
			try run(
				"""
				UPDATE items SET remote_key = ?2 || substr(remote_key, length(?1) + 1), synced_at = ?4
				WHERE remote_key >= ?1 AND remote_key < ?3
				""",
				from, to, upperBound, now)
		} else {
			try run("UPDATE items SET remote_key = ?, synced_at = ? WHERE remote_key = ?", to, now, from)
		}
	}

	/// Listings of the directory holding `key` that started before `now` predate this change.
	func markListingStale(forKey key: String, now: Double) throws {
		let path = key.hasSuffix("/") ? key.dropLast() : Substring(key)
		let parent = path.lastIndex(of: "/").map { String(path[...$0]) } ?? ""
		try run("UPDATE items SET synced_at = ? WHERE remote_key = ? AND is_dir = 1 AND state != 3", now, parent)
	}

	/// Uploads and mkdirs of deleted items can never run. The queued delete covers them.
	func dropContentOpsOfTombstones() throws {
		try run("DELETE FROM ops WHERE kind IN (0, 1) AND state = 0 AND item_id IN (SELECT id FROM items WHERE state = 3)")
	}
}
