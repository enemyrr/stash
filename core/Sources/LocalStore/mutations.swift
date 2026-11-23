import Foundation

/// Local mutations. Each runs in one transaction and appends its sync work to the queue.
extension LocalStore {
	@discardableResult
	public func createFile(in parent: Int64, name: String, mode: UInt16 = 0o644) throws -> Item {
		try create(in: parent, name: name, isDirectory: false, mode: mode)
	}

	@discardableResult
	public func createDirectory(in parent: Int64, name: String, mode: UInt16 = 0o755) throws -> Item {
		try create(in: parent, name: name, isDirectory: true, mode: mode)
	}

	/// Writes through to the cache and marks the item modified.
	/// A dirty file is always fully cached, so this throws `blocksMissing` with every range to fetch
	/// first, unless the write itself replaces them. Throws `noSpace` when dirty data would exceed the budget.
	@discardableResult
	public func write(_ id: Int64, offset: Int64, data: Data) throws -> Item {
		guard offset >= 0 else { throw StoreError.io(errno: EINVAL) }
		return try withFileLock(id) {
			try withWriter { db in
				let item = try db.liveItem(id)
				guard !item.isDirectory else { throw StoreError.isDirectory }
				guard !data.isEmpty else { return item }
				let info = try db.cacheInfo(id)
				let end = offset + Int64(data.count)

				var after = info
				after.blocks = info.cachedBlocksAreCurrent ? info.blocks : BlockBitmap()
				after.state = .localModified
				after.size = max(info.size, end)
				for block in CacheInfo.blocks(touching: offset..<end) {
					let backed = info.remoteBacked(block)
					let isCovered = backed.map { offset <= $0.lowerBound && end >= $0.upperBound } ?? true
					if isCovered { after.blocks[block] = true }
				}
				guard after.missingRanges.isEmpty else { throw StoreError.blocksMissing(after.missingRanges) }

				try reserveSpace(db, for: info, bytes: CacheInfo.cachedBytes(after.blocks, size: after.size), dirty: true)
				try writeCacheFile(id) { fd in
					// Bytes past the recorded end are leftovers of an interrupted truncate. Zero them before growing.
					if end > info.size, ftruncate(fd, off_t(info.size)) != 0 { throw StoreError.io(errno: errno) }
					try pwriteAll(fd, data, at: offset)
				}
				try db.saveCache(
					info, blocks: after.blocks, size: after.size, remoteSize: info.remoteSize, cacheEtag: info.cacheEtag)
				return try markModified(db, item)
			}
		}
	}

	/// Sets the file size. Growing adds zeros. The kept range must be cached, as for `write`.
	@discardableResult
	public func truncate(_ id: Int64, to size: Int64) throws -> Item {
		guard size >= 0 else { throw StoreError.io(errno: EINVAL) }
		return try withFileLock(id) {
			try withWriter { db in
				let item = try db.liveItem(id)
				guard !item.isDirectory else { throw StoreError.isDirectory }
				guard size != item.size else { return item }
				let info = try db.cacheInfo(id)

				var after = info
				after.blocks = info.cachedBlocksAreCurrent ? info.blocks : BlockBitmap()
				after.state = .localModified
				after.blocks.truncate(toBlocks: CacheInfo.blockCount(size))
				after.size = size
				after.remoteSize = min(info.remoteSize, size)
				guard after.missingRanges.isEmpty else { throw StoreError.blocksMissing(after.missingRanges) }

				try reserveSpace(db, for: info, bytes: CacheInfo.cachedBytes(after.blocks, size: size), dirty: true)
				let path = cacheFile(id)
				if size > info.size {
					// Drop leftovers past the old end so the new range reads as zeros.
					if access(path, F_OK) == 0 {
						try writeCacheFile(id) { fd in
							guard ftruncate(fd, off_t(info.size)) == 0 else { throw StoreError.io(errno: errno) }
						}
					}
				} else {
					// Cut the file only after commit, so a crash never loses bytes the store still records.
					db.afterCommit.append { _ = Darwin.truncate(path, off_t(size)) }
				}
				try db.saveCache(
					info, blocks: after.blocks, size: size, remoteSize: after.remoteSize, cacheEtag: info.cacheEtag)
				return try markModified(db, item)
			}
		}
	}

