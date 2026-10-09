import Foundation
import TildeSupport
import WorkerKit

/// A Claude Code worker: the user's own `claude`, with their CLAUDE.md, skills
/// and MCP servers, running in auto mode inside the job's worktree. tilde's
/// rails hook turns anything outward-facing into an explicit request.
public actor ClaudeWorker: Worker, ClaudeHost {
    public nonisolated let events: AsyncStream<WorkerEvent>
    private let emit: AsyncStream<WorkerEvent>.Continuation
    private let workdir: String
    private var launch: ClaudeLaunch
    private var session: ClaudeSession?
    private var waiting: [String: CheckedContinuation<WorkerAnswer, Never>] = [:]

    public init(
        workdir: String, sessionID: String, resume: Bool = false, model: String? = nil,
        instructions: String = Supervision.brief(owner: Owner.firstName), executable: String = "claude"
    ) {
        self.workdir = workdir
        var launch = ClaudeLaunch(cwd: workdir, sessionID: sessionID)
        launch.executable = executable
        launch.resume = resume
        launch.model = model
        launch.permissionMode = "auto"
        launch.appendSystemPrompt = instructions
        launch.preToolUseHook = true
        self.launch = launch
        (events, emit) = AsyncStream<WorkerEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    public func start(brief: String) async throws {
        let session = ClaudeSession(launch, host: self)
        self.session = session
        Task { await self.relay(session) }
        try await session.start()
        try await session.send(brief)
    }

    public func steer(_ text: String) async throws {
        guard let session, await session.isRunning else {
            // The process ended (crash, restart): pick the conversation back up.
            launch.resume = true
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

    // MARK: ClaudeHost

    public func preToolUse(tool: String, input: JSON) async -> ClaudeHookDecision {
        Rails.check(tool: tool, input: input, workdir: workdir).map { .ask(reason: "tilde rail: \($0)") } ?? .proceed
    }

    public func canUseTool(_ request: ClaudePermissionRequest) async -> ClaudePermissionDecision {
        if request.toolName == "AskUserQuestion" {
            let questions = (request.input["questions"]?.array ?? []).map {
                WorkerQuestion(
                    question: $0["question"]?.string ?? "",
                    options: ($0["options"]?.array ?? []).compactMap { $0["label"]?.string },
                    multiSelect: $0["multiSelect"]?.bool ?? false)
            }
            switch await ask(.question(questions)) {
            case .reply(let text):
                return .allow(Self.answering(request.input, questions: questions, with: text))
            case .deny(let reason): return .deny(reason)
            case .allow: return .deny("No answer was given; use your best judgement and say what you assumed.")
            }
        }

        let rail = Rails.check(tool: request.toolName, input: request.input, workdir: workdir)
        let action = Activity.action(tool: request.toolName, input: request.input)
        switch await ask(.permission(tool: request.toolName, action: action, rail: rail ?? request.reason)) {
        case .allow: return .allow(request.input)
        case .deny(let reason): return .deny(reason)
        case .reply(let text): return .deny(text)
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

    private func relay(_ session: ClaudeSession) async {
        for await event in session.events {
            switch event {
            case .ready(let id, _): emit.yield(.session(id: id))
            case .toolUse(_, let name, let input): emit.yield(.activity(Activity.describe(tool: name, input: input)))
            case .text(let text): emit.yield(.message(text))
            case .turnDone(let turn): emit.yield(.turnEnded(ok: turn.ok, text: turn.text))
            case .notice(let text): emit.yield(.notice(text))
            case .exited(let status, let detail):
                emit.yield(.exited(status == 0 ? nil : "Claude Code exited (\(status)). \(detail)"))
            case .textDelta, .toolResult: break
            }
        }
    }

    // MARK: Helpers

    /// AskUserQuestion takes its answers as `{question: label}` alongside the questions.
    static func answering(_ input: JSON, questions: [WorkerQuestion], with text: String) -> JSON {
        var answers: [String: JSON] = [:]
        for q in questions {
            let match = q.options.first { $0.caseInsensitiveCompare(text.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }
            answers[q.question] = .string(match ?? text)
        }
        var updated = input.object ?? [:]
        updated["answers"] = .object(answers)
        return .object(updated)
    }
}
