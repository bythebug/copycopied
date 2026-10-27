// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CopyCopied",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CopyCopiedCore", targets: ["CopyCopiedCore"]),
        .executable(name: "copycopied-cli", targets: ["copycopied-cli"]),
    ],
    targets: [
        // Official xxHash v0.8.3 (BSD-2), vendored unmodified: Sources/CXXHash/include/xxhash.h
        .target(name: "CXXHash"),
        .target(name: "CopyCopiedCore", dependencies: ["CXXHash"]),
        .executableTarget(name: "copycopied-cli", dependencies: ["CopyCopiedCore"]),
        // Menu bar app; scripts/build-app.sh wraps the binary in CopyCopied.app (PLAN.md D1).
        .executableTarget(name: "CopyCopiedApp", dependencies: ["CopyCopiedCore"]),
        .testTarget(name: "CopyCopiedCoreTests", dependencies: ["CopyCopiedCore"]),
    ]
)
