// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ougi",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ougi",
            path: "Sources/ougi",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
    ]
)
