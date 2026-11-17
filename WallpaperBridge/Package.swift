// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WallpaperBridge",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "WallpaperBridge",
            path: "Sources/WallpaperBridge"
        )
    ]
)
