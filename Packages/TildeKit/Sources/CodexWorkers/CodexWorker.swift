import Foundation
import TildeSupport
import WorkerKit

/// A Codex worker: the user's own `codex`, sandboxed to the job's worktree
/// (no network, no writes outside it). It works on its own and asks, through
/// tilde, only when it needs to step outside the sandbox.
public actor CodexWorker: Worker, CodexHost {
    public nonisolated let events: AsyncStream<WorkerEvent>
    private let emit: AsyncStream<WorkerEvent>.Continuation
    private let workdir: String
    private var threadID: String?
    private let model: String?
    private let executable: String
    private let instructions: String
    /// Extra thread config (computer-use app access, features).
    private let config: JSON?
    /// Directories outside the worktree its sandbox may write to (the repo's git directory).
    private let writable: [String]
    private var session: CodexSession?
    private var waiting: [String: CheckedContinuation<WorkerAnswer, Never>] = [:]
    private var lastMessage = ""

    public init(
        workdir: String, threadID: String? = nil, model: String? = nil,
        instructions: String = Supervision.brief(owner: Owner.firstName), config: JSON? = nil, writable: [String] = [],
        executable: String = "codex"
    ) {
        self.workdir = workdir
        self.instructions = instructions
        self.config = config
        self.writable = writable
        self.threadID = threadID
        self.model = model
        self.executable = executable
        (events, emit) = AsyncStream<WorkerEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    public func start(brief: String) async throws {
        let session = CodexSession(cwd: workdir, host: self, executable: executable)
        self.session = session
        Task { await self.relay(session) }
        try await session.start()
        var params: [String: JSON] = [
            "cwd": .string(workdir), "approvalPolicy": "on-request", "sandbox": "workspace-write",
            "developerInstructions": .string(instructions),
        ]
        if let model { params["model"] = .string(model) }
        var config = config?.object ?? [:]
        if !writable.isEmpty {
            config["sandbox_workspace_write"] = ["writable_roots": .array(writable.map { .string($0) })]
        }
        if !config.isEmpty { params["config"] = .object(config) }
        let id = if let threadID { try await session.resumeThread(threadID, .object(params)) } else {
            try await session.startThread(.object(params))
        }
        threadID = id
        emit.yield(.session(id: id))
        try await session.send(brief)
    }

    public func steer(_ text: String) async throws {
        guard let session, await session.isRunning else {
            try await start(brief: text)
            return
        }
        try await session.send(text)
    }

    public func resolve(_ requestID: String, _ answer: WorkerAnswer) {
        waiting.removeValue(forKey: requestID)?.resume(returning: answer)
    }

    public func stop() async {
        for continuation in waiting.values { continuation.resume(returning: .deny("The job was stopped.")) }
        waiting = [:]
        await session?.stop()
    }

    // MARK: CodexHost

    public func approveCommand(_ command: String, cwd: String?, reason: String?) async -> Bool {
        // Codex asks only to run something beyond its sandbox, which is a rail whatever the command.
        let rail = Rails.check(tool: "Bash", input: ["command": .string(command)], workdir: workdir) ?? Rails.outsideSandbox
        return await ask(.permission(tool: "Shell", action: command + Self.saying(reason), rail: rail)).isAllow
    }

    public func approveFileChange(reason: String?, root: String?) async -> Bool {
        let action = (root.map { "write under \($0)" } ?? "write files outside the sandbox") + Self.saying(reason)
        return await ask(.permission(tool: "Edit", action: action, rail: "Writes outside the job's worktree")).isAllow
    }

    public func approveToolUse(connector: String, message: String) async -> Bool {
        await ask(.permission(tool: connector, action: message, rail: ComputerUse.rail(for: message))).isAllow
    }

    public func approvePermissions(reason: String?, requested: JSON) async -> Bool {
        let action = "extra sandbox permissions: \(requested.compact.clipped(to: 300))" + Self.saying(reason)
        return await ask(.permission(tool: "Sandbox", action: action, rail: "Steps outside the job's sandbox")).isAllow
    }

    /// Codex's own reason, as context for whoever decides (never as the rail).
    private static func saying(_ reason: String?) -> String {
        reason.map { $0.isEmpty ? "" : "\n(Codex says: \($0))" } ?? ""
    }

    public func answer(_ questions: [WorkerQuestion]) async -> [String]? {
        switch await ask(.question(questions)) {
        case .reply(let text): return questions.map { _ in text }
        case .allow, .deny: return nil
        }
    }

    private func ask(_ kind: WorkerRequest.Kind) async -> WorkerAnswer {
        let id = IDs.make("r")
        return await withCheckedContinuation { continuation in
            waiting[id] = continuation
            emit.yield(.request(WorkerRequest(id: id, kind: kind)))
        }
    }

    // MARK: Events

    private func relay(_ session: CodexSession) async {
        for await event in session.events {
            switch event {
            case .itemStarted(let item):
                if let activity = Self.describe(item) { emit.yield(.activity(activity)) }
            case .message(let text):
                lastMessage = text
                emit.yield(.message(text))
            case .turnCompleted(let ok, let error):
                emit.yield(.turnEnded(ok: ok, text: ok ? lastMessage : error ?? lastMessage))
            case .notice(let text):
                emit.yield(.notice(text))
            case .exited(let status, let detail):
                emit.yield(.exited(status == 0 ? nil : "Codex exited (\(status)). \(detail)"))
            case .turnStarted, .textDelta:
                break
            }
        }
    }

    static func describe(_ item: JSON) -> String? {
        switch item["type"]?.string {
        case "commandExecution":
            let command = item["command"]?.string ?? "a command"
            // Codex wraps commands as `/bin/zsh -lc '...'`; show what's inside.
            let inner = command.range(of: "-lc ").map { String(command[$0.upperBound...]).trimmingCharacters(in: ["'", "\""]) } ?? command
            return "Running " + inner.clipped(to: 48)
        case "fileChange": return "Editing files"
        case "webSearch": return "Searching the web"
        case "mcpToolCall":
            let server = item["server"]?.string ?? "a tool"
            return server.hasPrefix("cua") ? "Using the computer" : "Using \(server) \(item["tool"]?.string ?? "")"
        case "reasoning": return "Thinking"
        case "plan": return "Planning"
        default: return nil
        }
    }
}
