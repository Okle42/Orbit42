// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Orbit42",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Orbit42", targets: ["Orbit42"]),
    ],
    targets: [
        // Engine + full sphere, in this repo since 2026-11-24 (copied from ShoWork42 f0dba58; no longer follows that repo)
        .target(name: "ShoWorkCore", path: "Engine/Sources/ShoWorkCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "ShoWorkApp", dependencies: ["ShoWorkCore"], path: "Engine/Sources/ShoWorkApp", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "showork", dependencies: ["ShoWorkCore"], path: "Engine/Sources/showork", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "ShoWorkCoreTests", dependencies: ["ShoWorkCore"], path: "Engine/Tests/ShoWorkCoreTests", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(
            name: "Orbit42",
            dependencies: ["ShoWorkCore", "ShoWorkApp"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "Orbit42Tests", dependencies: ["Orbit42"]),
    ]
)
