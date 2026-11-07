// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RcloneGUI",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "RcloneGUI", path: "Sources/RcloneGUI")
    ]
)
