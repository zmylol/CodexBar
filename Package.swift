// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CodexBarCore", targets: ["CodexBarCore"]),
        .library(name: "CodexBarWindowing", targets: ["CodexBarWindowing"]),
        .executable(name: "CodexBar", targets: ["CodexBarApp"]),
        .executable(name: "codexbar-hook", targets: ["CodexBarHook"]),
        .executable(name: "codexbar-tests", targets: ["CodexBarTests"])
    ],
    targets: [
        .target(name: "CodexBarCore"),
        .target(
            name: "CodexBarWindowing",
            dependencies: ["CodexBarCore"]
        ),
        .executableTarget(
            name: "CodexBarHook",
            dependencies: ["CodexBarCore"]
        ),
        .executableTarget(
            name: "CodexBarApp",
            dependencies: ["CodexBarCore", "CodexBarWindowing"]
        ),
        .executableTarget(
            name: "CodexBarTests",
            dependencies: ["CodexBarCore", "CodexBarWindowing"],
            path: "Tests/CodexBarCoreTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
