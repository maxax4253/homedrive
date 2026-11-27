// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HomeDrive",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "HomeDrive",
            path: "Sources/HomeDrive"
        )
    ]
)
