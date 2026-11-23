import Foundation

/// Item queries shared by readers and the writer.
extension Connection {
	static let itemColumns = """
		id, parent_id, name, is_dir, size, mtime, ctime, mode, remote_key, remote_etag, remote_mtime, state, content_state
		"""

	static func item(from row: Row) -> Item {
		Item(
			id: row.int64(0),
			parentId: row.optionalInt64(1),
			name: row.string(2),
			isDirectory: row.bool(3),
			size: row.int64(4),
			mtime: Date(timeIntervalSince1970: row.double(5)),
			ctime: Date(timeIntervalSince1970: row.double(6)),
			mode: UInt16(truncatingIfNeeded: row.int(7)),
			remoteKey: row.optionalString(8),
			remoteEtag: row.optionalString(9),
			remoteMtime: row.optionalDouble(10).map(Date.init(timeIntervalSince1970:)),
			state: ItemState(rawValue: row.int(11)) ?? .synced,
			contentState: ContentState(rawValue: row.int(12)) ?? .none)
	}

	func item(_ id: Int64) throws -> Item? {
		try first("SELECT \(Self.itemColumns) FROM items WHERE id = ?", id, map: Self.item(from:))
	}

	/// Returns the item unless it is missing or a tombstone.
	func liveItem(_ id: Int64) throws -> Item {
		guard let item = try item(id), item.state != .deletedPending else { throw StoreError.notFound }
		return item
	}

	func lookup(_ parent: Int64, _ name: String) throws -> Item? {
		try first(
			"SELECT \(Self.itemColumns) FROM items WHERE parent_id = ? AND name = ? AND state != 3",
			parent, name, map: Self.item(from:))
	}

	/// Live children whose key uses `name`. Differs from `lookup` for aliases such as `foo (file)`.
	func remoteNameOwners(_ parent: Int64, _ name: String) throws -> [Int64] {
		try query("SELECT id FROM items WHERE parent_id = ? AND remote_name = ? AND state != 3", parent, name) { $0.int64(0) }
	}

	func liveChildren(_ parent: Int64) throws -> [Item] {
		try query(
			"SELECT \(Self.itemColumns) FROM items WHERE parent_id = ? AND state != 3",
			parent, map: Self.item(from:))
	}

	func path(_ id: Int64) throws -> String? {
		try components(id, column: "name")?.joined(separator: "/")
	}

	/// The key this item should have in the bucket, built from `remote_name`s.
	func intendedKey(_ item: Item) throws -> String {
		let path = try components(item.id, column: "remote_name")?.joined(separator: "/") ?? ""
		return item.isDirectory && !path.isEmpty ? path + "/" : path
	}

	private func components(_ id: Int64, column: String) throws -> [String]? {
		var names: [String] = []
		var current: Int64? = id
		while let id = current, id != Item.rootId {
			guard let (parent, name) = try first(
				"SELECT parent_id, \(column) FROM items WHERE id = ?", id, map: { ($0.optionalInt64(0), $0.string(1)) })
			else { return nil }
			names.append(name)
			current = parent
		}
		return names.reversed()
	}

	func isAncestor(_ ancestor: Int64, of id: Int64) throws -> Bool {
		var current: Int64? = id
		while let id = current {
			if id == ancestor { return true }
			current = try first("SELECT parent_id FROM items WHERE id = ?", id) { $0.optionalInt64(0) } ?? nil
		}
		return false
	}

	/// The item and all descendants, tombstones included.
	func subtreeIds(_ id: Int64) throws -> [Int64] {
		try query(
			"""
			WITH RECURSIVE sub(id) AS (
				SELECT ?1 UNION ALL SELECT items.id FROM items JOIN sub ON items.parent_id = sub.id)
			SELECT id FROM sub
			""",
			id) { $0.int64(0) }
	}

	/// True when anything in the subtree exists remotely, or may: an operation in flight or tried before.
	func hasRemotePresence(_ id: Int64) throws -> Bool {
		try first(
			"""
			WITH RECURSIVE sub(id) AS (
				SELECT ?1 UNION ALL SELECT items.id FROM items JOIN sub ON items.parent_id = sub.id)
			SELECT EXISTS (SELECT 1 FROM items WHERE id IN sub AND remote_key IS NOT NULL)
				OR EXISTS (SELECT 1 FROM ops WHERE item_id IN sub AND (state = 1 OR attempts > 0))
			""",
			id) { $0.bool(0) } ?? false
	}

	func hasInFlightOps(_ id: Int64) throws -> Bool {
		try first("SELECT 1 FROM ops WHERE item_id = ? AND state = 1 LIMIT 1", id) { _ in true } ?? false
	}

	func touch(_ id: Int64, now: Double) throws {
		try run("UPDATE items SET mtime = ?, ctime = ? WHERE id = ?", now, now, id)
	}

	func cacheInfo(_ id: Int64) throws -> CacheInfo {
		guard let info = try first(
			"""
			SELECT is_dir, size, remote_size, state, remote_etag, cache_etag, cached_bytes, blocks
			FROM items WHERE id = ?
			""",
			id,
			map: { row in
				CacheInfo(
					id: id, isDirectory: row.bool(0), size: row.int64(1), remoteSize: row.int64(2),
					state: ItemState(rawValue: row.int(3)) ?? .synced, remoteEtag: row.optionalString(4),
					cacheEtag: row.optionalString(5), cachedBytes: row.int64(6), blocks: BlockBitmap(row.data(7)))
			})
		else { throw StoreError.notFound }
		return info
	}

	/// Stores a new bitmap and size, and derives `cached_bytes` and `content_state` from them.
	func saveCache(_ info: CacheInfo, blocks: BlockBitmap, size: Int64, remoteSize: Int64, cacheEtag: String?) throws {
		let updated = CacheInfo(
			id: info.id, isDirectory: false, size: size, remoteSize: remoteSize, state: info.state,
			remoteEtag: info.remoteEtag, cacheEtag: cacheEtag, cachedBytes: 0, blocks: blocks)
		try run(
			"""
			UPDATE items SET blocks = ?, size = ?, remote_size = ?, cache_etag = ?, cached_bytes = ?, content_state = ?
			WHERE id = ?
			""",
			blocks.data, size, remoteSize, cacheEtag, CacheInfo.cachedBytes(blocks, size: size),
			updated.contentState.rawValue, info.id)
	}
}
