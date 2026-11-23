import Foundation

/// Merges remote listings into the store without clobbering local changes.
extension LocalStore {
	/// Applies the listing of directory `dirId`, matching items by remote key.
	///
	/// `listedAt` is when the listing request started. Items that finished syncing after that, or have an
	/// operation in flight, are left alone because the listing may predate their upload.
	/// The call is a no-op, and the directory should be listed again, when a move or delete in it
	/// completed after `listedAt`, or while the directory itself has a rename queued.
	/// Items in `protected`, such as files with writes still buffered in memory, are left alone too.
	public func applyRemoteListing(
		_ dirId: Int64, entries: [RemoteEntry], listedAt: Date, protected: Set<Int64> = []
	) throws {
		try withWriter { db in
			let listedAt = listedAt.timeIntervalSince1970
			guard let dir = try db.item(dirId), dir.isDirectory, dir.state != .deletedPending,
				let prefix = dir.remoteKey, try prefix == db.intendedKey(dir), try !db.isBusy(dirId, listedAt: listedAt)
			else { return }
			let entries = entries.filter {
				$0.key.isDirectChild(of: prefix) && isValidName($0.name) && !isLocalOnlyName($0.name)
			}
			let keys = Set(entries.map(\.key))
			let listing = Listing(
				dirId: dirId, prefix: prefix, keys: keys, listedAt: listedAt, now: Date(), protected: protected)

			for child in try db.liveChildren(dirId) {
				guard let key = child.remoteKey, key.isDirectChild(of: prefix), !keys.contains(key) else { continue }
				try applyRemoteDeletion(db, child, listing)
			}
			// Directories first, so a file named like a directory finds it.
			for entry in entries.sorted(by: { $0.isDirectory && !$1.isDirectory }) {
				try apply(db, entry, listing)
			}
		}
	}

	private struct Listing {
		let dirId: Int64
		let prefix: String
		let keys: Set<String>
		let listedAt: Double
		let now: Date
		let protected: Set<Int64>

		func isBusy(_ db: Connection, _ id: Int64) throws -> Bool {
			try protected.contains(id) || db.isBusy(id, listedAt: listedAt)
		}
	}

	private func apply(_ db: Connection, _ entry: RemoteEntry, _ listing: Listing) throws {
		let matches = try db.query(
			"SELECT \(Connection.itemColumns) FROM items WHERE remote_key = ?", entry.key, map: Connection.item(from:))
		// Deleted here: the queued delete wins. A delete queued after a create whose reply was lost has no item with the key.
		if matches.contains(where: { $0.state == .deletedPending }) { return }
		let isDeleteQueued = try db.first(
			"SELECT 1 FROM ops WHERE kind = ? AND key = ? LIMIT 1", OperationKind.delete.rawValue, entry.key) { _ in true } != nil
		if isDeleteQueued { return }

		if let local = matches.first {
			guard try !listing.isBusy(db, local.id), !local.isDirectory,
				local.remoteEtag != entry.etag
			else { return }
			if local.state.isDirty {
				try saveRemoteAsConflict(db, entry, local: local, listing)
			} else {
				try updateFromRemote(db, local.id, entry)
			}
			return
		}

		guard let local = try db.lookup(listing.dirId, entry.name) else {
			try insertRemote(db, entry, name: entry.name, remoteName: entry.name, state: .synced, listing)
			return
		}
		guard try !listing.isBusy(db, local.id) else { return }
		switch (local.isDirectory, entry.isDirectory) {
		case (true, true):
			// Created on both sides: one directory.
			try db.run("UPDATE items SET remote_key = ? WHERE id = ? AND remote_key IS NULL", entry.key, local.id)
		case (false, false):
			try saveRemoteAsConflict(db, entry, local: local, listing)
		case (true, false):
			let alias = try uniqueName(db, listing) { fileCollisionName(for: entry.name, attempt: $0) }
			try insertRemote(db, entry, name: alias, remoteName: entry.name, state: .synced, listing)
		case (false, true):
			// The local file keeps its key and takes the alias; the directory takes the name.
			let alias = try uniqueName(db, listing) { fileCollisionName(for: local.name, attempt: $0) }
			try db.run("UPDATE items SET name = ? WHERE id = ?", alias, local.id)
			try insertRemote(db, entry, name: entry.name, remoteName: entry.name, state: .synced, listing)
		}
	}

	/// Keeps `local` under its name and inserts the remote version under a conflict name.
	/// Queues a server-side move to that name ahead of the local item's pending uploads.
	private func saveRemoteAsConflict(_ db: Connection, _ entry: RemoteEntry, local: Item, _ listing: Listing) throws {
		let name = try uniqueName(db, listing) {
			conflictName(for: entry.name, isDirectory: entry.isDirectory, date: listing.now, attempt: $0)
		}
		let copyId = try insertRemote(db, entry, name: name, remoteName: name, state: .conflict, listing)
		try db.enqueue(.move, itemId: copyId, key: listing.prefix + name + (entry.isDirectory ? "/" : ""), fromKey: entry.key)
		if local.remoteKey == entry.key {
			try db.run("UPDATE items SET remote_key = NULL, remote_etag = NULL WHERE id = ?", local.id)
		}
		// Anything else queued for this key, from any item, now runs after the move.
		try db.requeue(db.query(
			"SELECT \(Connection.operationColumns) FROM ops WHERE state = 0 AND item_id != ?1 AND (key = ?2 OR from_key = ?2)",
			copyId, entry.key, map: Connection.operation(from:)))
	}

