import CodexWorkers
import TildeMemory
import TildeSupport

/// The background review's model: an ephemeral Codex thread in a read-only sandbox that may look
/// at the owner's connected apps (the MCP servers they configured for Codex) but never change
/// anything in them. See `ReadOnlyTools` for how.
public struct CodexReviewModel: MemoryModel {
    public var model: String?
    public var modelProvider: String?
    public var effort: String
    public var executable: String
    /// Extra `-c` config overrides for the Codex process.
    public var overrides: [String]
    /// A pass that runs longer is stopped, and its findings dropped.
    public var timeout: Duration

    public init(
        model: String? = nil, effort: String = "medium", executable: String = "codex", overrides: [String] = [],
        timeout: Duration = .seconds(240), modelProvider: String? = nil
    ) {
        self.model = model
        self.modelProvider = modelProvider
        self.effort = effort
        self.executable = executable
        self.overrides = overrides
        self.timeout = timeout
    }

    public func run(_ pass: ModelPass) async throws -> ModelReply {
        let running = CodexSession(
            cwd: pass.workdir, host: ReadOnlyConnectors(), overrides: CodexSession.ownProcess(connectors: true) + overrides,
            executable: executable)
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            Log.info("review", "timed out")
            await running.stop()
        }
        defer {
            watchdog.cancel()
            Task { await running.stop() }
        }
        try await running.start()
        try await running.startThread([
            "cwd": .string(pass.workdir), "model": model.map(JSON.string) ?? nil,
            "modelProvider": modelProvider.map(JSON.string) ?? nil, "approvalPolicy": ReadOnlyTools.approvalPolicy,
            "sandbox": "read-only", "ephemeral": true, "baseInstructions": .string(pass.instructions),
            "config": ReadOnlyTools.fence(try await running.readConfig()),
        ])
        try await running.send(pass.prompt, effort: effort, outputSchema: pass.outputSchema)
        return await running.reply()
    }

    /// Lets a connector tool run only when its name reads like a read.
    private struct ReadOnlyConnectors: CodexHost {
        func approveToolUse(connector: String, tool: String?, message: String) async -> Bool {
            let allowed = tool.map(ReadOnlyTools.allows) ?? false
            Log.info("review", "\(allowed ? "allowed" : "declined") \(connector) \(tool ?? message.clipped(to: 120))")
            return allowed
        }
    }
}
