import Foundation
import SQLite3

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A value that can be bound to a statement parameter.
protocol SQLValue: Sendable {
	func bind(to statement: OpaquePointer, at index: Int32) -> Int32
}

extension Int64: SQLValue {
	func bind(to statement: OpaquePointer, at index: Int32) -> Int32 { sqlite3_bind_int64(statement, index, self) }
}

extension Int: SQLValue {
	func bind(to statement: OpaquePointer, at index: Int32) -> Int32 { sqlite3_bind_int64(statement, index, Int64(self)) }
}

extension Bool: SQLValue {
	func bind(to statement: OpaquePointer, at index: Int32) -> Int32 { sqlite3_bind_int(statement, index, self ? 1 : 0) }
}

extension Double: SQLValue {
	func bind(to statement: OpaquePointer, at index: Int32) -> Int32 { sqlite3_bind_double(statement, index, self) }
}

extension String: SQLValue {
	func bind(to statement: OpaquePointer, at index: Int32) -> Int32 { sqlite3_bind_text(statement, index, self, -1, transient) }
}

extension Data: SQLValue {
	func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
		if isEmpty { return sqlite3_bind_zeroblob(statement, index, 0) }
		return withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
	}
}

/// The current result row of a stepped statement.
struct Row {
	let statement: OpaquePointer

	func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
	func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
	func bool(_ column: Int32) -> Bool { sqlite3_column_int64(statement, column) != 0 }
	func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
	func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }

	func string(_ column: Int32) -> String {
		guard let text = sqlite3_column_text(statement, column) else { return "" }
		return String(cString: text)
	}

	func optionalString(_ column: Int32) -> String? { isNull(column) ? nil : string(column) }
	func optionalInt64(_ column: Int32) -> Int64? { isNull(column) ? nil : int64(column) }
	func optionalDouble(_ column: Int32) -> Double? { isNull(column) ? nil : double(column) }

	func data(_ column: Int32) -> Data? {
		guard !isNull(column) else { return nil }
		let count = Int(sqlite3_column_bytes(statement, column))
		guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
		return Data(bytes: bytes, count: count)
	}
}

/// One SQLite connection with a prepared-statement cache.
/// Not thread-safe: `LocalStore` hands each connection to one thread at a time.
final class Connection: @unchecked Sendable {
	private let db: OpaquePointer
	private var statements: [String: OpaquePointer] = [:]
	/// File work to run once the current transaction commits, such as unlinking cache files.
	var afterCommit: [() -> Void] = []

	init(path: String) throws {
		var handle: OpaquePointer?
		let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
		let code = sqlite3_open_v2(path, &handle, flags, nil)
		guard code == SQLITE_OK, let handle else {
			let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
			sqlite3_close_v2(handle)
			throw StoreError.sqlite(code: code, message: message)
		}
		db = handle
		sqlite3_busy_timeout(db, 5_000)
	}

	deinit {
		for statement in statements.values { sqlite3_finalize(statement) }
		sqlite3_close_v2(db)
	}

	func unlinkAfterCommit(_ path: String) {
		afterCommit.append { unlink(path) }
	}

	var changes: Int { Int(sqlite3_changes(db)) }
	var lastInsertId: Int64 { sqlite3_last_insert_rowid(db) }

	/// Runs one or more statements without parameters.
	func execute(_ sql: String) throws {
		let code = sqlite3_exec(db, sql, nil, nil, nil)
		guard code == SQLITE_OK else { throw error(code) }
	}

	func run(_ sql: String, _ params: (any SQLValue)?...) throws {
		let statement = try prepare(sql, params)
		defer { sqlite3_reset(statement) }
		while true {
			let code = sqlite3_step(statement)
			if code == SQLITE_DONE { return }
			guard code == SQLITE_ROW else { throw error(code) }
		}
	}

	/// Steps through result rows until `body` returns false.
	func each(_ sql: String, _ params: (any SQLValue)?..., body: (Row) throws -> Bool) throws {
		try each(sql, params, body: body)
	}

	func query<T>(_ sql: String, _ params: (any SQLValue)?..., map: (Row) throws -> T) throws -> [T] {
		var results: [T] = []
		try each(sql, params) { row in
			results.append(try map(row))
			return true
		}
		return results
	}

	func first<T>(_ sql: String, _ params: (any SQLValue)?..., map: (Row) throws -> T) throws -> T? {
		var result: T?
		try each(sql, params) { row in
			result = try map(row)
			return false
		}
		return result
	}

	private func each(_ sql: String, _ params: [(any SQLValue)?], body: (Row) throws -> Bool) throws {
		let statement = try prepare(sql, params)
		defer { sqlite3_reset(statement) }
		while true {
			let code = sqlite3_step(statement)
			if code == SQLITE_DONE { return }
			guard code == SQLITE_ROW else { throw error(code) }
			guard try body(Row(statement: statement)) else { return }
		}
	}

	private func prepare(_ sql: String, _ params: [(any SQLValue)?]) throws -> OpaquePointer {
		let statement: OpaquePointer
		if let cached = statements[sql] {
			statement = cached
		} else {
			var prepared: OpaquePointer?
			let code = sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &prepared, nil)
			guard code == SQLITE_OK, let prepared else { throw error(code) }
			statements[sql] = prepared
			statement = prepared
		}
		sqlite3_clear_bindings(statement)
		for (offset, value) in params.enumerated() {
			let index = Int32(offset + 1)
			let code = value?.bind(to: statement, at: index) ?? sqlite3_bind_null(statement, index)
			guard code == SQLITE_OK else { throw error(code) }
		}
		return statement
	}

	private func error(_ code: Int32) -> StoreError {
		.sqlite(code: code, message: String(cString: sqlite3_errmsg(db)))
	}
}
