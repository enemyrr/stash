import Foundation
import LocalStore
@testable import S3Client
@testable import SyncEngine
import Testing

/// The engine against an in-memory bucket, without encryption.
@Suite struct EngineTests {
	let directory = FileManager.default.temporaryDirectory.appendingPathComponent("engine-\(UUID().uuidString)")
	let store: LocalStore
	let engine: SyncEngine
	let bucket: FakeBucket

	init() throws {
		store = try LocalStore(directory: directory)
		let (client, bucket) = FakeS3.client()
		self.bucket = bucket
		engine = SyncEngine(store: store, client: client, keys: KeyMapper(cipher: nil))
	}

	/// Lists `dirId` and waits for it.
	func list(_ dirId: Int64 = Item.rootId) async {
		await engine.ensureListed(dirId, timeout: .seconds(5))
	}

	/// Runs the engine until `done` holds.
	func run(until done: () throws -> Bool) async throws {
		engine.start()
		defer { Task { [engine] in await engine.stop() } }
		let deadline = Date().addingTimeInterval(20)
		while try !done() {
			guard Date() < deadline else { throw SyncEngine.Failure.timedOut }
			engine.kick()
			try await Task.sleep(for: .milliseconds(50))
		}
	}

	func runQueue() async throws {
		try await run { try store.queuedOperations().isEmpty }
	}

	func content(_ key: String) -> String? {
		bucket.object(key).map { String(decoding: $0.data, as: UTF8.self) }
	}

	@Test func readsRcloneMtimeAfterListing() async throws {
		bucket.put("a.txt", "a", metadata: ["mtime": "1700000000.5"])
		bucket.put("b.txt", "b")
		await list()
		let a = try #require(try store.lookup(parent: Item.rootId, name: "a.txt"))
		try await run { try store.filesNeedingRemoteMtime(in: Item.rootId).isEmpty }
		#expect(try store.item(a.id)?.mtime == Date(timeIntervalSince1970: 1_700_000_000.5))
		let b = try #require(try store.lookup(parent: Item.rootId, name: "b.txt"))
		#expect(abs(b.mtime.timeIntervalSinceNow) < 60)
	}

	@Test func uploadSendsMtimeAndTouchUpdatesItInPlace() async throws {
		let file = try store.createFile(in: Item.rootId, name: "new.txt")
		try store.write(file.id, offset: 0, data: Data("hello".utf8))
		try store.setMtime(file.id, to: Date(timeIntervalSince1970: 1_600_000_000.25))
		try await runQueue()
		#expect(bucket.object("new.txt")?.metadata["mtime"] == "1600000000.25")

		try store.setMtime(file.id, to: Date(timeIntervalSince1970: 1_500_000_000))
		#expect(try store.queuedOperations().map(\.kind) == [.touch])
		try await runQueue()
		let object = try #require(bucket.object("new.txt"))
		#expect(object.metadata["mtime"] == "1500000000")
		#expect(content("new.txt") == "hello")
		#expect(try store.item(file.id)?.remoteEtag == object.etag)
		#expect(try store.read(file.id, range: 0..<5) == .data(Data("hello".utf8)))
	}

	@Test func editOfAnOutdatedVersionKeepsTheRemoteOneAsConflict() async throws {
		bucket.put("a.txt", "old")
		await list()
		let a = try #require(try store.lookup(parent: Item.rootId, name: "a.txt"))
		try store.fillCache(a.id, offset: 0, data: Data("old".utf8), etag: a.remoteEtag)
		bucket.put("a.txt", "remote")
		try store.write(a.id, offset: 0, data: Data("local".utf8))
		try await runQueue()
		#expect(content("a.txt") == "local")
		let conflict = try #require(bucket.keys.first { $0.hasPrefix("a (conflict") })
		#expect(content(conflict) == "remote")
	}

	@Test func directoryMoveKeepsSourcesThatWereNotCopied() async throws {
		bucket.put("dir/x", "x")
		bucket.put("dir/y", "y")
		await list()
		let dir = try #require(try store.lookup(parent: Item.rootId, name: "dir"))
		bucket.failCopies(from: "dir/y")
		try store.rename(dir.id, to: Item.rootId, name: "moved")
		try await run { try store.queuedOperations().first?.attempts ?? 0 > 0 }
		#expect(bucket.keys == ["dir/y", "moved/x"])
	}

	@Test func directoryDeleteLeavesObjectsTheStoreDoesNotKnow() async throws {
		bucket.put("d/")
		await list()
		let d = try #require(try store.lookup(parent: Item.rootId, name: "d"))
		await list(d.id)
		bucket.put("d/late.txt", "late")
		try store.delete(d.id)
		try await runQueue()
		#expect(bucket.keys == ["d/late.txt"])
	}

	@Test func rcloneMtimeFormat() {
		#expect(SyncEngine.rcloneMtime(Date(timeIntervalSince1970: 1_783_019_161.5)) == "1783019161.5")
		#expect(SyncEngine.rcloneMtime(Date(timeIntervalSince1970: 1_783_019_160)) == "1783019160")
		#expect(SyncEngine.date(rcloneMtime: "1783019161.590893708")?.timeIntervalSince1970 == 1_783_019_161.590893708)
		#expect(SyncEngine.date(rcloneMtime: "nope") == nil)
	}
}
