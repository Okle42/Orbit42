// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Orbit42",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Orbit42", targets: ["Orbit42"]),
    ],
    dependencies: [
        // ShoWork42 engine + full sphere (board state, voice, push-to-talk, gauges, audit, cool42 panel…)
        .package(url: "https://github.com/Okle42/ShoWork42.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "Orbit42",
            dependencies: [.product(name: "ShoWorkCore", package: "ShoWork42"), .product(name: "ShoWorkApp", package: "ShoWork42")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "Orbit42Tests", dependencies: ["Orbit42"]),
    ]
)
