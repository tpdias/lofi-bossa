// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LofiBossa",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "LofiBossa", path: "Sources/LofiBossa")
    ]
)
