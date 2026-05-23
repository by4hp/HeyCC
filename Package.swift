// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HeyCC",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "codexbar",
            path: "Sources/codexbar"
        ),
    ]
)
