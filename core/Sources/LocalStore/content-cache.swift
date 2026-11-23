import Foundation

/// Content cache: one sparse file per item under `cache/`, 1 MiB blocks, present-blocks bitmap in SQLite.
///
/// Durability order: file data is flushed with F_FULLFSYNC before the commit that marks it present,
/// and files are unlinked only after the commit that clears their bitmap.
extension LocalStore {
	/// Returns cached bytes, or the ranges to fetch. Never waits on the network.
	/// The range is clamped to the file size.
	public func read(_ id: Int64, range: Range<Int64>) throws -> ReadResult {
		try withFileLock(id) {
			let info = try withReader { try $0.cacheInfo(id) }
			guard !info.isDirectory else { throw StoreError.isDirectory }
			let lower = max(0, range.lowerBound)
			let upper = min(range.upperBound, info.size)
			guard lower < upper else { return .data(Data()) }
			let range = lower..<upper

			let missing = info.missingRanges(in: range)
			guard missing.isEmpty else { return .missing(missing, etag: info.remoteEtag) }
			noteAccess(id)
			if let data = try readCacheFile(id, range) { return .data(data) }

			// No file: the range is all zeros past `remote_size`, or the cache was just evicted.
			var evicted = info
			evicted.blocks = BlockBitmap()
			let refetch = evicted.missingRanges(in: range)
			return refetch.isEmpty ? .data(Data(count: range.count)) : .missing(refetch, etag: info.remoteEtag)
		}
	}

	/// The ranges of `range` to fetch from remote version `etag` before it can be read. Never waits on the network.
	public func missingRanges(_ id: Int64, in range: Range<Int64>) throws -> (ranges: [Range<Int64>], etag: String?) {
		let info = try withReader { try $0.cacheInfo(id) }
		let lower = max(0, range.lowerBound), upper = min(range.upperBound, info.size)
		return (lower < upper ? info.missingRanges(in: lower..<upper) : [], info.remoteEtag)
	}

	/// True when every block is cached for the current version. Directories count as resident.
	public func isFullyResident(_ id: Int64) throws -> Bool {
		let info = try withReader { try $0.cacheInfo(id) }
		return info.isDirectory || info.isFullyResident
	}

	/// Stores downloaded bytes of remote version `etag`, starting at block-aligned `offset`.
	/// Only whole blocks that are not cached yet are written, so local edits are never overwritten.
	/// Returns false when `etag` is no longer the item's remote version.
	@discardableResult
	public func fillCache(_ id: Int64, offset: Int64, data: Data, etag: String?) throws -> Bool {
		guard offset >= 0, offset % Self.blockSize == 0 else { throw StoreError.io(errno: EINVAL) }
		return try withFileLock(id) {
			try withWriter { db in
				let info = try db.cacheInfo(id)
				guard !info.isDirectory, info.state != .deletedPending, info.remoteEtag == etag else { return false }

				var blocks = info.cachedBlocksAreCurrent ? info.blocks : BlockBitmap()
				var writes: [Range<Int64>] = []
				var block = Int(offset / Self.blockSize)
				while let backed = info.remoteBacked(block), backed.upperBound <= offset + Int64(data.count) {
					if !blocks[block] {
						writes.append(backed)
						blocks[block] = true
					}
					block += 1
				}
				guard !writes.isEmpty else { return true }

				let bytes = CacheInfo.cachedBytes(blocks, size: info.size)
				try reserveSpace(db, for: info, bytes: bytes, dirty: info.state.isDirty)
				try writeCacheFile(id) { fd in
					for range in writes {
						let start = data.startIndex + Int(range.lowerBound - offset)
						try pwriteAll(fd, data[start..<(start + range.count)], at: range.lowerBound)
					}
				}
				try db.saveCache(info, blocks: blocks, size: info.size, remoteSize: info.remoteSize, cacheEtag: etag)
				return true
			}
		}
	}

	/// A path on the store's volume for downloading a whole file before `finalizeDownload`.
	public func makeStagingURL() -> URL {
		URL(fileURLWithPath: stagingPath).appendingPathComponent(UUID().uuidString)
	}

	/// Atomically replaces the cache file with a complete download of remote version `etag`.
	/// Returns false, and deletes `file`, when the version changed or the item has local edits.
	@discardableResult
	public func finalizeDownload(_ id: Int64, from file: URL, etag: String?) throws -> Bool {
		try withFileLock(id) {
			try withWriter { db in
				let info = try db.cacheInfo(id)
				let fileSize = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? -1
				guard !info.isDirectory, info.state == .synced || info.state == .conflict,
					info.remoteEtag == etag, fileSize == info.size
				else {
					unlink(file.path)
					return false
				}

				var blocks = BlockBitmap()
				for block in 0..<info.blockCount { blocks[block] = true }
				try reserveSpace(db, for: info, bytes: CacheInfo.cachedBytes(blocks, size: info.size), dirty: false)
				let fd = open(file.path, O_RDONLY)
				guard fd >= 0 else { throw StoreError.io(errno: errno) }
				defer { close(fd) }
				try fullSync(fd)
				guard Darwin.rename(file.path, cacheFile(id)) == 0 else { throw StoreError.io(errno: errno) }
				try db.saveCache(info, blocks: blocks, size: info.size, remoteSize: info.remoteSize, cacheEtag: etag)
				return true
			}
		}
	}

