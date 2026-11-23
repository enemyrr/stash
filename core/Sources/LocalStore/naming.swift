import Foundation

/// Conflict policy: when an item changed both here and remotely, the local version keeps the name and
/// the remote version is saved next to it as `report (conflict 2026-11-23).pdf`.
/// `attempt` 2 and up gives `report (conflict 2026-11-23 2).pdf`.
public func conflictName(
	for name: String, isDirectory: Bool = false, date: Date, timeZone: TimeZone = .current, attempt: Int = 1
) -> String {
	var calendar = Calendar(identifier: .gregorian)
	calendar.timeZone = timeZone
	let day = calendar.dateComponents([.year, .month, .day], from: date)
	let stamp = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
	return nameWithSuffix(name, isDirectory: isDirectory, suffix: attempt > 1 ? "conflict \(stamp) \(attempt)" : "conflict \(stamp)")
}

/// Collision policy: S3 can hold both `foo` and `foo/`. The directory keeps the name and the file is
/// shown as `foo (file)`, while its key stays `foo`.
public func fileCollisionName(for name: String, attempt: Int = 1) -> String {
	nameWithSuffix(name, isDirectory: false, suffix: attempt > 1 ? "file \(attempt)" : "file")
}

/// Inserts ` (suffix)` before the extension of a file name. Dotfiles and directories have no extension.
private func nameWithSuffix(_ name: String, isDirectory: Bool, suffix: String) -> String {
	if !isDirectory, let dot = name.lastIndex(of: "."), dot != name.startIndex {
		return "\(name[..<dot]) (\(suffix))\(name[dot...])"
	}
	return "\(name) (\(suffix))"
}

/// macOS bookkeeping that is never uploaded and is hidden in remote listings. Everything below such a name is
/// local-only too. Moves and deletes still reach the bucket, so a synced file moved to `.Trashes` moves there
/// server-side, and emptying the Trash deletes it.
public func isLocalOnlyName(_ name: String) -> Bool {
	localOnlyNames.contains(name) || name.hasPrefix("._")
}

private let localOnlyNames: Set = [".DS_Store", ".Trashes", ".fseventsd", ".TemporaryItems", ".Spotlight-V100"]

/// True when any component of `key` is a local-only name.
func isLocalOnlyKey(_ key: String) -> Bool {
	key.split(separator: "/").contains { isLocalOnlyName(String($0)) }
}

func isValidName(_ name: String) -> Bool {
	!name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255
		&& !name.contains("/") && !name.contains("\0")
}

extension String {
	/// True when this key is a direct child of the directory key `prefix`: `a/b` or `a/b/` under `a/`.
	func isDirectChild(of prefix: String) -> Bool {
		guard utf8.starts(with: prefix.utf8) else { return false }
		var rest = utf8.dropFirst(prefix.utf8.count)
		if rest.last == UInt8(ascii: "/") { rest = rest.dropLast() }
		return !rest.isEmpty && !rest.contains(UInt8(ascii: "/"))
	}
}
