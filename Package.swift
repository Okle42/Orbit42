// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Orbit42",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Orbit42", targets: ["Orbit42"]),
    ],
    targets: [
        // Engine + full sphere
        .target(name: "Orbit42Core", path: "Engine/Sources/Orbit42Core", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "Orbit42App", dependencies: ["Orbit42Core"], path: "Engine/Sources/Orbit42App", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "orbit", dependencies: ["Orbit42Core"], path: "Engine/Sources/orbit", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "Orbit42CoreTests", dependencies: ["Orbit42Core"], path: "Engine/Tests/Orbit42CoreTests", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(
            name: "Orbit42",
            dependencies: ["Orbit42Core", "Orbit42App"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "Orbit42Tests", dependencies: ["Orbit42"]),
    ]
)
