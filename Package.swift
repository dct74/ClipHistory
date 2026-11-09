// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipHistory",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClipHistory",
            path: "Sources/ClipHistory"
        ),
        .testTarget(
            name: "ClipHistoryTests",
            dependencies: ["ClipHistory"],
            path: "Tests/ClipHistoryTests"
        ),
    ]
)
