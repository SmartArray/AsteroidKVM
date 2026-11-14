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
        .executable(name: "CometApp", targets: ["CometApp"]),
        .executable(name: "create-edid", targets: ["EDIDTool"])
    ],
    targets: [
        // WebRTC-SDK exposes macOS audio routing. Pin its artifact directly because the
        // upstream 150.7871.01 manifest uses visionOS 26 with Swift tools 5.9.
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/webrtc-sdk/Specs/releases/download/150.7871.01/WebRTC.xcframework.zip",
            checksum: "03815cdf2f6a0ed328c94d74cce8fd1b8d2b6e95e2b37eab66795012fcecfdfa"),
        .target(name: "CometCore"),
        .target(name: "CometMedia", dependencies: ["CometCore", "WebRTC"]),
        .target(name: "CometAgent", dependencies: ["CometCore"]),
        .target(name: "CometSession", dependencies: ["CometCore", "CometMedia", "CometAgent"]),
        .executableTarget(name: "CometApp", dependencies: ["CometCore", "CometMedia", "CometAgent", "CometSession"]),
        .executableTarget(name: "EDIDTool", dependencies: ["CometCore"]),
        .testTarget(name: "CometCoreTests", dependencies: ["CometCore", "CometMedia", "CometAgent", "CometSession"])
    ]
)
