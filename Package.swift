// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MemBar", targets: ["MemBar"]),
        .library(name: "MemBarCore", targets: ["MemBarCore"]),
    ],
    targets: [
        .target(
            name: "MemBarCore",
            path: "Sources/MemBarCore"
        ),
        .executableTarget(
            name: "MemBar",
            dependencies: ["MemBarCore"],
            path: "Sources/MemBar"
        ),
        .testTarget(
            name: "MemBarCoreTests",
            dependencies: ["MemBarCore"],
            path: "Tests/MemBarCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)