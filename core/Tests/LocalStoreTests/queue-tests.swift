import Foundation
import Testing
@testable import LocalStore

@Suite struct QueueTests {
	@Test func createAndWritesCoalesceIntoOneUpload() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		let file = try store.createFile(in: Item.rootId, name: "f.txt")
		try store.write(file.id, offset: 0, data: Data("one".utf8))
		try store.write(file.id, offset: 3, data: Data("two".utf8))

		let ops = try store.queuedOperations()
		#expect(ops.map(\.kind) == [.upload])
		#expect(ops.first?.key == "f.txt")
	}

	@Test func createThenDeleteLeavesNothing() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		let folder = try store.createDirectory(in: Item.rootId, name: "d")
		let file = try store.createFile(in: folder.id, name: "f")
		try store.write(file.id, offset: 0, data: Data("x".utf8))
		try store.delete(folder.id)

		#expect(try store.queuedOperations().isEmpty)
		#expect(try store.item(file.id) == nil)
	}

	@Test func renameBeforeUploadRewritesQueuedKeys() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		let folder = try store.createDirectory(in: Item.rootId, name: "untitled folder")
		try store.createFile(in: folder.id, name: "f")
		try store.rename(folder.id, to: Item.rootId, name: "Photos")

		let ops = try store.queuedOperations()
		#expect(ops.map(\.kind) == [.mkdir, .upload])
		#expect(ops.map(\.key) == ["Photos/", "Photos/f"])
	}

	@Test func renamesOfSyncedItemCoalesceIntoOneMove() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		let file = try store.createFile(in: Item.rootId, name: "a")
		try syncAll(store)
		#expect(try store.item(file.id)?.state == .synced)

		try store.rename(file.id, to: Item.rootId, name: "b")
		try store.rename(file.id, to: Item.rootId, name: "c")
		var ops = try store.queuedOperations()
		#expect(ops.count == 1)
		#expect(ops.first?.kind == .move)
		#expect(ops.first?.fromKey == "a")
		#expect(ops.first?.key == "c")

		try store.rename(file.id, to: Item.rootId, name: "a")
		ops = try store.queuedOperations()
		#expect(ops.isEmpty)
	}

	@Test func deleteOfSyncedDirectoryDropsPendingWorkAndTombstones() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		let folder = try store.createDirectory(in: Item.rootId, name: "d")
		let file = try store.createFile(in: folder.id, name: "f")
		try syncAll(store)
		try store.write(file.id, offset: 0, data: Data("x".utf8))
		try store.delete(folder.id)

		let ops = try store.queuedOperations()
		#expect(ops.map(\.kind) == [.delete])
		#expect(ops.first?.key == "d/")
		#expect(try store.item(folder.id)?.state == .deletedPending)
		#expect(try store.root("d") == nil)
		// The name is free again while the delete is queued.
		try store.createDirectory(in: Item.rootId, name: "d")

		try syncAll(store)
		#expect(try store.item(folder.id) == nil)
		#expect(try store.item(file.id) == nil)
	}

	@Test func barriersRunAloneAndInOrder() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		let file = try store.createFile(in: Item.rootId, name: "a")
		try syncAll(store)
		try store.write(file.id, offset: 0, data: Data("new".utf8))
		try store.rename(file.id, to: Item.rootId, name: "b")
		let other = try store.createFile(in: Item.rootId, name: "other")

		var batch = try store.nextBatch(limit: 10)
		#expect(batch.map(\.kind) == [.upload])
		#expect(batch.first?.key == "a")

		let claimed = try store.markInFlight(batch.map(\.id))
		let upload = try #require(claimed.first)
		#expect(try Data(contentsOf: #require(upload.contentURL)) == Data("new".utf8))
		// Claimed work is not offered again, and the move waits for it.
		#expect(try store.nextBatch(limit: 10).isEmpty)
		try store.complete(upload.id, etag: "v2")
		#expect(try store.item(file.id)?.state == .synced)

		batch = try store.nextBatch(limit: 10)
		#expect(batch.map(\.kind) == [.move])
		try store.complete(try #require(batch.first).id)
		#expect(try store.item(file.id)?.remoteKey == "b")

		batch = try store.nextBatch(limit: 10)
		#expect(batch.map(\.itemId) == [other.id])
	}

	@Test func failedOperationWaitsForRetryTime() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		try store.createFile(in: Item.rootId, name: "a")
		let op = try #require(try store.markInFlight(store.nextBatch(limit: 1).map(\.id)).first)
		try store.fail(op.id, retryAfter: Date().addingTimeInterval(60))

		#expect(try store.nextBatch(limit: 10).isEmpty)
		let later = try store.nextBatch(limit: 10, now: Date().addingTimeInterval(120))
		#expect(later.map(\.id) == [op.id])
		#expect(later.first?.attempts == 1)
	}

	@Test func inFlightOperationsReturnToPendingOnReopen() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		var opId: Int64 = 0
		var contentURL: URL?
		do {
			let store = try LocalStore(directory: dir)
			let file = try store.createFile(in: Item.rootId, name: "a")
			try store.write(file.id, offset: 0, data: Data("data".utf8))
			let op = try #require(try store.markInFlight(store.nextBatch(limit: 1).map(\.id)).first)
			opId = op.id
			contentURL = op.contentURL
			#expect(try store.queuedOperations().first?.isInFlight == true)
			// The store goes away without complete or fail, as in a crash.
		}

		let store = try LocalStore(directory: dir)
		let ops = try store.queuedOperations()
		#expect(ops.map(\.id) == [opId])
		#expect(ops.first?.isInFlight == false)
		#expect(!FileManager.default.fileExists(atPath: try #require(contentURL).path))
		#expect(try store.nextBatch(limit: 10).map(\.id) == [opId])
		#expect(try store.root("a")?.state == .localNew)
	}

	@Test func uploadSendsASnapshotOfTheContent() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		let file = try store.createFile(in: Item.rootId, name: "f")
		try store.write(file.id, offset: 0, data: Data("first".utf8))
		let op = try #require(try store.markInFlight(store.nextBatch(limit: 1).map(\.id)).first)
		try store.write(file.id, offset: 0, data: Data("later".utf8))

		#expect(try Data(contentsOf: #require(op.contentURL)) == Data("first".utf8))
		try store.complete(op.id, etag: "v1")
		// The later write still needs an upload.
		#expect(try store.item(file.id)?.state == .localNew)
		#expect(try store.queuedOperations().map(\.kind) == [.upload])
	}

	@Test func deleteDuringUploadDoesNotWedgeTheQueue() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		try listRoot(store, [RemoteEntry(key: "f", size: 4, etag: "e")])
		let file = try #require(try store.root("f"))
		try store.fillCache(file.id, offset: 0, data: Data("data".utf8), etag: "e")
		try store.write(file.id, offset: 0, data: Data("edit".utf8))
		let upload = try #require(try store.markInFlight(store.nextBatch(limit: 1).map(\.id)).first)
		try store.delete(file.id)
		try store.fail(upload.id, retryAfter: Date())

		#expect(try store.nextBatch(limit: 10).map(\.kind) == [.delete])
	}

	@Test func deleteAfterAnInterruptedUploadStillDeletesRemotely() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		do {
			let store = try LocalStore(directory: dir)
			try store.createFile(in: Item.rootId, name: "f")
			// The PUT may land before the crash.
			_ = try store.markInFlight(store.nextBatch(limit: 1).map(\.id))
		}
		let store = try LocalStore(directory: dir)
		try store.delete(try #require(try store.root("f")).id)

		let ops = try store.queuedOperations()
		#expect(ops.map(\.kind) == [.delete])
		#expect(ops.first?.key == "f")
	}

	@Test func renameAfterATriedMoveQueuesASecondMove() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		let folder = try store.createDirectory(in: Item.rootId, name: "a")
		try syncAll(store)
		try store.rename(folder.id, to: Item.rootId, name: "b")
		// Part of the prefix may have moved before the failure.
		let move = try #require(try store.markInFlight(store.nextBatch(limit: 1).map(\.id)).first)
		try store.fail(move.id, retryAfter: Date())
		try store.rename(folder.id, to: Item.rootId, name: "c")

		let ops = try store.queuedOperations()
		#expect(ops.map(\.fromKey) == ["a/", "b/"])
		#expect(ops.map(\.key) == ["b/", "c/"])
	}

	@Test func setMtimeQueuesATouchOnlyWithoutAPendingUpload() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		let file = try store.createFile(in: Item.rootId, name: "f")
		try store.setMtime(file.id, to: Date(timeIntervalSince1970: 1))
		#expect(try store.queuedOperations().map(\.kind) == [.upload])
		try syncAll(store)

		try store.setMtime(file.id, to: Date(timeIntervalSince1970: 2))
		try store.setMtime(file.id, to: Date(timeIntervalSince1970: 3))
		#expect(try store.queuedOperations().map(\.kind) == [.touch])
		#expect(try store.item(file.id)?.mtime == Date(timeIntervalSince1970: 3))
	}
}
