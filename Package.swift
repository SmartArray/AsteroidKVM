// swift-tools-version: 5.10
// Share domain and media targets between the native app, Xcode, and automated tests.
import PackageDescription

let package = Package(
    name: "CometModules",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CometCore", targets: ["CometCore"]),
        .library(name: "CometMedia", targets: ["CometMedia"]),
        .library(name: "CometAgent", targets: ["CometAgent"]),
        .library(name: "CometSession", targets: ["CometSession"]),
        .executable(name: "CometApp", targets: ["CometApp"])
    ],
    dependencies: [.package(url: "https://github.com/stasel/WebRTC.git", exact: "153.0.0")],
    targets: [
        .target(name: "CometCore"),
        .target(name: "CometMedia", dependencies: ["CometCore", "WebRTC"]),
        .target(name: "CometAgent", dependencies: ["CometCore"]),
        .target(name: "CometSession", dependencies: ["CometCore", "CometMedia", "CometAgent"]),
        .executableTarget(name: "CometApp", dependencies: ["CometCore", "CometMedia", "CometAgent", "CometSession"]),
        .testTarget(name: "CometCoreTests", dependencies: ["CometCore", "CometMedia", "CometAgent", "CometSession"])
    ]
)
