// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LofiBossa",
    // SwiftPM builds the Mac app and runs the tests. The iOS app (iPhone, iPad) is the
    // LofiBossaiOS target in LofiBossa.xcodeproj, which compiles these same sources.
    platforms: [.macOS(.v14), .iOS("27.0")],
    targets: [
        .executableTarget(name: "LofiBossa", path: "Sources/LofiBossa"),
        .testTarget(name: "LofiBossaTests", dependencies: ["LofiBossa"], path: "LofiBossaTests"),
    ]
)
