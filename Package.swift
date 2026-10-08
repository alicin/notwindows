// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "notwindows",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "notwindows",
            path: "Sources/notwindows",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "notwindowsTests",
            dependencies: ["notwindows"],
            path: "Tests/notwindowsTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
