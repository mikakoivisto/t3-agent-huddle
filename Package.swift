// swift-tools-version:6.0
import PackageDescription

let swift5: [SwiftSetting] = []

let package = Package(
    name: "AgentHuddle",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentHuddle", targets: ["AgentHuddle"]),
        .executable(name: "fake-t3", targets: ["fake-t3"]),
        .executable(name: "huddle-probe", targets: ["huddle-probe"]),
    ],
    targets: [
        // Pure logic: models, reducer, discovery, MCP client, poller. No UI.
        .target(name: "HuddleCore"),
        // In-process fake T3 MCP server (loopback only). Used by tests, demo and `fake-t3`.
        .target(name: "FakeT3", dependencies: ["HuddleCore"]),
        .executableTarget(name: "fake-t3", dependencies: ["FakeT3"]),
        // Live-check tool: OAuth sign-in approved with a throwaway pairing code, then read-only calls (scripts/live-check.sh).
        .executableTarget(name: "huddle-probe", dependencies: ["HuddleCore"]),
        .executableTarget(name: "AgentHuddle", dependencies: ["HuddleCore", "FakeT3"]),
        .testTarget(name: "HuddleCoreTests", dependencies: ["HuddleCore", "FakeT3"], exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v5]
)
