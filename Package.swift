// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "backed",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BackedCore", targets: ["BackedCore"]),
        .executable(name: "backed-cli", targets: ["backed-cli"]),
    ],
    targets: [
        // Official xxHash v0.8.3 (BSD-2), vendored unmodified: Sources/CXXHash/include/xxhash.h
        .target(name: "CXXHash"),
        .target(name: "BackedCore", dependencies: ["CXXHash"]),
        .executableTarget(name: "backed-cli", dependencies: ["BackedCore"]),
        .testTarget(name: "BackedCoreTests", dependencies: ["BackedCore"]),
    ]
)
