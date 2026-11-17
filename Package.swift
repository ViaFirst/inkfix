// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Inkfix",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Inkfix", path: "Sources/Inkfix")
    ]
)
