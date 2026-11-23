import Foundation
import Testing
@testable import LocalStore

@Suite struct ItemTests {
	@Test func createLookupListAndDelete() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		let docs = try store.createDirectory(in: Item.rootId, name: "docs")
		let file = try store.createFile(in: docs.id, name: "a.txt")
		#expect(file.state == .localNew)
		#expect(file.parentId == docs.id)
		#expect(try store.lookup(parent: docs.id, name: "a.txt")?.id == file.id)
		#expect(try store.item(file.id)?.name == "a.txt")
		#expect(try store.path(of: file.id) == "docs/a.txt")
		#expect(try store.path(of: Item.rootId) == "")

		#expect(throws: StoreError.exists) { try store.createFile(in: docs.id, name: "a.txt") }
		#expect(throws: StoreError.invalidName) { try store.createFile(in: docs.id, name: "x/y") }
		#expect(throws: StoreError.notDirectory) { try store.createFile(in: file.id, name: "b") }
		#expect(throws: StoreError.notFound) { try store.createFile(in: 9_999, name: "b") }

		let written = try store.write(file.id, offset: 0, data: Data("hello".utf8))
		#expect(written.size == 5)
		#expect(try store.read(file.id, range: 0..<100) == .data(Data("hello".utf8)))

		for index in 0..<25 { try store.createFile(in: docs.id, name: String(format: "f%02d", index)) }
		let first = try store.children(of: docs.id, limit: 10)
		let second = try store.children(of: docs.id, after: first.last?.name, limit: 100)
		#expect(first.count == 10)
		#expect(first.map(\.name) == first.map(\.name).sorted())
		#expect(first.count + second.count == 26)

		try store.delete(file.id)
		#expect(try store.lookup(parent: docs.id, name: "a.txt") == nil)
		// Never uploaded, so nothing is left behind.
		#expect(try store.item(file.id) == nil)
		#expect(throws: StoreError.invalidMove) { try store.delete(Item.rootId) }
	}

	@Test func renameUpdatesSubtreePaths() throws {
		let dir = makeDirectory()
		defer { removeDirectory(dir) }
		let store = try LocalStore(directory: dir)

		let a = try store.createDirectory(in: Item.rootId, name: "a")
		let b = try store.createDirectory(in: a.id, name: "b")
		let c = try store.createFile(in: b.id, name: "c.txt")

		try store.rename(a.id, to: Item.rootId, name: "z")
		#expect(try store.path(of: c.id) == "z/b/c.txt")

		try store.rename(b.id, to: Item.rootId, name: "b")
		#expect(try store.path(of: c.id) == "b/c.txt")
		#expect(try store.children(of: a.id).isEmpty)

		#expect(throws: StoreError.invalidMove) { try store.rename(b.id, to: b.id, name: "x") }

		// Replacing an existing file, like rename(2).
		let other = try store.createFile(in: b.id, name: "other.txt")
		try store.rename(other.id, to: b.id, name: "c.txt")
		#expect(try store.lookup(parent: b.id, name: "c.txt")?.id == other.id)
		#expect(try store.item(c.id) == nil)
	}

	@Test func conflictAndCollisionNames() {
		let date = Date(timeIntervalSince1970: 1_795_435_200)  // 2026-11-23 12:00 UTC
		let utc = TimeZone(identifier: "UTC")!
		#expect(conflictName(for: "report.pdf", date: date, timeZone: utc) == "report (conflict 2026-11-23).pdf")
		#expect(conflictName(for: "archive.tar.gz", date: date, timeZone: utc) == "archive.tar (conflict 2026-11-23).gz")
		#expect(conflictName(for: "Makefile", date: date, timeZone: utc) == "Makefile (conflict 2026-11-23)")
		#expect(conflictName(for: ".bashrc", date: date, timeZone: utc) == ".bashrc (conflict 2026-11-23)")
		#expect(conflictName(for: "my.folder", isDirectory: true, date: date, timeZone: utc) == "my.folder (conflict 2026-11-23)")
		#expect(conflictName(for: "a.txt", date: date, timeZone: utc, attempt: 2) == "a (conflict 2026-11-23 2).txt")
		#expect(fileCollisionName(for: "foo") == "foo (file)")
		#expect(fileCollisionName(for: "foo.txt", attempt: 2) == "foo (file 2).txt")
	}
}
