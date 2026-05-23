// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentIsland",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AgentIslandApp", targets: ["AgentIslandApp"]),
        .executable(name: "agentisland", targets: ["AgentIslandCLI"]),
    ],
    targets: [
        .target(
            name: "AgentIslandCore",
            path: "Sources/AgentIslandCore"
        ),
        .executableTarget(
            name: "AgentIslandApp",
            dependencies: ["AgentIslandCore"],
            path: "Sources/AgentIslandApp"
        ),
        .executableTarget(
            name: "AgentIslandCLI",
            dependencies: ["AgentIslandCore"],
            path: "Sources/AgentIslandCLI"
        ),
    ]
)
