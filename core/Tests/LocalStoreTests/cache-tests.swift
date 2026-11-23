import Foundation
import Testing
@testable import LocalStore

@Suite struct CacheTests {
	@Test func partialReadsReportMissingRanges() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		let size = Int64(3 * mib + mib / 2)
		try listRoot(store, [RemoteEntry(key: "video", size: size, etag: "e1")])
		let video = try #require(try store.root("video"))
		let m = Int64(mib)

		#expect(try store.read(video.id, range: 0..<size) == .missing([0..<size], etag: "e1"))

		#expect(try store.fillCache(video.id, offset: m, data: bytes(0xAB, mib), etag: "e1"))
		#expect(try store.read(video.id, range: m..<(m + 10)) == .data(bytes(0xAB, 10)))
		#expect(try store.read(video.id, range: 0..<size) == .missing([0..<m, (2 * m)..<size], etag: "e1"))
		#expect(try store.item(video.id)?.contentState == .partial)

		// A fill for another version is refused.
		#expect(try !store.fillCache(video.id, offset: 0, data: bytes(1, mib), etag: "old"))

		try store.fillCache(video.id, offset: 0, data: bytes(1, mib), etag: "e1")
		try store.fillCache(video.id, offset: 2 * m, data: bytes(2, mib + mib / 2), etag: "e1")
		#expect(try store.isFullyResident(video.id))
		#expect(try store.item(video.id)?.contentState == .full)
		#expect(try store.read(video.id, range: (m - 1)..<(m + 1)) == .data(Data([1, 0xAB])))
		// Reads past the end are clamped.
		#expect(try store.read(video.id, range: (size - 1)..<(size + 100)) == .data(Data([2])))
	}

	@Test func remoteChangeInvalidatesCachedBlocks() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		try listRoot(store, [RemoteEntry(key: "f", size: 4, etag: "v1")])
		let file = try #require(try store.root("f"))
		try store.fillCache(file.id, offset: 0, data: Data("old!".utf8), etag: "v1")

		try listRoot(store, [RemoteEntry(key: "f", size: 4, etag: "v2")])
		#expect(try store.read(file.id, range: 0..<4) == .missing([0..<4], etag: "v2"))
		#expect(try !store.isFullyResident(file.id))
		try store.fillCache(file.id, offset: 0, data: Data("new!".utf8), etag: "v2")
		#expect(try store.read(file.id, range: 0..<4) == .data(Data("new!".utf8)))
	}

	@Test func writesNeedTheWholeFileCached() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)
		let m = Int64(mib)

		try listRoot(store, [RemoteEntry(key: "f", size: 3 * m, etag: "e")])
		let file = try #require(try store.root("f"))

		// Every missing range comes back, except the blocks the write replaces whole.
		#expect(throws: StoreError.blocksMissing([0..<m, (2 * m)..<(3 * m)])) {
			try store.write(file.id, offset: m, data: bytes(9, mib))
		}
		try store.fillCache(file.id, offset: 0, data: bytes(1, mib), etag: "e")
		try store.fillCache(file.id, offset: m, data: bytes(2, mib), etag: "e")
		try store.write(file.id, offset: 2 * m, data: bytes(3, mib))
		try store.write(file.id, offset: 10, data: Data("x".utf8))
		try store.write(file.id, offset: m, data: bytes(2, mib))
		try store.write(file.id, offset: 3 * m + 5, data: Data("tail".utf8))

		#expect(try store.read(file.id, range: (3 * m)..<(3 * m + 9)) == .data(Data(count: 5) + Data("tail".utf8)))
		#expect(try store.read(file.id, range: 9..<12) == .data(Data([1]) + Data("x".utf8) + Data([1])))
		#expect(try store.isFullyResident(file.id))
		// Truncating to zero needs nothing from the remote.
		try listRoot(store, [RemoteEntry(key: "f", size: 3 * m, etag: "e"), RemoteEntry(key: "g", size: 3 * m, etag: "g")])
		let other = try #require(try store.root("g"))
		try store.truncate(other.id, to: 0)
		try store.write(other.id, offset: 0, data: Data("new".utf8))
		#expect(try store.read(other.id, range: 0..<10) == .data(Data("new".utf8)))
	}

	@Test func truncateThenGrowReadsZeros() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		let file = try store.createFile(in: Item.rootId, name: "f")
		try store.write(file.id, offset: 0, data: Data("abcdef".utf8))
		try store.truncate(file.id, to: 3)
		try store.truncate(file.id, to: 6)
		#expect(try store.read(file.id, range: 0..<6) == .data(Data("abc".utf8) + Data(count: 3)))

		// Same for cached remote content: the cut-off part must not come back.
		try listRoot(store, [RemoteEntry(key: "r", size: 10, etag: "e")])
		let remote = try #require(try store.root("r"))
		#expect(throws: StoreError.blocksMissing([0..<4])) { try store.truncate(remote.id, to: 4) }
		try store.fillCache(remote.id, offset: 0, data: Data("0123456789".utf8), etag: "e")
		try store.truncate(remote.id, to: 4)
		try store.truncate(remote.id, to: 10)
		#expect(try store.read(remote.id, range: 0..<10) == .data(Data("0123".utf8) + Data(count: 6)))
	}

	@Test func leftoverBytesPastTheEndNeverShowUp() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		// As if a crash left an old cache file behind, or cut a truncate short.
		let file = try store.createFile(in: Item.rootId, name: "f")
		try bytes(0xEE, 100).write(to: URL(fileURLWithPath: store.cacheFile(file.id)))
		try store.write(file.id, offset: 50, data: Data("x".utf8))
		#expect(try store.read(file.id, range: 0..<51) == .data(Data(count: 50) + Data("x".utf8)))

		try bytes(0xEE, 100).write(to: URL(fileURLWithPath: store.cacheFile(file.id)))
		try store.truncate(file.id, to: 0)
		try store.truncate(file.id, to: 20)
		#expect(try store.read(file.id, range: 0..<20) == .data(Data(count: 20)))
	}

	@Test func finalizeDownloadReplacesTheFileAtomically() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		try listRoot(store, [RemoteEntry(key: "f", size: Int64(mib + 3), etag: "e")])
		let file = try #require(try store.root("f"))

		let stale = store.makeStagingURL()
		try bytes(1, mib + 3).write(to: stale)
		#expect(try !store.finalizeDownload(file.id, from: stale, etag: "other"))
		#expect(!FileManager.default.fileExists(atPath: stale.path))

		let download = store.makeStagingURL()
		try bytes(5, mib + 3).write(to: download)
		#expect(try store.finalizeDownload(file.id, from: download, etag: "e"))
		#expect(try store.isFullyResident(file.id))
		#expect(try store.read(file.id, range: Int64(mib)..<Int64(mib + 3)) == .data(bytes(5, 3)))
	}

	@Test func evictionIsLeastRecentlyUsedAndSkipsDirtyItems() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)
		let size = Int64(mib)

		try listRoot(store, ["a", "b", "dirty"].map { RemoteEntry(key: $0, size: size, etag: $0) })
		let a = try #require(try store.root("a"))
		let b = try #require(try store.root("b"))
		let dirty = try #require(try store.root("dirty"))
		for item in [a, b, dirty] {
			try store.fillCache(item.id, offset: 0, data: bytes(1, mib), etag: item.remoteEtag)
		}
		try store.write(dirty.id, offset: 0, data: Data("edit".utf8))
		_ = try store.read(b.id, range: 0..<1)
		_ = try store.read(a.id, range: 0..<1)
		#expect(try store.usage() == CacheUsage(cleanBytes: 2 * size, dirtyBytes: size, budget: store.cacheBudget))

		#expect(try store.evictCache(toBytes: 2 * size) == size)
		#expect(try store.item(b.id)?.contentState == ContentState.none)
		#expect(try store.item(a.id)?.contentState == .full)

		try store.evictCache(toBytes: 0)
		#expect(try store.item(a.id)?.contentState == ContentState.none)
		#expect(try store.item(dirty.id)?.contentState == .full)
		#expect(try store.read(dirty.id, range: 0..<4) == .data(Data("edit".utf8)))
		#expect(try store.usage().cleanBytes == 0)
	}

	@Test func dirtyDataBeyondTheBudgetFailsEarly() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir, cacheBudget: Int64(2 * mib))

		try listRoot(store, [RemoteEntry(key: "clean", size: Int64(mib), etag: "c")])
		let clean = try #require(try store.root("clean"))
		try store.fillCache(clean.id, offset: 0, data: bytes(1, mib), etag: "c")

		let one = try store.createFile(in: Item.rootId, name: "one")
		try store.write(one.id, offset: 0, data: bytes(2, mib))
		// The budget is full; the next dirty megabyte evicts the clean file.
		let two = try store.createFile(in: Item.rootId, name: "two")
		try store.write(two.id, offset: 0, data: bytes(3, mib))
		#expect(try store.item(clean.id)?.contentState == ContentState.none)

		// Dirty data is never evicted, so a third megabyte has no room.
		let three = try store.createFile(in: Item.rootId, name: "three")
		#expect(throws: StoreError.noSpace) { try store.write(three.id, offset: 0, data: bytes(4, mib)) }
		#expect(try store.item(three.id)?.size == 0)
		#expect(try store.usage().dirtyBytes == Int64(2 * mib))
	}
}
