import Foundation

public enum ItemState: Int, Sendable {
	case synced = 0
	case localNew = 1
	case localModified = 2
	case deletedPending = 3
	/// A conflict copy of a remote version whose server-side rename is still queued.
	case conflict = 4

	var isDirty: Bool { self == .localNew || self == .localModified }
}

public enum ContentState: Int, Sendable {
	case none = 0
	case partial = 1
	case full = 2
}

public struct Item: Sendable, Hashable, Identifiable {
	public static let rootId: Int64 = 1

	public let id: Int64
	/// `nil` only for the root.
	public let parentId: Int64?
	public let name: String
	public let isDirectory: Bool
	public let size: Int64
	public let mtime: Date
	public let ctime: Date
	public let mode: UInt16
	/// Where the item currently exists in the bucket. `nil` until the first upload completes.
	/// Directory keys end with `/`. The root key is empty.
	public let remoteKey: String?
	public let remoteEtag: String?
	public let remoteMtime: Date?
	public let state: ItemState
	public let contentState: ContentState
}

/// One object or common prefix from a remote listing.
public struct RemoteEntry: Sendable, Hashable {
	/// Full key. Directories (common prefixes) end with `/`.
	public var key: String
	public var size: Int64
	public var etag: String?
	public var mtime: Date

	public init(key: String, size: Int64 = 0, etag: String? = nil, mtime: Date = Date(timeIntervalSince1970: 0)) {
		self.key = key
		self.size = size
		self.etag = etag
		self.mtime = mtime
	}

	public var isDirectory: Bool { key.hasSuffix("/") }

	/// The last path component, without the trailing `/`.
	public var name: String {
		let trimmed = isDirectory ? key.dropLast() : Substring(key)
		return trimmed.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
	}
}

public enum OperationKind: Int, Sendable {
	case upload = 0
	case mkdir = 1
	/// Server-side rename of `fromKey` to `key`. A key ending in `/` means the whole prefix.
	/// The source may not exist (an upload that never landed); treat that as success.
	case move = 2
	/// Delete `key`. A key ending in `/` means the known objects under that prefix. A missing key is success.
	case delete = 3
	/// Store the item's mtime in the object's metadata, without sending the content.
	case touch = 4

	/// Moves and deletes run alone, in queue order.
	var isBarrier: Bool { self == .move || self == .delete }
}

public struct SyncOperation: Sendable, Hashable, Identifiable {
	public let id: Int64
	public let kind: OperationKind
	public let itemId: Int64
	public let key: String
	public let fromKey: String?
	public let attempts: Int
	public let isInFlight: Bool
	/// For a claimed upload: a stable copy of the content to send. Deleted on complete or fail.
	public var contentURL: URL?
	/// For a claimed upload: the remote version the content was edited from, so a newer remote version is never overwritten.
	public var baseEtag: String?
}

public enum ReadResult: Sendable, Equatable {
	case data(Data)
	/// Byte ranges to fetch from the remote version `etag` and pass to `fillCache`.
	case missing([Range<Int64>], etag: String?)
}

public struct CacheUsage: Sendable, Equatable {
	public let cleanBytes: Int64
	public let dirtyBytes: Int64
	public let budget: Int64
}

public enum StoreError: Error, Equatable, Sendable {
	case notFound
	case exists
	case notDirectory
	case isDirectory
	case notEmpty
	case invalidName
	case invalidMove
	/// A partial write touched blocks that are not cached. Fetch them and retry.
	case blocksMissing([Range<Int64>])
	/// Dirty data would exceed the cache budget (ENOSPC).
	case noSpace
	case sqlite(code: Int32, message: String)
	case io(errno: Int32)
}
