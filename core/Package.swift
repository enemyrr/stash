// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StashCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "S3Client", targets: ["S3Client"]),
        .library(name: "RcloneCrypt", targets: ["RcloneCrypt"]),
        .library(name: "LocalStore", targets: ["LocalStore"]),
        .library(name: "SyncEngine", targets: ["SyncEngine"]),
    ],
    targets: [
        .target(name: "S3Client"),
        .testTarget(name: "S3ClientTests", dependencies: ["S3Client"]),
        .target(name: "RcloneCrypt"),
        .testTarget(name: "RcloneCryptTests", dependencies: ["RcloneCrypt"]),
        .target(name: "LocalStore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "LocalStoreTests", dependencies: ["LocalStore"]),
        .target(name: "SyncEngine", dependencies: ["S3Client", "RcloneCrypt", "LocalStore"]),
        .testTarget(name: "SyncEngineTests", dependencies: ["SyncEngine"]),
    ]
)
