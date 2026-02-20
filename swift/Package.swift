// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "bridge_swift_tools",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "engine_helper", targets: ["EngineHelper"]),
        .executable(name: "bridge_companion", targets: ["BridgeCompanion"]),
    ],
    targets: [
        .executableTarget(
            name: "EngineHelper",
            path: "Sources/EngineHelper",
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-strict-concurrency=minimal"]),
            ]
        ),
        .executableTarget(
            name: "BridgeCompanion",
            path: "Sources/BridgeCompanion",
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-strict-concurrency=minimal"]),
            ]
        ),
    ]
)
