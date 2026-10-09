import CodexWorkers
import TildeMemory
import TildeSupport

/// The scribe's and the dream's model: each pass is its own ephemeral Codex thread,
/// in a fresh process that never asks anyone anything.
public struct CodexMemoryModel: MemoryModel {
    public var model: String
    public var effort: String
    public var executable: String

    public init(model: String = "gpt-6.1-sol", effort: String, executable: String = "codex") {
        self.model = model
        self.effort = effort
        self.executable = executable
    }

    public func run(_ pass: ModelPass) async throws -> ModelReply {
        let session = CodexSession(cwd: pass.workdir, host: Unattended(), overrides: CodexSession.ownProcess(), executable: executable)
        defer { Task { await session.stop() } }
        try await session.start()
        try await session.startThread([
            "cwd": .string(pass.workdir), "model": .string(model), "approvalPolicy": "never",
            "sandbox": pass.writable ? "workspace-write" : "read-only", "ephemeral": true,
            "baseInstructions": .string(pass.instructions), "config": try await session.serversOff(),
        ])
        try await session.send(pass.prompt, effort: effort, outputSchema: pass.outputSchema)
        return await session.reply()
    }

    /// Refuses whatever the thread asks: a memory pass has no one to ask.
    private struct Unattended: CodexHost {}
}

extension CodexSession {
    /// The turn's last message once it ends, or whatever was said before the process went away.
    nonisolated func reply() async -> ModelReply {
        var text: String?
        for await event in events {
            switch event {
            case .message(let message): text = message
            case .turnCompleted(let ok, _): return ModelReply(ok: ok, text: text)
            case .exited: return ModelReply(ok: false, text: text)
            default: continue
            }
        }
        return ModelReply(ok: false, text: text)
    }
}
