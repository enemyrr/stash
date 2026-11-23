import Foundation
import Testing
@testable import LocalStore

@Suite struct LocalOnlyTests {
	@Test func finderFilesNeverSyncAndDontBlockTheQueue() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		let dsStore = try store.createFile(in: Item.rootId, name: ".DS_Store")
		try store.write(dsStore.id, offset: 0, data: Data("x".utf8))
		let file = try store.createFile(in: Item.rootId, name: "a")
		try syncAll(store)
		try store.delete(file.id)

		#expect(try store.nextBatch(limit: 10).map(\.kind) == [.delete])
		try syncAll(store)
		#expect(try store.item(dsStore.id)?.remoteKey == nil)
	}

	@Test func trashMovesTheBucketCopyAndEmptyingDeletesIt() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		let file = try store.createFile(in: Item.rootId, name: "report.pdf")
		try syncAll(store)
		let trash = try store.createDirectory(in: try store.createDirectory(in: Item.rootId, name: ".Trashes").id, name: "501")
		try store.rename(file.id, to: trash.id, name: "report.pdf")
		#expect(try store.nextBatch(limit: 10).map { "\($0.kind) \($0.key)" } == ["move .Trashes/501/report.pdf"])
		try syncAll(store)

		// The bucket's .Trashes is hidden, so a root listing neither shows it nor deletes the local one.
		try listRoot(store, [RemoteEntry(key: ".Trashes/")])
		#expect(try store.children(of: Item.rootId).map(\.name) == [".Trashes"])
		#expect(try store.item(file.id)?.parentId == trash.id)

		try store.delete(file.id)
		#expect(try store.nextBatch(limit: 10).map { "\($0.kind) \($0.key)" } == ["delete .Trashes/501/report.pdf"])
	}

	@Test func putBackUploadsWhatWasHeldBack() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		let synced = try store.createFile(in: Item.rootId, name: "a")
		try syncAll(store)
		let trash = try store.createDirectory(in: Item.rootId, name: ".Trashes")
		try store.rename(synced.id, to: trash.id, name: "a")
		try syncAll(store)
		let unsynced = try store.createFile(in: Item.rootId, name: "b")
		try store.rename(unsynced.id, to: trash.id, name: "b")
		try store.write(synced.id, offset: 0, data: Data("edited in the trash".utf8))
		#expect(try store.nextBatch(limit: 10).isEmpty)

		try store.rename(synced.id, to: Item.rootId, name: "a2")
		try store.rename(unsynced.id, to: Item.rootId, name: "b")
		#expect(try store.queuedOperations().filter { !$0.key.hasPrefix(".Trashes") }.map { "\($0.kind) \($0.key)" } == [
			"move a2", "upload a2", "upload b",
		])
	}
}
