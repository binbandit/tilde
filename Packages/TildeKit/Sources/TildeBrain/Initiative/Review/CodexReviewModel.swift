import CodexWorkers
import TildeMemory
import TildeSupport

/// The background review's model: an ephemeral Codex thread in a read-only sandbox that may look
/// at the owner's connected apps (the MCP servers they configured for Codex) but never change
/// anything in them. See `ReadOnlyTools` for how.
public struct CodexReviewModel: MemoryModel {
    public var model: String
    public var effort: String
    public var executable: String
    /// Extra `-c` config overrides for the Codex process.
    public var overrides: [String]
    /// A pass that runs longer is stopped, and its findings dropped.
    public var timeout: Duration

    public init(
        model: String = "gpt-6.1-sol", effort: String = "medium", executable: String = "codex", overrides: [String] = [],
        timeout: Duration = .seconds(240)
    ) {
        self.model = model
        self.effort = effort
        self.executable = executable
        self.overrides = overrides
        self.timeout = timeout
    }

    public func run(_ pass: ModelPass) async throws -> ModelReply {
        var session = try await open(overrides, in: pass.workdir)
        var fence = (try? await session.readConfig()).flatMap(ReadOnlyTools.fence)
        if fence == nil {
            // Connectors that can't be fenced aren't used at all.
            Log.info("review", "running without connectors: couldn't fence them")
            await session.stop()
            session = try await open(overrides + ["mcp_servers={}"], in: pass.workdir)
            fence = [:]
        }
        let running = session
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            Log.info("review", "timed out")
            await running.stop()
        }
        defer {
            watchdog.cancel()
            Task { await running.stop() }
        }
        try await running.startThread([
            "cwd": .string(pass.workdir), "model": .string(model), "approvalPolicy": ReadOnlyTools.approvalPolicy,
            "sandbox": "read-only", "ephemeral": true, "baseInstructions": .string(pass.instructions),
            "config": .object(fence ?? [:]),
        ])
        try await running.send(pass.prompt, effort: effort, outputSchema: pass.outputSchema)
        return await running.reply()
    }

    private func open(_ overrides: [String], in workdir: String) async throws -> CodexSession {
        let session = CodexSession(cwd: workdir, host: ReadOnlyConnectors(), overrides: overrides, executable: executable)
        try await session.start()
        return session
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
