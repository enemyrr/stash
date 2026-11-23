import Foundation
@testable import LocalStore

let mib = Int(LocalStore.blockSize)

func makeDirectory() -> URL {
	FileManager.default.temporaryDirectory.appendingPathComponent("local-store-\(UUID().uuidString)")
}

func removeDirectory(_ url: URL) {
	try? FileManager.default.removeItem(at: url)
}

func bytes(_ value: UInt8, _ count: Int) -> Data {
	Data(repeating: value, count: count)
}

/// Drains the queue as a sync engine would, answering every operation with success.
func syncAll(_ store: LocalStore) throws {
	while true {
		let batch = try store.nextBatch(limit: 100)
		if batch.isEmpty { return }
		for op in try store.markInFlight(batch.map(\.id)) {
			try store.complete(op.id, etag: op.kind == .upload ? "etag-\(op.id)" : nil)
		}
	}
}

/// Applies a listing of the root, started now.
func listRoot(_ store: LocalStore, _ entries: [RemoteEntry]) throws {
	try store.applyRemoteListing(Item.rootId, entries: entries, listedAt: Date())
}

extension LocalStore {
	func root(_ name: String) throws -> Item? {
		try lookup(parent: Item.rootId, name: name)
	}
}
