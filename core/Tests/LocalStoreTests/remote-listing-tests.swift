import Foundation
import Testing
@testable import LocalStore

@Suite struct RemoteListingTests {
	@Test func mergeWithoutLocalChanges() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		try listRoot(store, [
			RemoteEntry(key: "a.txt", size: 10, etag: "e1"),
			RemoteEntry(key: "docs/"),
		])
		let a = try #require(try store.root("a.txt"))
		#expect(a.state == .synced)
		#expect(a.remoteKey == "a.txt")
		#expect(a.size == 10)
		let docs = try #require(try store.root("docs"))
		#expect(docs.isDirectory)

		try store.applyRemoteListing(docs.id, entries: [RemoteEntry(key: "docs/n.md", size: 3, etag: "n1")], listedAt: Date())
		#expect(try store.path(of: #require(try store.lookup(parent: docs.id, name: "n.md")).id) == "docs/n.md")

		try store.fillCache(a.id, offset: 0, data: bytes(7, 10), etag: "e1")
		#expect(try store.item(a.id)?.contentState == .full)

		// Remote change: new metadata, stale cache dropped. Remote removal: gone here too.
		try listRoot(store, [RemoteEntry(key: "a.txt", size: 20, etag: "e2")])
		let updated = try #require(try store.item(a.id))
		#expect(updated.size == 20)
		#expect(updated.remoteEtag == "e2")
		#expect(updated.contentState == ContentState.none)
		#expect(try store.read(a.id, range: 0..<20) == .missing([0..<20], etag: "e2"))
		#expect(try store.root("docs") == nil)
		#expect(try store.queuedOperations().isEmpty)
	}

	@Test func modifiedLocallyAndRemotelyKeepsBoth() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		try listRoot(store, [RemoteEntry(key: "a.txt", size: 5, etag: "e1")])
		let a = try #require(try store.root("a.txt"))
		try store.write(a.id, offset: 0, data: Data("local".utf8))

		try listRoot(store, [RemoteEntry(key: "a.txt", size: 6, etag: "e2")])

		let local = try #require(try store.item(a.id))
		#expect(local.name == "a.txt")
		#expect(local.state == .localModified)
		#expect(local.remoteKey == nil)

		let copyName = conflictName(for: "a.txt", date: Date())
		let copy = try #require(try store.root(copyName))
		#expect(copy.state == .conflict)
		#expect(copy.remoteKey == "a.txt")
		#expect(copy.remoteEtag == "e2")

		// The remote version moves aside before the local upload overwrites its key.
		let ops = try store.queuedOperations()
		#expect(ops.map(\.kind) == [.move, .upload])
		#expect(ops.first?.fromKey == "a.txt")
		#expect(ops.first?.key == copyName)

		try syncAll(store)
		#expect(try store.item(copy.id)?.state == .synced)
		#expect(try store.item(copy.id)?.remoteKey == copyName)
		#expect(try store.item(a.id)?.remoteKey == "a.txt")
	}

	@Test func newLocalFileAndNewRemoteFileWithSameName() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		let local = try store.createFile(in: Item.rootId, name: "n.txt")
		try listRoot(store, [RemoteEntry(key: "n.txt", size: 1, etag: "r1")])

		#expect(try store.root("n.txt")?.id == local.id)
		#expect(try store.root(conflictName(for: "n.txt", date: Date()))?.remoteEtag == "r1")
		#expect(try store.queuedOperations().map(\.kind) == [.move, .upload])
	}

	@Test func localChangesSurviveRemoteDeletionAndDeletesAreNotUndone() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		try listRoot(store, [RemoteEntry(key: "keep", size: 1, etag: "k"), RemoteEntry(key: "gone", size: 1, etag: "g")])
		let keep = try #require(try store.root("keep"))
		let gone = try #require(try store.root("gone"))
		try store.write(keep.id, offset: 0, data: Data("x".utf8))
		try store.delete(gone.id)

		// Remote still lists `gone` (delete queued) and no longer lists `keep`.
		try listRoot(store, [RemoteEntry(key: "gone", size: 1, etag: "g")])

		let kept = try #require(try store.item(keep.id))
		#expect(kept.state == .localModified)
		#expect(kept.remoteKey == nil)
		#expect(try store.root("gone") == nil)
		#expect(try store.item(gone.id)?.state == .deletedPending)
	}

	@Test func listingOlderThanAnUploadDoesNotUndoIt() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		let listedAt = Date()
		let file = try store.createFile(in: Item.rootId, name: "fresh")
		try syncAll(store)

		try store.applyRemoteListing(Item.rootId, entries: [], listedAt: listedAt)
		#expect(try store.item(file.id)?.state == .synced)
	}

	@Test func fileAndDirectoryWithTheSameKey() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		let entries = [RemoteEntry(key: "foo", size: 3, etag: "f"), RemoteEntry(key: "foo/")]
		try listRoot(store, entries)
		try listRoot(store, entries)

		#expect(try store.root("foo")?.isDirectory == true)
		let file = try #require(try store.root("foo (file)"))
		#expect(file.remoteKey == "foo")
		#expect(try store.children(of: Item.rootId).count == 2)
		#expect(try store.queuedOperations().isEmpty)

		// A directory appearing next to an existing file: the file takes the alias.
		try listRoot(store, entries + [RemoteEntry(key: "bar", size: 1, etag: "b")])
		try listRoot(store, entries + [RemoteEntry(key: "bar", size: 1, etag: "b"), RemoteEntry(key: "bar/")])
		#expect(try store.root("bar")?.isDirectory == true)
		#expect(try store.root("bar (file)")?.remoteKey == "bar")
		#expect(try store.queuedOperations().isEmpty)
	}
}

