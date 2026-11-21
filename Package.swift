// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WinExplorer",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "WinExplorer",
            path: "Sources/WinExplorer"
        )
    ]
)
