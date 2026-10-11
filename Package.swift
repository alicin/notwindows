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
        .executableTarget(
            name: "notwindows-link-helper",
            path: "Sources/notwindows-link-helper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "notwindowsTests",
            dependencies: ["notwindows"],
            path: "Tests/notwindowsTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
