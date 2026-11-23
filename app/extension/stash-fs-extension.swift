import ExtensionFoundation
import FSKit

@main
struct StashFSExtension: UnaryFileSystemExtension {
	let fileSystem = StashFileSystem()
}
