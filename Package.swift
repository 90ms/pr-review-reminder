// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PRReviewReminder",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "PRRCore"
        ),
        .executableTarget(
            name: "PRReviewReminder",
            dependencies: ["PRRCore"]
        ),
        .testTarget(
            name: "PRRCoreTests",
            dependencies: ["PRRCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
