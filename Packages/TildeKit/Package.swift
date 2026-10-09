// swift-tools-version: 6.2
import PackageDescription

// One module per layer, each depending only on layers below it. See "Layout" in AGENTS.md.
let package = Package(
    name: "TildeKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "TildeKit", targets: ["TildeKit"]),
        .executable(name: "tilde-smoke", targets: ["TildeSmoke"]),
    ],
    targets: [
        // Foundations with no domain knowledge: processes, JSON, logging, paths.
        .target(name: "TildeSupport"),

        // The worker contract every harness family implements, and the rails.
        .target(name: "WorkerKit", dependencies: ["TildeSupport"]),

        // One module per harness family. Families never import each other.
        .target(name: "ClaudeWorkers", dependencies: ["WorkerKit", "TildeSupport"]),
        .target(name: "CodexWorkers", dependencies: ["WorkerKit", "TildeSupport"]),
        .target(name: "ACPWorkers", dependencies: ["WorkerKit", "TildeSupport"]),
        .target(name: "StreamWorkers", dependencies: ["WorkerKit", "TildeSupport"]),

        // The catalog: the one place that knows every family.
        .target(
            name: "Harnesses",
            dependencies: ["WorkerKit", "ClaudeWorkers", "CodexWorkers", "ACPWorkers", "StreamWorkers"]),

        // The notebook, its index, and the scribe and dream passes.
        .target(name: "TildeMemory", dependencies: ["TildeSupport"]),

        // Jobs, git worktrees and landing, projects on this Mac.
        .target(name: "TildeWork", dependencies: ["TildeSupport", "WorkerKit"]),

        // The manager, the conductor and its tools, initiative.
        .target(
            name: "TildeBrain",
            dependencies: ["TildeSupport", "WorkerKit", "CodexWorkers", "Harnesses", "TildeMemory", "TildeWork"]),

        // What the app imports.
        .target(
            name: "TildeKit",
            dependencies: ["TildeBrain", "TildeWork", "TildeMemory", "Harnesses", "WorkerKit", "TildeSupport"]),

        .executableTarget(name: "TildeSmoke", dependencies: ["TildeKit"]),

        .testTarget(name: "TildeSupportTests", dependencies: ["TildeSupport"]),
        .testTarget(name: "WorkerKitTests", dependencies: ["WorkerKit", "TildeSupport"]),
        .testTarget(name: "ClaudeWorkersTests", dependencies: ["ClaudeWorkers", "WorkerKit", "TildeSupport"]),
        .testTarget(name: "CodexWorkersTests", dependencies: ["CodexWorkers", "TildeSupport"], exclude: ["Fixtures"]),
        .testTarget(name: "ACPWorkersTests", dependencies: ["ACPWorkers", "WorkerKit", "TildeSupport"], exclude: ["Fixtures"]),
        .testTarget(name: "StreamWorkersTests", dependencies: ["StreamWorkers", "WorkerKit", "TildeSupport"], exclude: ["Fixtures"]),
        .testTarget(name: "HarnessesTests", dependencies: ["Harnesses", "WorkerKit"]),
        .testTarget(name: "TildeMemoryTests", dependencies: ["TildeMemory", "TildeSupport"]),
        .testTarget(name: "TildeWorkTests", dependencies: ["TildeWork", "WorkerKit", "TildeSupport"]),
        .testTarget(
            name: "TildeBrainTests",
            dependencies: ["TildeBrain", "Harnesses", "TildeMemory", "TildeWork", "WorkerKit", "TildeSupport"],
            exclude: ["Fixtures"]),
    ]
)
