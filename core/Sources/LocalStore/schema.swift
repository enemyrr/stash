import Foundation

/// Schema migrations, tracked with `PRAGMA user_version`. Append new steps; never edit old ones.
enum Schema {
	static let migrations: [String] = [
		"""
		CREATE TABLE items (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			parent_id INTEGER,
			name TEXT NOT NULL,
			-- Last key component. Differs from name only for aliases such as "foo (file)".
			remote_name TEXT NOT NULL,
			is_dir INTEGER NOT NULL,
			size INTEGER NOT NULL DEFAULT 0,
			mtime REAL NOT NULL,
			ctime REAL NOT NULL,
			mode INTEGER NOT NULL,
			state INTEGER NOT NULL,
			remote_key TEXT,
			remote_etag TEXT,
			remote_mtime REAL,
			-- Bytes [0, remote_size) that are not cached can be fetched; bytes past it are zeros.
			remote_size INTEGER NOT NULL DEFAULT 0,
			synced_at REAL,
			content_state INTEGER NOT NULL DEFAULT 0,
			-- Present-blocks bitmap, one bit per block.
			blocks BLOB,
			-- Remote version the cached remote-backed blocks belong to.
			cache_etag TEXT,
			cached_bytes INTEGER NOT NULL DEFAULT 0,
			last_access REAL NOT NULL DEFAULT 0
		);
		-- Tombstones (state 3) leave the namespace so the name can be reused.
		CREATE UNIQUE INDEX items_parent_name ON items(parent_id, name) WHERE state != 3;
		CREATE INDEX items_parent ON items(parent_id);
		CREATE INDEX items_remote_key ON items(remote_key) WHERE remote_key IS NOT NULL;
		CREATE INDEX items_lru ON items(last_access) WHERE cached_bytes > 0;

		CREATE TABLE ops (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			kind INTEGER NOT NULL,
			item_id INTEGER NOT NULL,
			key TEXT NOT NULL,
			from_key TEXT,
			-- 0 pending, 1 in flight
			state INTEGER NOT NULL DEFAULT 0,
			attempts INTEGER NOT NULL DEFAULT 0,
			retry_after REAL NOT NULL DEFAULT 0
		);
		CREATE INDEX ops_item ON ops(item_id);

		-- Cache bytes split by dirty (state 1, 2) and clean, kept current by triggers.
		CREATE TABLE usage (id INTEGER PRIMARY KEY CHECK (id = 1), clean INTEGER NOT NULL, dirty INTEGER NOT NULL);
		INSERT INTO usage VALUES (1, 0, 0);
		CREATE TRIGGER items_usage_insert AFTER INSERT ON items BEGIN
			UPDATE usage SET
				clean = clean + CASE WHEN NEW.state IN (1, 2) THEN 0 ELSE NEW.cached_bytes END,
				dirty = dirty + CASE WHEN NEW.state IN (1, 2) THEN NEW.cached_bytes ELSE 0 END;
		END;
		CREATE TRIGGER items_usage_delete AFTER DELETE ON items BEGIN
			UPDATE usage SET
				clean = clean - CASE WHEN OLD.state IN (1, 2) THEN 0 ELSE OLD.cached_bytes END,
				dirty = dirty - CASE WHEN OLD.state IN (1, 2) THEN OLD.cached_bytes ELSE 0 END;
		END;
		CREATE TRIGGER items_usage_update AFTER UPDATE OF cached_bytes, state ON items BEGIN
			UPDATE usage SET
				clean = clean
					- CASE WHEN OLD.state IN (1, 2) THEN 0 ELSE OLD.cached_bytes END
					+ CASE WHEN NEW.state IN (1, 2) THEN 0 ELSE NEW.cached_bytes END,
				dirty = dirty
					- CASE WHEN OLD.state IN (1, 2) THEN OLD.cached_bytes ELSE 0 END
					+ CASE WHEN NEW.state IN (1, 2) THEN NEW.cached_bytes ELSE 0 END;
		END;

		INSERT INTO items (id, parent_id, name, remote_name, is_dir, mtime, ctime, mode, state, remote_key)
		VALUES (1, NULL, '', '', 1, 0, 0, 493, 0, '');
		""",
	]

	static func migrate(_ db: Connection) throws {
		let version = try db.first("PRAGMA user_version") { $0.int(0) } ?? 0
		for (index, sql) in migrations.enumerated() where index >= version {
			try db.execute("BEGIN IMMEDIATE")
			do {
				try db.execute(sql)
				try db.execute("PRAGMA user_version = \(index + 1)")
				try db.execute("COMMIT")
			} catch {
				try? db.execute("ROLLBACK")
				throw error
			}
		}
	}
}
