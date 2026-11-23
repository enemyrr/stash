import Foundation
import LocalStore
import RcloneCrypt
import S3Client
import os

/// Keeps one drive's `LocalStore` in sync with its bucket in the background: lists directories,
/// drains the operation queue, and downloads file content on request.
///
/// The file system reaches the network only through `ensureListed`, `fetch`, and `ensureResident`, which wait a bounded time.
/// Every failure is retried later; nothing here blocks a caller indefinitely.
public final class SyncEngine: Sendable {
	public enum Failure: Error {
		case timedOut
		case offline
		case notUploaded
		case missingContent
		case deleteFailed(count: Int)
	}

	public let store: LocalStore
	let client: S3Client
	let keys: KeyMapper
	let shouldDeferUpload: @Sendable (Int64) -> Bool
	private let state = OSAllocatedUnfairLock(initialState: State())
	private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "StashCore", category: "sync")

	static let maxOperations = 4
	/// Unit of content download. Small enough that a slow but working network shows progress within `stall`.
	static let chunkSize: Int64 = 2 << 20
	static let fetchWindow = 4
	/// A visited directory is listed again when its listing is older than this.
	static let listingTTL: TimeInterval = 15
	/// Directories not visited for this long are no longer refreshed.
	static let visitWindow: TimeInterval = 600
	static let maxRetryDelay: TimeInterval = 60

	private struct ChunkKey: Hashable {
		let id: Int64
		let index: Int64
		let etag: String?
	}

	private struct State: Sendable {
		var loop: Task<Void, Never>?
		var isKicked = false
		var runningOperations = 0
		var listings: [Int64: Task<Void, any Error>] = [:]
		var chunks: [ChunkKey: Task<Void, any Error>] = [:]
		/// When a chunk of the file last arrived.
		var progress: [Int64: ContinuousClock.Instant] = [:]
		/// rclone crypt file headers by item, with the version they belong to.
		var headers: [Int64: (etag: String?, data: Data)] = [:]
		var listedAt: [Int64: Date] = [:]
		var visitedAt: [Int64: Date] = [:]
		var isOffline = false
	}

	/// `shouldDeferUpload` holds back uploads of files that are still being written.
	public init(
		store: LocalStore, client: S3Client, keys: KeyMapper,
		shouldDeferUpload: @escaping @Sendable (Int64) -> Bool = { _ in false }
	) {
		self.store = store
		self.client = client
		self.keys = keys
		self.shouldDeferUpload = shouldDeferUpload
	}

	/// True after a network failure, until the next successful request.
	public var isOffline: Bool { state.withLock { $0.isOffline } }

	public func start() {
		state.withLock { state in
			guard state.loop == nil else { return }
			state.loop = Task.detached { [self] in await runLoop() }
		}
	}

	public func stop() {
		state.withLock { state in
			defer { state.loop = nil }
			return state.loop
		}?.cancel()
	}

	/// Runs queued operations now instead of at the next tick.
	public func kick() {
		state.withLock { $0.isKicked = true }
	}

	private func runLoop() async {
		var refreshedAt = Date.distantPast
		while !Task.isCancelled {
			startReadyOperations()
			if Date().timeIntervalSince(refreshedAt) >= Self.listingTTL {
				refreshedAt = Date()
				refreshVisitedDirectories()
			}
			for _ in 0..<8 where !state.withLock({ $0.isKicked }) {
				try? await Task.sleep(for: .milliseconds(250))
			}
			state.withLock { $0.isKicked = false }
		}
	}

	// MARK: Listing

	/// Lists the directory in the background when its listing is stale, and keeps it fresh while it is visited.
	public func requestListing(_ dirId: Int64) {
		let isDue = state.withLock { state in
			state.visitedAt[dirId] = Date()
			return Date().timeIntervalSince(state.listedAt[dirId] ?? .distantPast) >= Self.listingTTL
		}
		if isDue { startListing(dirId) }
	}

	/// Like `requestListing`, but waits at most `timeout` for the listing when nothing is known about the directory yet.
	public func ensureListed(_ dirId: Int64, timeout: Duration) async {
		requestListing(dirId)
		let isUnknown = state.withLock { $0.listedAt[dirId] == nil && !$0.isOffline }
		guard isUnknown, (try? store.children(of: dirId, limit: 1).isEmpty) == true else { return }
		try? await Self.wait(for: startListing(dirId), timeout: timeout)
	}

	/// True when the directory was listed since the engine started, so its local children are complete.
	public func hasListed(_ dirId: Int64) -> Bool {
		state.withLock { $0.listedAt[dirId] != nil }
	}

	@discardableResult
	private func startListing(_ dirId: Int64) -> Task<Void, any Error> {
		state.withLock { state in
			if let task = state.listings[dirId] { return task }
			let task = Task<Void, any Error>.detached { [self] in
				await list(dirId)
				self.state.withLock { _ = $0.listings.removeValue(forKey: dirId) }
			}
			state.listings[dirId] = task
			return task
		}
	}

	private func refreshVisitedDirectories() {
		let now = Date()
		let due = state.withLock { state in
			state.visitedAt.filter { now.timeIntervalSince($0.value) < Self.visitWindow }.keys.filter {
				now.timeIntervalSince(state.listedAt[$0] ?? .distantPast) >= Self.listingTTL
			}
		}
		for dirId in due { startListing(dirId) }
	}

	private func list(_ dirId: Int64) async {
		do {
			guard let dir = try store.item(dirId), dir.isDirectory, dir.state != .deletedPending else { return }
			let listedAt = Date()
			// A directory that never reached the bucket has nothing to list.
			if let prefix = dir.remoteKey {
				let remotePrefix = keys.remoteKey(prefix)
				let result = try await client.listAll(prefix: remotePrefix.isEmpty ? nil : remotePrefix, delimiter: "/")
				let entries = keys.entries(result, prefix: prefix, listedAt: listedAt)
				try store.applyRemoteListing(dirId, entries: entries, listedAt: listedAt)
				noteSuccess()
			}
			state.withLock { $0.listedAt[dirId] = listedAt }
		} catch {
			noteFailure(error, "List")
		}
	}

	// MARK: Content

	/// Caches `range` of a file, fetching its missing chunks at most `fetchWindow` at a time. Waits while chunks keep
	/// arriving: throws `timedOut` after `stall` without one, and `offline` at once while offline, so callers such as
	/// thumbnailers don't queue up behind the network. Fetches still running when this throws finish in the background.
	public func fetch(_ id: Int64, range: Range<Int64>, stall: Duration) async throws {
		let start = ContinuousClock.now
		var running: [Task<Void, any Error>] = []
		for index in Self.chunks(range) {
			if let task = try startChunk(id, index) { running.append(task) }
			if running.count >= Self.fetchWindow { try await wait(for: running.removeFirst(), id, since: start, stall: stall) }
		}
		for task in running { try await wait(for: task, id, since: start, stall: stall) }
	}

	/// Like `fetch` for the whole file.
	public func ensureResident(_ id: Int64, stall: Duration) async throws {
		guard let item = try store.item(id), !item.isDirectory else { return }
		try await fetch(id, range: 0..<item.size, stall: stall)
	}

	/// Starts fetching `range` in the background, for read-ahead. Does nothing while offline.
	public func prefetch(_ id: Int64, range: Range<Int64>) {
		for index in Self.chunks(range) { _ = try? startChunk(id, index) }
	}

	private static func chunks(_ range: Range<Int64>) -> Range<Int64> {
		range.isEmpty ? 0..<0 : range.lowerBound / chunkSize..<(range.upperBound - 1) / chunkSize + 1
	}

	/// Starts fetching the missing blocks of chunk `index`, or returns the fetch already underway.
	/// Returns nil when the chunk is cached.
	private func startChunk(_ id: Int64, _ index: Int64) throws -> Task<Void, any Error>? {
		let (missing, etag) = try store.missingRanges(id, in: index * Self.chunkSize..<(index + 1) * Self.chunkSize)
		guard let first = missing.first, let last = missing.last else { return nil }
		let key = ChunkKey(id: id, index: index, etag: etag)
		return try state.withLock { state in
			if let task = state.chunks[key] { return task }
			guard !state.isOffline else { throw Failure.offline }
			let task = Task<Void, any Error>.detached { [self] in
				defer { self.state.withLock { _ = $0.chunks.removeValue(forKey: key) } }
				do {
					let started = ContinuousClock.now
					try await download(id, first.lowerBound..<last.upperBound, etag: etag)
					Self.log.debug("Fetched \(id) chunk \(index) in \(ContinuousClock.now - started, privacy: .public)")
					self.state.withLock { $0.progress[id] = .now }
					noteSuccess()
				} catch {
					noteFailure(error, "Download")
					throw error
				}
			}
			state.chunks[key] = task
			return task
		}
	}

	/// Waits for `task` while the file's chunks keep arriving.
	private func wait(for task: Task<Void, any Error>, _ id: Int64, since start: ContinuousClock.Instant, stall: Duration) async throws {
		while true {
			let deadline = max(start, state.withLock { $0.progress[id] } ?? start) + stall
			guard deadline > .now else { throw Failure.timedOut }
			do {
				return try await Self.wait(for: task, timeout: deadline - .now)
			} catch Failure.timedOut {}
		}
	}

	/// Fetches block-aligned `range` of remote version `etag` with a Range GET and caches it.
	/// rclone crypt needs the file's 32-byte header too; it is fetched once per version, alongside the first chunk.
	private func download(_ id: Int64, _ range: Range<Int64>, etag: String?) async throws {
		guard let item = try store.item(id), !item.isDirectory else { return }
		guard let plainKey = item.remoteKey else { throw Failure.notUploaded }
		let key = keys.remoteKey(plainKey)
		let data: Data
		if let cipher = keys.cipher {
			guard let span = RcloneCipher.contentRange(plainOffset: range.lowerBound, length: Int64(range.count), plainSize: item.size)
			else { return }
			let end = span.encryptedOffset + span.encryptedLength - 1
			let headerSize = Int64(RcloneCipher.headerSize)
			var header = state.withLock { $0.headers[id] }.flatMap { $0.etag == etag ? $0.data : nil }
			let blocks: Data
			if header == nil, span.firstBlock == 0 {
				let bytes = try await client.get(key, range: 0...end, ifMatch: etag)
				header = bytes.prefix(Int(headerSize))
				blocks = bytes.dropFirst(Int(headerSize))
			} else {
				let needsHeader = header == nil
				async let fetchedHeader = needsHeader ? client.get(key, range: 0...headerSize - 1, ifMatch: etag) : nil
				blocks = try await client.get(key, range: span.encryptedOffset...end, ifMatch: etag)
				if let fetched = try await fetchedHeader { header = fetched }
			}
			let fileHeader = Data(header ?? Data())
			state.withLock { $0.headers[id] = (etag, fileHeader) }
			data = try cipher.decrypt(range: span, header: fileHeader, blocks: Data(blocks))
		} else {
			data = try await client.get(key, range: range.lowerBound...range.upperBound - 1, ifMatch: etag)
		}
		// False when a listing replaced the version meanwhile; the next read starts over.
		try store.fillCache(id, offset: range.lowerBound, data: data, etag: etag)
	}

	// MARK: Operations

	private func startReadyOperations() {
		let free = Self.maxOperations - state.withLock { $0.runningOperations }
		guard free > 0 else { return }
		let claimed: [SyncOperation]
		do {
			let ready = try store.nextBatch(limit: 32).filter { $0.kind != .upload || !shouldDeferUpload($0.itemId) }
			guard !ready.isEmpty else { return }
			claimed = try store.markInFlight(ready.prefix(free).map(\.id))
		} catch {
			Self.log.error("Claim failed: \(String(describing: error), privacy: .public)")
			return
		}
		state.withLock { $0.runningOperations += claimed.count }
		for op in claimed {
			Task.detached { [self] in
				await run(op)
				state.withLock {
					$0.runningOperations -= 1
					$0.isKicked = true
				}
			}
		}
	}

	private func run(_ op: SyncOperation) async {
		do {
			let etag = try await perform(op)
			try store.complete(op.id, etag: etag)
			noteSuccess()
		} catch {
			noteFailure(error, "Operation")
			let delay = min(pow(2, Double(op.attempts)), Self.maxRetryDelay)
			try? store.fail(op.id, retryAfter: Date().addingTimeInterval(delay))
			// The key is taken remotely: a fresh listing turns the remote version into a conflict copy.
			if (error as? S3Error) == .preconditionFailed, let parent = try? store.item(op.itemId)?.parentId {
				startListing(parent)
			}
		}
	}

	/// Returns the new ETag for uploads.
	private func perform(_ op: SyncOperation) async throws -> String? {
		let key = keys.remoteKey(op.key)
		switch op.kind {
		case .upload:
			guard let content = op.contentURL else { throw Failure.missingContent }
			// Only a first upload of a new file checks that the key is free. A retry may follow an attempt that landed
			// without a reply, so it overwrites: last writer wins, as for edits of existing files.
			let isCreate = try store.item(op.itemId)?.remoteKey == nil && op.attempts == 0
			return try await upload(content, to: key, isCreate: isCreate)
		case .mkdir:
			// S3 has no directories. A zero-byte `dir/` marker keeps empty ones; rclone lists it as a directory.
			try await client.put(key, data: Data())
			return nil
		case .move:
			try await move(from: keys.remoteKey(op.fromKey ?? ""), to: key)
			return nil
		case .delete:
			try await delete(key)
			return nil
		}
	}

	private func upload(_ content: URL, to key: String, isCreate: Bool) async throws -> String {
		var file = content
		let encrypted = store.makeStagingURL()
		defer { try? FileManager.default.removeItem(at: encrypted) }
		if let cipher = keys.cipher {
			try cipher.encryptFile(at: content, to: encrypted)
			file = encrypted
		}
		guard isCreate else { return try await client.put(key, fileURL: file) }
		// Hetzner ignores conditions on CompleteMultipartUpload, so big files check with HEAD first.
		let size = try Int64(file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
		guard size >= client.config.multipart.threshold else {
			return try await client.put(key, fileURL: file, condition: .ifNoneMatch("*"))
		}
		do {
			_ = try await client.head(key)
			throw S3Error.preconditionFailed
		} catch S3Error.notFound {
			return try await client.put(key, fileURL: file)
		}
	}

	/// Server-side copy and delete, per object for a prefix. A missing source counts as moved.
	/// Encrypted names are encrypted per segment, so keys below a moved prefix keep their suffix.
	private func move(from: String, to: String) async throws {
		guard from.hasSuffix("/") else {
			if try await copy(from, to) { try await client.delete(from) }
			return
		}
		let objects = try await client.listAll(prefix: from).objects
		for object in objects {
			_ = try await copy(object.key, to + String(decoding: object.key.utf8.dropFirst(from.utf8.count), as: UTF8.self))
		}
		try await deleteKeys(objects.map(\.key))
	}

	/// Returns false when the source does not exist.
	private func copy(_ source: String, _ destination: String) async throws -> Bool {
		do {
			try await client.copy(from: source, to: destination)
			return true
		} catch S3Error.notFound {
			return false
		}
	}

	/// A key ending in `/` deletes the whole prefix. Missing keys count as deleted.
	private func delete(_ key: String) async throws {
		guard key.hasSuffix("/") else { return try await client.delete(key) }
		try await deleteKeys(client.listAll(prefix: key).objects.map(\.key))
	}

	/// Batches of 100 keep each request well inside Hetzner's time limits.
	private func deleteKeys(_ keys: [String]) async throws {
		for start in stride(from: 0, to: keys.count, by: 100) {
			let failures = try await client.deleteObjects(Array(keys[start..<min(start + 100, keys.count)]))
			guard failures.isEmpty else { throw Failure.deleteFailed(count: failures.count) }
		}
	}

	// MARK: Helpers

	private func noteSuccess() {
		state.withLock { $0.isOffline = false }
	}

	private func noteFailure(_ error: any Error, _ context: StaticString) {
		if case .network? = error as? S3Error { state.withLock { $0.isOffline = true } }
		Self.log.error("\(context, privacy: .public) failed: \(String(describing: error), privacy: .public)")
	}

	/// Waits for `task` at most `timeout`. On timeout the task keeps running.
	static func wait(for task: Task<Void, any Error>, timeout: Duration) async throws {
		let pending = OSAllocatedUnfairLock<CheckedContinuation<Void, any Error>?>(initialState: nil)
		try await withCheckedThrowingContinuation { continuation in
			pending.withLock { $0 = continuation }
			Task {
				let result = await task.result
				pending.withLock { $0.take() }?.resume(with: result)
			}
			Task {
				try? await Task.sleep(for: timeout)
				pending.withLock { $0.take() }?.resume(throwing: Failure.timedOut)
			}
		}
	}
}
