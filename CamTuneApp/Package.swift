// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OjoApp",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "OjoApp",
            path: "Sources"
        ),
    ]
)
