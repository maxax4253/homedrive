// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HomeDrive",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "HomeDrive",
            path: "Sources/HomeDrive"
        ),
        // Run with `swift test` (needs full Xcode for XCTest). GitHub runs these on every push.
        .testTarget(
            name: "HomeDriveTests",
            dependencies: ["HomeDrive"],
            path: "Tests/HomeDriveTests"
        ),
    ]
)