	public func usage() throws -> CacheUsage {
		try withReader { try $0.usage(budget: cacheBudget) }
	}

	/// Evicts clean cached content, least recently used first, until the cache holds at most `bytes`.
	/// Dirty items are never evicted. Returns the bytes freed.
	@discardableResult
	public func evictCache(toBytes bytes: Int64) throws -> Int64 {
		try withWriter { db in
			try flushAccessTimes(db)
			let usage = try db.usage(budget: cacheBudget)
			let excess = usage.cleanBytes + usage.dirtyBytes - bytes
			return excess > 0 ? try evictClean(db, atLeast: excess, except: nil) : 0
		}
	}

	// MARK: Space

	/// Makes room for `info` to hold `bytes` of cache, evicting clean content of other items.
	/// Throws `noSpace` when dirty data alone would exceed the budget.
	func reserveSpace(_ db: Connection, for info: CacheInfo, bytes: Int64, dirty: Bool) throws {
		let wasDirty = info.state.isDirty
		guard bytes > info.cachedBytes || dirty != wasDirty else { return }
		let usage = try db.usage(budget: cacheBudget)
		let otherDirty = usage.dirtyBytes - (wasDirty ? info.cachedBytes : 0)
		let otherClean = usage.cleanBytes - (wasDirty ? 0 : info.cachedBytes)
		guard otherDirty + bytes <= cacheBudget else { throw StoreError.noSpace }
		let excess = otherDirty + otherClean + bytes - cacheBudget
		if excess > 0 { _ = try evictClean(db, atLeast: excess, except: info.id) }
	}

	private func evictClean(_ db: Connection, atLeast target: Int64, except: Int64?) throws -> Int64 {
		var victims: [Int64] = []
		var freed: Int64 = 0
		try db.each(
			"""
			SELECT id, cached_bytes FROM items
			WHERE cached_bytes > 0 AND state IN (0, 4) AND id != ? ORDER BY last_access, id
			""",
			except ?? 0
		) { row in
			victims.append(row.int64(0))
			freed += row.int64(1)
			return freed < target
		}
		for id in victims { try dropCache(db, id) }
		return freed
	}

	/// Clears the bitmap now and unlinks the file after commit.
	func dropCache(_ db: Connection, _ id: Int64) throws {
		try db.run(
			"""
			UPDATE items SET blocks = NULL, cached_bytes = 0, cache_etag = NULL,
				content_state = CASE WHEN remote_size = 0 THEN 2 ELSE 0 END
			WHERE id = ?
			""",
			id)
		db.unlinkAfterCommit(cacheFile(id))
	}

	func flushAccessTimes(_ db: Connection) throws {
		let times = takeAccessTimes()
		for (id, time) in times {
			try db.run("UPDATE items SET last_access = max(last_access, ?) WHERE id = ?", time, id)
		}
	}

	// MARK: Files

	func cacheFile(_ id: Int64) -> String { cachePath + "/" + String(id) }

	/// Opens the cache file for writing, runs `body`, then flushes it to stable storage.
	func writeCacheFile(_ id: Int64, _ body: (Int32) throws -> Void) throws {
		let fd = open(cacheFile(id), O_WRONLY | O_CREAT, 0o600)
		guard fd >= 0 else { throw StoreError.io(errno: errno) }
		defer { close(fd) }
		try body(fd)
		try fullSync(fd)
	}

	/// Returns `nil` when the cache file does not exist. Bytes past the file's end read as zeros.
	private func readCacheFile(_ id: Int64, _ range: Range<Int64>) throws -> Data? {
		let fd = open(cacheFile(id), O_RDONLY)
		guard fd >= 0 else {
			if errno == ENOENT { return nil }
			throw StoreError.io(errno: errno)
		}
		defer { close(fd) }
		var data = Data(count: Int(range.count))
		try data.withUnsafeMutableBytes { buffer in
			var done = 0
			while done < buffer.count {
				let count = pread(fd, buffer.baseAddress! + done, buffer.count - done, off_t(range.lowerBound) + off_t(done))
				if count < 0 {
					if errno == EINTR { continue }
					throw StoreError.io(errno: errno)
				}
				if count == 0 { break }
				done += count
			}
		}
		return data
	}
}

func pwriteAll(_ fd: Int32, _ data: Data, at offset: Int64) throws {
	try data.withUnsafeBytes { buffer in
		var done = 0
		while done < buffer.count {
			let count = pwrite(fd, buffer.baseAddress! + done, buffer.count - done, off_t(offset) + off_t(done))
			if count < 0 {
				if errno == EINTR { continue }
				throw StoreError.io(errno: errno)
			}
			done += count
		}
	}
}

/// Flushes to stable storage. Falls back to fsync where F_FULLFSYNC is unsupported.
func fullSync(_ fd: Int32) throws {
	if fcntl(fd, F_FULLFSYNC) == 0 { return }
	guard fsync(fd) == 0 else { throw StoreError.io(errno: errno) }
}

extension Connection {
	func usage(budget: Int64) throws -> CacheUsage {
		try first("SELECT clean, dirty FROM usage") { CacheUsage(cleanBytes: $0.int64(0), dirtyBytes: $0.int64(1), budget: budget) }
			?? CacheUsage(cleanBytes: 0, dirtyBytes: 0, budget: budget)
	}
}
