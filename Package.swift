// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ConnectCam",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ProtocolCore", path: "shared", sources: ["StreamHeader.swift", "BackgroundStage.swift"]),
        .testTarget(name: "ProtocolTests", dependencies: ["ProtocolCore"], path: "tests/swift")
    ]
)