@Suite struct RemoteListingEdgeTests {
	@Test func conflictMoveRunsBeforeAnyUploadToTheSameKey() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		try listRoot(store, [RemoteEntry(key: "a", size: 1, etag: "e1")])
		let original = try #require(try store.root("a"))
		try store.fillCache(original.id, offset: 0, data: Data("1".utf8), etag: "e1")
		try store.write(original.id, offset: 0, data: Data("2".utf8))
		try store.rename(original.id, to: Item.rootId, name: "b")
		let replacement = try store.createFile(in: Item.rootId, name: "a")

		// A listing that predates the rename shows `a` changed remotely.
		try listRoot(store, [RemoteEntry(key: "a", size: 1, etag: "e2")])

		let ops = try store.queuedOperations()
		#expect(ops.first?.kind == .move)
		#expect(ops.first?.fromKey == "a")
		#expect(ops.first?.key == conflictName(for: "a", date: Date()))
		#expect(ops.dropFirst().map(\.itemId) == [original.id, original.id, replacement.id])
	}

	@Test func aliasKeyCannotBeReused() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		try listRoot(store, [RemoteEntry(key: "foo", size: 1, etag: "f"), RemoteEntry(key: "foo/")])
		try listRoot(store, [RemoteEntry(key: "foo", size: 1, etag: "f")])
		#expect(try store.root("foo") == nil)
		#expect(throws: StoreError.exists) { try store.createFile(in: Item.rootId, name: "foo") }

		let other = try store.createFile(in: Item.rootId, name: "other")
		#expect(throws: StoreError.exists) { try store.rename(other.id, to: Item.rootId, name: "foo") }
	}

	@Test func remoteDeletionRetargetsQueuedUploads() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		try listRoot(store, [RemoteEntry(key: "a", size: 1, etag: "e")])
		let file = try #require(try store.root("a"))
		try store.fillCache(file.id, offset: 0, data: Data("1".utf8), etag: "e")
		try store.write(file.id, offset: 0, data: Data("2".utf8))
		try store.rename(file.id, to: Item.rootId, name: "b")

		try listRoot(store, [])

		let ops = try store.queuedOperations()
		#expect(ops.map(\.kind) == [.upload])
		#expect(ops.first?.key == "b")
	}

	@Test func listingOlderThanAMoveOrDeleteIsIgnored() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		try listRoot(store, [RemoteEntry(key: "a", size: 1, etag: "e"), RemoteEntry(key: "x", size: 1, etag: "x")])
		let a = try #require(try store.root("a"))
		let x = try #require(try store.root("x"))
		let listedAt = Date()
		try store.rename(a.id, to: Item.rootId, name: "b")
		try store.delete(x.id)
		try syncAll(store)

		let stale = [RemoteEntry(key: "a", size: 1, etag: "e"), RemoteEntry(key: "x", size: 1, etag: "x")]
		try store.applyRemoteListing(Item.rootId, entries: stale, listedAt: listedAt)
		#expect(try store.children(of: Item.rootId).map(\.name) == ["b"])
		#expect(try store.item(a.id)?.remoteKey == "b")
	}
}
