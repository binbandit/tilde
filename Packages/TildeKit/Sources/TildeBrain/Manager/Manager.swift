import CodexWorkers
import Foundation
import TildeMemory
import TildeSupport
import WorkerKit

/// The manager: a Codex thread (gpt-6.1-sol by default, cheap and quick) whose
/// tools are tilde's orchestration toolset and whose memory is the notebook.
///
/// Messages are handled one turn at a time. Whatever arrives while a turn runs
/// is batched into the next, so every turn knows whether a <tap> started it,
/// and therefore whether its words go to a caption or stay private.
public actor Manager: CodexHost {
    public struct Config: Sendable {
        public var model = "gpt-6.1-sol"
        public var effort = "low"
        public var executable = "codex"
        public init() {}
    }

    public enum Output: Sendable {
        /// Streaming caption text for the taps that started this turn.
        case reply(taps: [String], text: String)
        case replyDone(taps: [String], text: String)
        case trouble(String)
    }

    public struct Message: Sendable {
        public var text: String
        /// Set when Brayden said it; the turn's reply goes to that tap's caption.
        public var tap: String?
        /// Paths and jobs the message concerns, to pull the right notes into the briefing.
        public var paths: [String]
        public var jobs: [String]

        public init(_ text: String, tap: String? = nil, paths: [String] = [], jobs: [String] = []) {
            self.text = text
            self.tap = tap
            self.paths = paths
            self.jobs = jobs
        }
    }

    public nonisolated let outputs: AsyncStream<Output>
    private let emit: AsyncStream<Output>.Continuation
    private let memory: Memory
    private let tools: Toolset
    private let config: Config

    private var session: CodexSession?
    private var sessionDay: String?
    private var inbox: [Message] = []
    /// Taps in the running turn; nil when idle.
    private var turn: [String]?
    private var streaming = ""
    private var replyText = ""
    private var lastTurn: Transcript?
    private var turnStarted = Date.now

    /// What happened in a tap turn, for the scribe.
    public struct Transcript: Sendable {
        public var said: String
        public var replied: String
    }

    public init(memory: Memory, tools: Toolset, config: Config = Config()) {
        self.memory = memory
        self.tools = tools
        self.config = config
        (outputs, emit) = AsyncStream<Output>.makeStream(bufferingPolicy: .unbounded)
    }

    public func post(_ message: Message) {
        inbox.append(message)
        pump()
    }

    public var isBusy: Bool { turn != nil }

    /// Starts the Codex process and thread ahead of the first message.
    public func warm() async {
        _ = try? await ensureSession()
    }

    public func shutdown() async {
        await session?.stop()
        session = nil
    }

    // MARK: Turns

    private func pump() {
        guard turn == nil, !inbox.isEmpty else { return }
        let batch = inbox
        inbox = []
        turn = batch.compactMap(\.tap)
        streaming = ""
        replyText = ""
        lastTurn = turn!.isEmpty ? nil : Transcript(
            said: batch.filter { $0.tap != nil }.map(\.text).joined(separator: "\n"), replied: "")
        Task { await self.send(batch) }
    }

    private func send(_ batch: [Message]) async {
        let text = batch.map(\.text).joined(separator: "\n\n")
        turnStarted = .now
        Log.info("manager", "turn: \(text.clipped(to: 300))")
        do {
            let session = try await ensureSession()
            let briefing = await memory.briefing(
                for: text, paths: batch.flatMap(\.paths), jobs: Array(Set(batch.flatMap(\.jobs))))
            try await session.send(briefing.map { "\($0)\n\n\(text)" } ?? text, effort: config.effort)
        } catch {
            emit.yield(.trouble("I couldn't reach Codex: \(error)"))
            endTurn()
        }
    }

    private func endTurn() {
        Log.info("manager", "turn done in \(String(format: "%.1f", Date.now.timeIntervalSince(turnStarted)))s: \(replyText.clipped(to: 200))")
        let taps = turn ?? []
        if !taps.isEmpty {
            emit.yield(.replyDone(taps: taps, text: replyText))
            lastTurn?.replied = replyText
        }
        turn = nil
        pump()
    }

    /// The last tap turn, once, for the scribe.
    public func takeTranscript() -> Transcript? {
        guard turn == nil, let transcript = lastTurn, !transcript.replied.isEmpty else { return nil }
        lastTurn = nil
        return transcript
    }

    private func ensureSession() async throws -> CodexSession {
        let day = Date.now.formatted(.iso8601.year().month().day())
        if let session, await session.isRunning, sessionDay == day { return session }
        await session?.stop()

        // A fresh, ephemeral thread each day (or after a crash): continuity lives
        // in the notebook and in tilde's job state, not in an ever-growing context.
        let session = CodexSession(
            cwd: memory.notebook.path, host: self, overrides: ["mcp_servers={}"], executable: config.executable)
        self.session = session
        sessionDay = day
        Task { await self.relay(session) }
        try await session.start()
        try await session.startThread([
            "cwd": .string(memory.notebook.path),
            "model": .string(config.model),
            "approvalPolicy": "never",
            // Read anything to understand a project; change nothing. Workers change things.
            "sandbox": "read-only",
            "baseInstructions": .string(ManagerPrompt.make(owner: Owner.firstName, notebook: memory.notebook.path)),
            "dynamicTools": tools.codexSpecs,
            "ephemeral": true,
        ])
        await memory.resetBriefing()
        return session
    }

    private func relay(_ session: CodexSession) async {
        for await event in session.events {
            guard session === self.session else { continue }
            switch event {
            case .textDelta(let text):
                streaming += text
                if let taps = turn, !taps.isEmpty { emit.yield(.reply(taps: taps, text: streaming)) }
            case .message(let text):
                // The reply is the last message; earlier ones came before tool calls.
                replyText = text
                streaming = ""
            case .turnCompleted(let ok, let error):
                if !ok, let error { emit.yield(.trouble(error.clipped(to: 200))) }
                endTurn()
            case .notice(let text):
                emit.yield(.trouble(text.clipped(to: 200)))
            case .exited(let status, let detail):
                if status != 0 { emit.yield(.trouble("The manager stopped (\(status)). \(detail.clipped(to: 200))")) }
                self.session = nil
                if turn != nil { endTurn() }
            case .itemStarted(let item):
                if let line = Self.trace(item) { Log.info("manager", line) }
            case .turnStarted:
                break
            }
        }
    }

    private static func trace(_ item: JSON) -> String? {
        switch item["type"]?.string {
        case "commandExecution": "ran \((item["command"]?.string ?? "").clipped(to: 160))"
        case "dynamicToolCall": "called \(item["tool"]?.string ?? "?") \((item["arguments"]?.compact ?? "").clipped(to: 200))"
        default: nil
        }
    }

    // MARK: CodexHost

    public func callTool(_ name: String, arguments: JSON) async -> ToolResult {
        await tools.call(name, arguments)
    }
}
