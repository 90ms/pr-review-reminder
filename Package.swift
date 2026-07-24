// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PRReviewReminder",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "PRRCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "PRReviewReminder",
            dependencies: ["PRRCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PRRCoreTests",
            dependencies: ["PRRCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