	private func updateFromRemote(_ db: Connection, _ id: Int64, _ entry: RemoteEntry) throws {
		try db.run(
			"""
			UPDATE items SET size = ?1, remote_size = ?1, mtime = ?2, remote_mtime = ?2, remote_etag = ?3
			WHERE id = ?4
			""",
			entry.size, entry.mtime.timeIntervalSince1970, entry.etag, id)
		try dropCache(db, id)
	}

	@discardableResult
	private func insertRemote(
		_ db: Connection, _ entry: RemoteEntry, name: String, remoteName: String, state: ItemState, _ listing: Listing
	) throws -> Int64 {
		let mtime = entry.mtime.timeIntervalSince1970
		let contentState: ContentState = !entry.isDirectory && entry.size == 0 ? .full : .none
		try db.run(
			"""
			INSERT INTO items (parent_id, name, remote_name, is_dir, size, mtime, ctime, mode, state,
				remote_key, remote_etag, remote_mtime, remote_size, content_state)
			VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6, ?7, ?8, ?9, ?10, ?6, ?5, ?11)
			""",
			listing.dirId, name, remoteName, entry.isDirectory, entry.isDirectory ? 0 : entry.size, mtime,
			entry.isDirectory ? 0o755 : 0o644, state.rawValue, entry.key, entry.etag, contentState.rawValue)
		return db.lastInsertId
	}

	/// The item is gone remotely. Clean items go too. Items with local work stay and are uploaded again.
	private func applyRemoteDeletion(_ db: Connection, _ item: Item, _ listing: Listing) throws {
		guard try !listing.isBusy(db, item.id) else { return }
		if item.isDirectory {
			for child in try db.liveChildren(item.id) where child.remoteKey != nil {
				try applyRemoteDeletion(db, child, listing)
			}
		}
		let hasQueuedContent = try db.first(
			"SELECT 1 FROM ops WHERE item_id = ? AND kind IN (0, 1) LIMIT 1", item.id) { _ in true } != nil
		let hasChildren = try item.isDirectory && !db.liveChildren(item.id).isEmpty
		guard item.state.isDirty || hasQueuedContent || hasChildren else { return try purgeSubtree(db, item.id) }

		try db.run("UPDATE items SET remote_key = NULL, remote_etag = NULL WHERE id = ?", item.id)
		try db.run("DELETE FROM ops WHERE item_id = ? AND kind = ? AND state = 0", item.id, OperationKind.move.rawValue)
		// Queued work aimed at the old key now goes to where the item is here.
		if let oldKey = item.remoteKey {
			try db.requeuePendingOps(under: item.id, replacingPrefix: oldKey, with: db.intendedKey(item))
		}
		if item.isDirectory && !hasQueuedContent {
			try db.run("UPDATE items SET state = ? WHERE id = ?", ItemState.localNew.rawValue, item.id)
			try db.enqueue(.mkdir, itemId: item.id, key: db.intendedKey(item))
		}
	}

	/// The first name from `make(1)`, `make(2)`, ... that is free both here and in the listing.
	private func uniqueName(_ db: Connection, _ listing: Listing, _ make: (Int) -> String) throws -> String {
		var attempt = 1
		while true {
			let name = make(attempt)
			let isTaken = try db.lookup(listing.dirId, name) != nil
				|| listing.keys.contains(listing.prefix + name) || listing.keys.contains(listing.prefix + name + "/")
			if !isTaken { return name }
			attempt += 1
		}
	}
}

/// rclone keeps a file's modification time in object metadata, which listings don't include.
extension LocalStore {
	/// Synced files in the directory whose metadata mtime is not known for their current remote version.
	public func filesNeedingRemoteMtime(in dirId: Int64) throws -> [Item] {
		try withReader { db in
			try db.query(
				"""
				SELECT \(Connection.itemColumns) FROM items
				WHERE parent_id = ? AND is_dir = 0 AND state = 0 AND remote_etag IS NOT NULL AND meta_etag IS NOT remote_etag
				""",
				dirId, map: Connection.item(from:))
		}
	}

	/// Records the metadata mtime of remote version `etag`; `nil` when it has none. Ignored when the item has
	/// changed since, here or remotely, so a local mtime is never replaced.
	public func setRemoteMtime(_ id: Int64, etag: String, mtime: Date?) throws {
		try withWriter { db in
			try db.run(
				"""
				UPDATE items SET meta_etag = ?1, mtime = coalesce(?2, mtime), remote_mtime = coalesce(?2, remote_mtime)
				WHERE id = ?3 AND remote_etag = ?1 AND state = 0 AND NOT EXISTS (SELECT 1 FROM ops WHERE item_id = ?3)
				""",
				etag, mtime?.timeIntervalSince1970, id)
		}
	}
}

extension Connection {
	/// True when the item has an operation in flight or finished syncing after `listedAt`.
	func isBusy(_ id: Int64, listedAt: Double) throws -> Bool {
		try first(
			"""
			SELECT synced_at > ? OR EXISTS (SELECT 1 FROM ops WHERE item_id = items.id AND state = 1)
			FROM items WHERE id = ?
			""",
			listedAt, id) { $0.bool(0) } ?? false
	}
}
