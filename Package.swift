// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Slimg",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SlimgCore", targets: ["SlimgCore"]),
        .executable(name: "slimg", targets: ["slimg"]),
        .executable(name: "SlimgApp", targets: ["SlimgApp"]),
    ],
    targets: [
        .target(
            name: "CZlib",
            path: "Sources/CZlib",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "SlimgCore",
            dependencies: ["CZlib"],
            path: "Sources/SlimgCore",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .executableTarget(
            name: "slimg",
            dependencies: ["SlimgCore"],
            path: "Sources/slimg"
        ),
        .executableTarget(
            name: "SlimgApp",
            dependencies: ["SlimgCore"],
            path: "Sources/SlimgApp"
        ),
        .testTarget(
            name: "SlimgCoreTests",
            dependencies: ["SlimgCore"],
            path: "Tests/SlimgCoreTests"
        ),
    ]
)