	/// Renames or moves an item, with its subtree. Replaces an existing file, or an empty directory,
	/// at the destination.
	@discardableResult
	public func rename(_ id: Int64, to newParent: Int64, name newName: String) throws -> Item {
		try validate(newName)
		return try withWriter { db in
			guard id != Item.rootId else { throw StoreError.invalidMove }
			let item = try db.liveItem(id)
			let parent = try db.liveItem(newParent)
			guard parent.isDirectory else { throw StoreError.notDirectory }
			if item.isDirectory, try db.isAncestor(id, of: newParent) { throw StoreError.invalidMove }

			let target = try db.lookup(newParent, newName)
			let keyOwners = try db.remoteNameOwners(newParent, newName).filter { $0 != id && $0 != target?.id }
			guard keyOwners.isEmpty else { throw StoreError.exists }
			if let target {
				if target.id == id { return item }
				if target.isDirectory != item.isDirectory {
					throw target.isDirectory ? StoreError.isDirectory : StoreError.notDirectory
				}
				if target.isDirectory, try !db.liveChildren(target.id).isEmpty { throw StoreError.notEmpty }
				try removeSubtree(db, target)
			}

			let oldKey = try db.intendedKey(item)
			let isRemote = try db.hasRemotePresence(id)
			let now = Date().timeIntervalSince1970
			try db.run(
				"UPDATE items SET parent_id = ?, name = ?, remote_name = ?, ctime = ? WHERE id = ?",
				newParent, newName, newName, now, id)
			if let oldParent = item.parentId { try db.touch(oldParent, now: now) }
			try db.touch(newParent, now: now)

			let moved = try db.liveItem(id)
			let newKey = try db.intendedKey(moved)
			if isRemote {
				try db.enqueue(.move, itemId: id, key: newKey, fromKey: oldKey)
				// Edits made while local-only, such as in .Trashes, were held back. They follow the move.
				if isLocalOnlyKey(oldKey) {
					try db.requeuePendingOps(under: id, replacingPrefix: oldKey, with: newKey, contentOnly: true)
				}
			} else {
				try db.requeuePendingOps(under: id, replacingPrefix: oldKey, with: newKey)
			}
			return moved
		}
	}

	/// Deletes an item and its subtree. Items that exist remotely stay as tombstones until the
	/// queued delete completes. Items that never left this Mac are removed at once.
	public func delete(_ id: Int64) throws {
		try withWriter { db in
			guard id != Item.rootId else { throw StoreError.invalidMove }
			let item = try db.liveItem(id)
			try removeSubtree(db, item)
			if let parent = item.parentId { try db.touch(parent, now: Date().timeIntervalSince1970) }
		}
	}

	// MARK: Helpers

	private func create(in parentId: Int64, name: String, isDirectory: Bool, mode: UInt16) throws -> Item {
		try validate(name)
		return try withWriter { db in
			let parent = try db.liveItem(parentId)
			guard parent.isDirectory else { throw StoreError.notDirectory }
			guard try db.lookup(parentId, name) == nil, try db.remoteNameOwners(parentId, name).isEmpty else {
				throw StoreError.exists
			}
			let now = Date().timeIntervalSince1970
			try db.run(
				"""
				INSERT INTO items (parent_id, name, remote_name, is_dir, mtime, ctime, mode, state, content_state, last_access)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
				""",
				parentId, name, name, isDirectory, now, now, Int(mode), ItemState.localNew.rawValue,
				(isDirectory ? ContentState.none : .full).rawValue, now)
			let item = try db.liveItem(db.lastInsertId)
			try db.touch(parentId, now: now)
			try db.enqueue(isDirectory ? .mkdir : .upload, itemId: item.id, key: db.intendedKey(item))
			return item
		}
	}

	private func markModified(_ db: Connection, _ item: Item) throws -> Item {
		let now = Date().timeIntervalSince1970
		try db.run(
			"UPDATE items SET mtime = ?, last_access = ?, state = CASE WHEN state = 1 THEN 1 ELSE 2 END WHERE id = ?",
			now, now, item.id)
		try db.enqueue(.upload, itemId: item.id, key: db.intendedKey(item))
		return try db.liveItem(item.id)
	}

	/// Tombstones the subtree and queues one delete if any of it exists remotely; otherwise purges it.
	func removeSubtree(_ db: Connection, _ item: Item) throws {
		guard try db.hasRemotePresence(item.id) else { return try purgeSubtree(db, item.id) }
		let key = try db.intendedKey(item)
		for id in try db.subtreeIds(item.id) {
			// Moves stay: they relocate what the delete must find.
			try db.run("DELETE FROM ops WHERE item_id = ? AND state = 0 AND kind != ?", id, OperationKind.move.rawValue)
			try db.run("UPDATE items SET state = ? WHERE id = ?", ItemState.deletedPending.rawValue, id)
			try dropCache(db, id)
		}
		try db.enqueue(.delete, itemId: item.id, key: key)
	}

	/// Removes the subtree's rows, queued operations, and cache files.
	func purgeSubtree(_ db: Connection, _ id: Int64) throws {
		for id in try db.subtreeIds(id) {
			try db.run("DELETE FROM ops WHERE item_id = ?", id)
			try db.run("DELETE FROM items WHERE id = ?", id)
			db.unlinkAfterCommit(cacheFile(id))
		}
	}

	private func validate(_ name: String) throws {
		guard isValidName(name) else { throw StoreError.invalidName }
	}
}
