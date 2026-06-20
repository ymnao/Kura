// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Kura",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Kura",
            path: "Sources/Kura"
        )
    ]
)
