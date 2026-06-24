// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacControlMCP",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MacControlMCPCore"),
        .target(name: "AXKit", dependencies: ["MacControlMCPCore"]),
        .target(name: "CaptureKit", dependencies: ["MacControlMCPCore"]),
        .target(name: "InputKit", dependencies: ["MacControlMCPCore"]),
        .target(name: "HostKit", dependencies: ["MacControlMCPCore", "AXKit", "CaptureKit", "InputKit"]),
        .executableTarget(name: "MacControlMCP", dependencies: ["HostKit"]),
        .executableTarget(name: "MacControlHost", dependencies: ["HostKit"]),
        .executableTarget(name: "MacControlRelay", dependencies: ["HostKit"]),
        .executableTarget(name: "MacControlRegistrar"),
        .testTarget(name: "MacControlMCPCoreTests", dependencies: ["MacControlMCPCore"]),
        .testTarget(name: "AXKitTests", dependencies: ["AXKit", "MacControlMCPCore"]),
        .testTarget(name: "CaptureKitTests", dependencies: ["CaptureKit"]),
        .testTarget(name: "InputKitTests", dependencies: ["InputKit"]),
        .testTarget(name: "HostKitTests", dependencies: ["HostKit"])
    ]
)
