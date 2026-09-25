// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacTree",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "MacTreeCore"),
        .executableTarget(name: "MacTree", dependencies: ["MacTreeCore"]),
        .testTarget(name: "MacTreeCoreTests", dependencies: ["MacTreeCore"]),
    ]
)
