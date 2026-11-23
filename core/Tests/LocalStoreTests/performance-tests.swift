import Foundation
import Testing
@testable import LocalStore

@Suite struct PerformanceTests {
	@Test func parallelLookupsReadsAndWrites() async throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		let files = try (0..<8).map { try store.createFile(in: Item.rootId, name: "f\($0)") }
		let chunk = 64
		let writesPerFile = 25

		try await withThrowingTaskGroup(of: Void.self) { group in
			for (index, file) in files.enumerated() {
				group.addTask {
					for step in 0..<writesPerFile {
						let data = bytes(UInt8(index), chunk)
						try store.write(file.id, offset: Int64(step * chunk), data: data)
						#expect(try store.read(file.id, range: Int64(step * chunk)..<Int64((step + 1) * chunk)) == .data(data))
					}
				}
				group.addTask {
					for _ in 0..<500 {
						#expect(try store.lookup(parent: Item.rootId, name: "f\(index)")?.id == file.id)
						_ = try store.children(of: Item.rootId, limit: 4)
					}
				}
			}
			try await group.waitForAll()
		}

		for (index, file) in files.enumerated() {
			let size = chunk * writesPerFile
			#expect(try store.item(file.id)?.size == Int64(size))
			#expect(try store.read(file.id, range: 0..<Int64(size)) == .data(bytes(UInt8(index), size)))
		}
		#expect(try store.queuedOperations().count == files.count)
	}

	@Test func tenThousandItemsStayFast() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		let count = 10_000
		let entries = (0..<count).map { RemoteEntry(key: String(format: "file-%05d.jpg", $0), size: 1_000, etag: "e\($0)") }
		try listRoot(store, entries)

		let clock = ContinuousClock()
		let lookups = clock.measure {
			for index in 0..<count {
				_ = try? store.lookup(parent: Item.rootId, name: String(format: "file-%05d.jpg", index))
			}
		}
		var listed = 0
		let paging = try clock.measure {
			var after: String?
			while true {
				let page = try store.children(of: Item.rootId, after: after, limit: 500)
				guard let last = page.last else { break }
				listed += page.count
				after = last.name
			}
		}
		let item = try #require(try store.root("file-09999.jpg"))
		let paths = clock.measure {
			for _ in 0..<1_000 { _ = try? store.path(of: item.id) }
		}

		let perLookup = lookups / count
		print("10k items: lookup \(perLookup) each, all children in pages of 500 \(paging), path \(paths / 1_000) each")
		#expect(listed == count)
		#expect(perLookup < .microseconds(200))
		#expect(paging < .milliseconds(250))
	}
}
