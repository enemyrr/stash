import FSKit
import LocalStore
import S3Client
import SyncEngine
import os

/// A drive's volume, served from its LocalStore. The network is reached only through the engine's
/// bounded waits: a first listing of an unknown directory, and fetching the uncached part of a read.
final class StashVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations, FSVolume.OpenCloseOperations,
	FSVolume.XattrOperations
{
	static let networkWait: Duration = .milliseconds(2500)
	/// A read of uncached bytes fails with EIO when no chunk of the file arrives for this long.
	static let fetchStall: Duration = .seconds(10)
	/// Read-ahead for files read in order, such as playing video.
	static let readAhead: Int64 = 8 << 20
	/// Files up to this size are downloaded whole when opened.
	static let hydrateLimit: Int64 = 16 << 20
	/// Refused so Spotlight never indexes the volume. Other macOS bookkeeping is kept local-only by the store.
	static let spotlightName = ".Spotlight-V100"
	static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Stash", category: "volume")

	let store: LocalStore
	let engine: SyncEngine
	private let nodes: NodeTable
	private let root: StashNode
	/// Read-only files served at the root: an empty .metadata_never_index so Spotlight leaves the volume alone,
	/// and the volume icon.
	private let virtualFiles: [String: StashNode] = [
		".metadata_never_index": StashNode(id: Int64.max - 1, isDirectory: false, virtualContent: Data()),
		".VolumeIcon.icns": StashNode(
			id: Int64.max - 2, isDirectory: false,
			virtualContent: Bundle.main.url(forResource: "VolumeIcon", withExtension: "icns").flatMap { try? Data(contentsOf: $0) }
				?? Data()),
	]

	init(config: DriveConfig, store: LocalStore, client: S3Client, keys: KeyMapper) {
		let nodes = NodeTable()
		self.nodes = nodes
		self.store = store
		engine = SyncEngine(store: store, client: client, keys: keys) { nodes.existing($0)?.isBusy ?? false }
		root = nodes.node(Item.rootId, isDirectory: true)
		super.init(volumeID: FSVolume.Identifier(uuid: config.id), volumeName: FSFileName(string: config.name))
	}

	// MARK: Volume

	var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
		let capabilities = FSVolume.SupportedCapabilities()
		capabilities.supportsPersistentObjectIDs = true
		capabilities.supports64BitObjectIDs = true
		capabilities.supportsHiddenFiles = true
		capabilities.supportsFastStatFS = true
		capabilities.supportsSparseFiles = true
		capabilities.supports2TBFiles = true
		capabilities.caseFormat = .sensitive
		return capabilities
	}

	/// Capacity is the cache budget: unsynced data must fit in it.
	var volumeStatistics: FSStatFSResult {
		let stats = FSStatFSResult(fileSystemTypeName: "stashfs")
		let usage = try? store.usage()
		let total = UInt64(store.cacheBudget)
		let available = UInt64(max(0, store.cacheBudget - (usage?.dirtyBytes ?? 0)))
		stats.blockSize = 4096
		stats.ioSize = 1 << 20
		stats.totalBytes = total
		stats.availableBytes = available
		stats.freeBytes = available
		stats.usedBytes = total - available
		stats.totalBlocks = total / 4096
		stats.availableBlocks = available / 4096
		stats.freeBlocks = available / 4096
		stats.usedBlocks = (total - available) / 4096
		stats.totalFiles = UInt64(Int32.max)
		stats.freeFiles = UInt64(Int32.max)
		return stats
	}

	var maximumLinkCount: Int { 1 }
	var maximumNameLength: Int { 255 }
	var restrictsOwnershipChanges: Bool { true }
	var truncatesLongNames: Bool { false }
	var maximumFileSize: UInt64 { UInt64(Int64.max) }
	var maximumXattrSize: Int { 1 << 16 }

	func activate(options: FSTaskOptions, replyHandler: @escaping (FSItem?, (any Error)?) -> Void) {
		engine.start()
		engine.requestListing(Item.rootId)
		replyHandler(root, nil)
	}

	func deactivate(options: FSDeactivateOptions = [], replyHandler: @escaping ((any Error)?) -> Void) {
		commitAll(logging: "deactivate")
		Task {
			await engine.stop()
			replyHandler(nil)
		}
	}

	func mount(options: FSTaskOptions, replyHandler: @escaping ((any Error)?) -> Void) {
		replyHandler(nil)
	}

	func unmount(replyHandler: @escaping () -> Void) {
		commitAll(logging: "unmount")
		replyHandler()
	}

	func synchronize(flags: FSSyncFlags, replyHandler: @escaping ((any Error)?) -> Void) {
		replyHandler(commitAll())
	}

	// MARK: Items

	func lookupItem(named name: FSFileName, inDirectory directory: FSItem, replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
		guard let directory = directory as? StashNode, let string = name.string else {
			return replyHandler(nil, nil, POSIXError(.ENOENT))
		}
		if directory === root, let file = virtualFiles[string] { return replyHandler(file, name, nil) }
		Task {
			do {
				var item = try store.lookup(parent: directory.id, name: string)
				if item == nil {
					await engine.ensureListed(directory.id, timeout: Self.networkWait)
					item = try store.lookup(parent: directory.id, name: string)
				}
				guard let item else { return replyHandler(nil, nil, POSIXError(.ENOENT)) }
				replyHandler(nodes.node(item.id, isDirectory: item.isDirectory), FSFileName(string: item.name), nil)
			} catch {
				replyHandler(nil, nil, Self.posixError(error))
			}
		}
	}

	func reclaimItem(_ item: FSItem, replyHandler: @escaping ((any Error)?) -> Void) {
		guard let node = item as? StashNode, node !== root, node.virtualContent == nil else { return replyHandler(nil) }
		do {
			try node.commit(to: store)
			nodes.remove(node)
		} catch {
			// The node keeps its buffered writes; the next sync or unmount tries again.
			Self.log.error("Keeping unsaved writes on reclaim: \(String(describing: error), privacy: .public)")
		}
		engine.kick()
		replyHandler(nil)
	}

	func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem, replyHandler: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
		guard let node = item as? StashNode else { return replyHandler(nil, POSIXError(.EIO)) }
		do {
			replyHandler(try attributes(of: node), nil)
		} catch {
			replyHandler(nil, Self.posixError(error))
		}
	}

	func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker, replyHandler: @escaping (FSDirectoryVerifier, (any Error)?) -> Void) {
		guard let directory = directory as? StashNode, directory.isDirectory else {
			return replyHandler(verifier, POSIXError(.ENOTDIR))
		}
		Task {
			if cookie.rawValue == 0 {
				await engine.ensureListed(directory.id, timeout: Self.networkWait)
			}
			do {
				let item = try liveItem(directory.id)
				var entries: [(name: String, item: Item)] = []
				var after: String?
				repeat {
					let page = try store.children(of: directory.id, after: after)
					entries += page.map { ($0.name, $0) }
					after = page.count == 1_000 ? page.last?.name : nil
				} while after != nil
				// readdir() wants "." and ".."; getattrlistbulk() (attributes != nil) doesn't.
				if attributes == nil {
					let parent = try item.parentId.map(liveItem) ?? item
					entries = [(".", item), ("..", parent)] + entries
				}
				for (index, entry) in entries.enumerated() where UInt64(index) >= cookie.rawValue {
					let isDirectory = entry.item.isDirectory
					let packed = packer.packEntry(
						name: FSFileName(string: entry.name),
						itemType: isDirectory ? .directory : .file,
						itemID: FSItem.Identifier(rawValue: UInt64(entry.item.id) + 1)!,
						nextCookie: FSDirectoryCookie(rawValue: UInt64(index + 1)),
						attributes: attributes == nil ? nil : makeAttributes(entry.item, pendingEnd: nodes.existing(entry.item.id)?.pendingEnd ?? 0))
					if !packed { break }
				}
				replyHandler(FSDirectoryVerifier(rawValue: 1), nil)
			} catch {
				replyHandler(verifier, Self.posixError(error))
			}
		}
	}

	// MARK: Changes

	func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
		guard let directory = directory as? StashNode, let string = name.string else {
			return replyHandler(nil, nil, POSIXError(.EINVAL))
		}
		guard type == .file || type == .directory else { return replyHandler(nil, nil, POSIXError(.ENOTSUP)) }
		guard string != Self.spotlightName else { return replyHandler(nil, nil, POSIXError(.EPERM)) }
		do {
			let mode = newAttributes.isValid(.mode) ? UInt16(newAttributes.mode & 0o7777) : nil
			let item = type == .directory
				? try store.createDirectory(in: directory.id, name: string, mode: mode ?? 0o755)
				: try store.createFile(in: directory.id, name: string, mode: mode ?? 0o644)
			let node = nodes.node(item.id, isDirectory: item.isDirectory)
			if !item.isDirectory { node.setOpenForWrite(false) }
			engine.kick()
			replyHandler(node, name, nil)
		} catch {
			replyHandler(nil, nil, Self.posixError(error))
		}
	}

	func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem, replyHandler: @escaping ((any Error)?) -> Void) {
		guard let node = item as? StashNode, node !== root, node.virtualContent == nil else {
			return replyHandler(POSIXError(.EPERM))
		}
		Task {
			do {
				if node.isDirectory { try await checkRemovable(node.id) }
				node.discardPending()
				try store.delete(node.id)
				engine.kick()
				replyHandler(nil)
			} catch {
				replyHandler(Self.posixError(error))
			}
		}
	}

	func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?, replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) {
		guard let node = item as? StashNode, let destination = destinationDirectory as? StashNode,
			let name = destinationName.string, node.virtualContent == nil
		else { return replyHandler(nil, POSIXError(.EINVAL)) }
		guard name != Self.spotlightName else { return replyHandler(nil, POSIXError(.EPERM)) }
		Task {
			do {
				if let target = overItem as? StashNode, target.isDirectory { try await checkRemovable(target.id) }
				try store.rename(node.id, to: destination.id, name: name)
				engine.kick()
				replyHandler(destinationName, nil)
			} catch {
				replyHandler(nil, Self.posixError(error))
			}
		}
	}

	func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem, replyHandler: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
		guard let node = item as? StashNode, node.virtualContent == nil else { return replyHandler(nil, POSIXError(.EPERM)) }
		Task {
			do {
				if newAttributes.isValid(.size) {
					let size = Int64(newAttributes.size)
					do {
						try node.flushed(to: store) { try store.truncate(node.id, to: size) }
					} catch StoreError.blocksMissing {
						try await engine.ensureResident(node.id, stall: Self.fetchStall)
						try node.flushed(to: store) { try store.truncate(node.id, to: size) }
					}
					engine.kick()
				}
				if newAttributes.isValid(.modifyTime) {
					// Buffered writes go first, so they don't bump the mtime set here.
					let time = newAttributes.modifyTime
					let mtime = Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9)
					try node.flushed(to: store) { try store.setMtime(node.id, to: mtime) }
					engine.kick()
				}
				// Other times, mode, and flags are accepted but not stored: LocalStore has no setter for them yet.
				newAttributes.consumedAttributes = [
					.size, .mode, .uid, .gid, .flags, .accessTime, .modifyTime, .changeTime, .birthTime, .backupTime, .addedTime,
				]
				replyHandler(try attributes(of: node), nil)
			} catch {
				replyHandler(nil, Self.posixError(error))
			}
		}
	}

	func readSymbolicLink(_ item: FSItem, replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) {
		replyHandler(nil, POSIXError(.EINVAL))
	}

	func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName, replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
		replyHandler(nil, nil, POSIXError(.ENOTSUP))
	}

	func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem, replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) {
		replyHandler(nil, POSIXError(.ENOTSUP))
	}

	// MARK: Open, read, write

	/// Opening for reading never waits: reads fetch what they need. Small files start downloading whole.
	/// Opening for writing downloads the whole file first, because a dirty file must be fully cached.
	func openItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler: @escaping ((any Error)?) -> Void) {
		guard let node = item as? StashNode, !node.isDirectory, node.virtualContent == nil else { return replyHandler(nil) }
		guard modes.contains(.write) else {
			if let size = try? store.item(node.id)?.size, size <= Self.hydrateLimit { engine.prefetch(node.id, range: 0..<size) }
			return replyHandler(nil)
		}
		Task {
			do {
				try await engine.ensureResident(node.id, stall: Self.fetchStall)
				node.setOpenForWrite(true)
				replyHandler(nil)
			} catch {
				replyHandler(Self.posixError(error))
			}
		}
	}

	func closeItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler: @escaping ((any Error)?) -> Void) {
		guard let node = item as? StashNode, !node.isDirectory, node.virtualContent == nil else { return replyHandler(nil) }
		guard !modes.contains(.write) else { return replyHandler(nil) }
		node.setOpenForWrite(false)
		do {
			try node.commit(to: store)
			engine.kick()
			replyHandler(nil)
		} catch {
			replyHandler(Self.posixError(error))
		}
	}

	func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer, replyHandler: @escaping (Int, (any Error)?) -> Void) {
		guard let node = item as? StashNode else { return replyHandler(0, POSIXError(.EIO)) }
		let range = Int64(offset)..<Int64(offset) + Int64(min(length, buffer.length))
		if let content = node.virtualContent {
			let end = Int(min(range.upperBound, Int64(content.count)))
			let data = content.subdata(in: min(Int(range.lowerBound), end)..<end)
			_ = buffer.withUnsafeMutableBytes { data.copyBytes(to: $0) }
			return replyHandler(data.count, nil)
		}
		Task {
			do {
				try node.commit(to: store)
				var result = try store.read(node.id, range: range)
				// A second round covers a version that changed during the first.
				for _ in 0..<2 {
					guard case .missing = result else { break }
					let started = ContinuousClock.now
					try await engine.fetch(node.id, range: range, stall: Self.fetchStall)
					Self.log.debug("Read \(node.id) at \(offset) for \(length) waited \(ContinuousClock.now - started, privacy: .public)")
					result = try store.read(node.id, range: range)
				}
				if node.noteRead(range) { engine.prefetch(node.id, range: range.upperBound..<range.upperBound + Self.readAhead) }
				guard case let .data(data) = result else { return replyHandler(0, POSIXError(.EIO)) }
				_ = buffer.withUnsafeMutableBytes { data.copyBytes(to: $0) }
				replyHandler(data.count, nil)
			} catch {
				replyHandler(0, Self.posixError(error))
			}
		}
	}

	func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler: @escaping (Int, (any Error)?) -> Void) {
		guard let node = item as? StashNode, !node.isDirectory, node.virtualContent == nil else {
			return replyHandler(0, POSIXError(.EISDIR))
		}
		do {
			try node.write(contents, at: Int64(offset), to: store)
			engine.kick()
			replyHandler(contents.count, nil)
		} catch {
			replyHandler(0, Self.posixError(error))
		}
	}

	// MARK: Extended attributes

	/// The root's Finder info sets only the custom-icon flag, so Finder shows .VolumeIcon.icns.
	static let rootFinderInfo: Data = {
		var info = Data(count: 32)
		info[8] = 0x04  // kHasCustomIcon in the big-endian Finder flags at offset 8
		return info
	}()

	/// Accepted and dropped: without xattr support the kernel would write AppleDouble `._` files.
	func getXattr(named name: FSFileName, of item: FSItem, replyHandler: @escaping (Data?, (any Error)?) -> Void) {
		guard item === root, name.string == XATTR_FINDERINFO_NAME else { return replyHandler(nil, POSIXError(.ENOATTR)) }
		replyHandler(Self.rootFinderInfo, nil)
	}

	func setXattr(named name: FSFileName, to value: Data?, on item: FSItem, policy: FSVolume.SetXattrPolicy, replyHandler: @escaping ((any Error)?) -> Void) {
		replyHandler(nil)
	}

	func listXattrs(of item: FSItem, replyHandler: @escaping ([FSFileName]?, (any Error)?) -> Void) {
		replyHandler(item === root ? [FSFileName(string: XATTR_FINDERINFO_NAME)] : [], nil)
	}

	// MARK: Helpers

	private func liveItem(_ id: Int64) throws -> Item {
		guard let item = try store.item(id), item.state != .deletedPending else { throw StoreError.notFound }
		return item
	}

	private func attributes(of node: StashNode) throws -> FSItem.Attributes {
		if let content = node.virtualContent {
			let attributes = FSItem.Attributes()
			attributes.type = .file
			attributes.mode = UInt32(S_IFREG | 0o444)
			attributes.linkCount = 1
			attributes.uid = getuid()
			attributes.gid = getgid()
			attributes.size = UInt64(content.count)
			attributes.allocSize = UInt64(content.count)
			attributes.fileID = node.fileID
			attributes.parentID = root.fileID
			return attributes
		}
		return try node.withPendingEnd { try makeAttributes(liveItem(node.id), pendingEnd: $0) }
	}

	private func makeAttributes(_ item: Item, pendingEnd: Int64) -> FSItem.Attributes {
		let attributes = FSItem.Attributes()
		let size = UInt64(max(item.size, pendingEnd))
		attributes.type = item.isDirectory ? .directory : .file
		attributes.mode = UInt32(item.isDirectory ? S_IFDIR : S_IFREG) | UInt32(item.mode & 0o7777)
		attributes.linkCount = item.isDirectory ? 2 : 1
		attributes.uid = getuid()
		attributes.gid = getgid()
		attributes.flags = 0
		attributes.size = item.isDirectory ? 0 : size
		attributes.allocSize = item.isDirectory ? 0 : (size + 4095) / 4096 * 4096
		attributes.fileID = FSItem.Identifier(rawValue: UInt64(item.id) + 1)!
		attributes.parentID = StashNode.fileID(parent: item.parentId)
		let mtime = Self.timespec(item.mtime)
		attributes.modifyTime = mtime
		attributes.accessTime = mtime
		attributes.changeTime = Self.timespec(item.ctime)
		attributes.birthTime = mtime
		return attributes
	}

	/// Refuses to remove a remote directory whose listing this session hasn't confirmed: it may hold files not known here,
	/// and the queued delete removes the whole prefix.
	private func checkRemovable(_ id: Int64) async throws {
		guard try store.children(of: id, limit: 1).isEmpty else { throw StoreError.notEmpty }
		guard try store.item(id)?.remoteKey != nil, !engine.hasListed(id) else { return }
		await engine.ensureListed(id, timeout: Self.networkWait)
		guard engine.hasListed(id) else { throw POSIXError(.EBUSY) }
		guard try store.children(of: id, limit: 1).isEmpty else { throw StoreError.notEmpty }
	}

	@discardableResult
	private func commitAll(logging context: StaticString? = nil) -> (any Error)? {
		var firstError: (any Error)?
		for node in nodes.all {
			do {
				try node.commit(to: store)
			} catch {
				firstError = firstError ?? error
				if let context {
					Self.log.error("Unsaved writes on \(context, privacy: .public): \(String(describing: error), privacy: .public)")
				}
			}
		}
		engine.kick()
		return firstError.map(Self.posixError)
	}

	private static func timespec(_ date: Date) -> timespec {
		let seconds = date.timeIntervalSince1970
		return Darwin.timespec(tv_sec: Int(seconds), tv_nsec: Int((seconds - seconds.rounded(.down)) * 1e9))
	}

	static func posixError(_ error: any Error) -> POSIXError {
		if let error = error as? POSIXError { return error }
		guard let error = error as? StoreError else { return POSIXError(.EIO) }
		switch error {
		case .notFound: return POSIXError(.ENOENT)
		case .exists: return POSIXError(.EEXIST)
		case .notDirectory: return POSIXError(.ENOTDIR)
		case .isDirectory: return POSIXError(.EISDIR)
		case .notEmpty: return POSIXError(.ENOTEMPTY)
		case .invalidName, .invalidMove: return POSIXError(.EINVAL)
		case .noSpace: return POSIXError(.ENOSPC)
		case let .io(code): return POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
		case .blocksMissing, .sqlite: return POSIXError(.EIO)
		}
	}
}

/// One `StashNode` per live item, so FSKit always sees the same object for the same file.
final class NodeTable: Sendable {
	private let nodes = OSAllocatedUnfairLock<[Int64: StashNode]>(uncheckedState: [:])

	func node(_ id: Int64, isDirectory: Bool) -> StashNode {
		nodes.withLockUnchecked { nodes in
			if let node = nodes[id] { return node }
			let node = StashNode(id: id, isDirectory: isDirectory)
			nodes[id] = node
			return node
		}
	}

	func existing(_ id: Int64) -> StashNode? {
		nodes.withLockUnchecked { $0[id] }
	}

	func remove(_ node: StashNode) {
		nodes.withLockUnchecked { if $0[node.id] === node { $0[node.id] = nil } }
	}

	var all: [StashNode] {
		nodes.withLockUnchecked { Array($0.values) }
	}
}
