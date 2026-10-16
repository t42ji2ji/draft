// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Draft",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Draft", path: "Sources/Draft")
    ]
)
