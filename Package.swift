// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VideoFree",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VideoCore", type: .static, targets: ["VideoCore"]),
        .library(name: "VideoMedia", type: .static, targets: ["VideoMedia"]),
        .executable(name: "video", targets: ["VideoCLI"]),
        .executable(name: "video-install", targets: ["VideoInstall"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .systemLibrary(name: "CZlib"),
        .target(name: "VideoCore", dependencies: ["CSQLite"]),
        .target(name: "VideoMedia", dependencies: ["VideoCore", "CZlib"]),
        .executableTarget(name: "VideoCLI", dependencies: ["VideoCore", "VideoMedia"]),
        .executableTarget(name: "VideoInstall", dependencies: ["VideoCore", "VideoMedia"]),
        .testTarget(name: "VideoCoreTests", dependencies: ["VideoCore"]),
        .testTarget(name: "VideoMediaTests", dependencies: ["VideoCore", "VideoMedia"])
    ]
)
