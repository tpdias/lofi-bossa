// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LofiBossa",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "LofiBossa", path: "Sources/LofiBossa"),
        .testTarget(name: "LofiBossaTests", dependencies: ["LofiBossa"], path: "Tests/LofiBossaTests"),
    ]
)
