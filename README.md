# Stash

Stash mounts an S3-compatible bucket as a drive in Finder. Each drive is an FSKit volume in `/Volumes` that you can eject like any other disk. Stash is local-first, so Finder keeps working when the network drops.

Encryption is optional and compatible with rclone crypt, so plain rclone can still read an encrypted bucket. Stash is native Swift, with no FUSE and no kernel extension.

## Requirements

- macOS 27 or later. Stash mounts drives with `FSClient.mountSingleVolume`, which macOS 27 introduced.
- Xcode 27 or later.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), to generate the Xcode project from `app/project.yml`.
- An Apple Developer team. FSKit modules, app groups, and shared Keychain groups need a signed build.

## Build and install

1. Copy the signing settings:

	```sh
	cp app/local.example.xcconfig app/local.xcconfig
	```

2. In `app/local.xcconfig`, set `DEVELOPMENT_TEAM` to your team ID and `STASH_BUNDLE_ID` to a bundle ID you own, such as `com.yourname.stash`. The FSKit module, the app group, and the Keychain access group derive their identifiers from these two values.
3. Generate the project:

	```sh
	cd app
	xcodegen generate
	```

4. Open `app/StashFS.xcodeproj`, then build and run the `StashFS` scheme. The app is named `Stash`.
5. Open **System Settings > General > Login Items & Extensions > File System Extensions**, then turn on **Stash**.

For a Developer ID build, archive the `StashFS` scheme and export it with `app/scripts/export-options.plist`.

To redraw the app icon and the volume icon, run `swift scripts/make-icons.swift` from `app/`.

## Add a drive

Open Stash and click **Add Drive…**. Enter the endpoint URL, the bucket, and the access keys. To encrypt files, turn on **Encrypt files** and enter a password. Stash checks the keys against the bucket, saves them in the Keychain, and mounts the drive in `/Volumes`.

To import an existing rclone crypt remote, run the app binary with `--import-rclone`:

```sh
/Applications/Stash.app/Contents/MacOS/Stash --import-rclone ~/.config/rclone/rclone.conf secret "My Drive"
```

The arguments are the path to `rclone.conf`, the name of the remote, and the name of the drive. The remote must be a crypt remote that points at the root of an S3 bucket. If a drive with that name exists, Stash updates it. The import prints no secrets. Stash mounts the drive the next time it starts.

## How it works

The app stores drive settings in its app group container and the keys in a shared Keychain group. The FSKit module serves each drive from local state and syncs with the bucket in the background:

- `LocalStore` keeps the file tree in SQLite, caches file content in blocks, and queues uploads, moves, and deletes.
- `SyncEngine` lists directories, drains the queue, and fetches file content on demand. Finder waits a bounded time for the network, then gets an error or the cached state.
- `S3Client` talks to the bucket with AWS Signature Version 4. Every request has a timeout.
- `RcloneCrypt` is a Swift implementation of the rclone crypt format, for both file content and names.

When a file changed both locally and in the bucket, the local version keeps its name. The bucket version is saved next to it as `name (conflict YYYY-MM-DD).ext`.

The Swift package in `core/` holds these four modules. The `app/` folder holds the host app, the FSKit module in `extension/`, and the code that both share in `shared/`.

## Run the tests

```sh
cd core
swift test
```

Integration tests skip unless you set these environment variables:

| Variable | Used by |
| --- | --- |
| `STASH_TEST_S3_ENDPOINT`, `STASH_TEST_S3_BUCKET`, `STASH_TEST_S3_ACCESS_KEY`, `STASH_TEST_S3_SECRET_KEY`, `STASH_TEST_S3_REGION` (default `us-east-1`) | S3 tests against a real bucket. They write only under `_stash-core-test/`. |
| `STASH_TEST_RCLONE` | Path to rclone for the cross-check tests. Without it, the tests use `rclone` from `PATH`. |
| `STASH_TEST_RCLONE_CONFIG`, `STASH_TEST_RCLONE_CRYPT_REMOTE` | A read-only check that decrypts the top-level names of a real crypt remote and compares them with rclone's listing. |

## Limitations

- Some providers ignore conditional headers on `CompleteMultipartUpload` and `CopyObject`. Hetzner Object Storage is one of them. Stash checks large uploads with `HEAD` first, but two writers can still overwrite each other in a short window.
- Finder doesn't refresh when the bucket changes. Stash lists an open directory again when its listing is older than 15 seconds, so remote changes show up after a short delay.
- Files moved to the Trash move to `.Trashes` in the bucket. Empty the Trash to delete them from the bucket.
- After a rebuild, macOS can keep running the old FSKit module. If a mount fails, quit Stash, then turn **Stash** off and on again in **File System Extensions**.

## License

MIT. See [LICENSE](LICENSE).
