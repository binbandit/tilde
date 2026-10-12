import CodexWorkers
import Foundation
import TildeMemory
import TildeSupport
import WorkerKit

/// The manager: a Codex thread using the owner's configured model whose
/// tools are tilde's orchestration toolset and whose memory is the notebook.
///
/// Messages are handled one turn at a time. What tilde hears while a turn runs is batched
/// into the next, so every turn knows whether a <tap> started it, and therefore whether its
/// words are a reply in the thread or stay private. What Brayden says never waits: it's
/// steered into the turn in progress, which then answers them.
///
/// A turn whose model goes quiet (a connection that hangs, which Codex alone would wait out
/// for five minutes) is asked again after `Config.stallAfter`.
public actor Manager: CodexHost {
    public struct Config: Sendable {
        /// Nil inherits Codex's configured model, including gateway routing aliases.
        public var model: String?
        /// The ID in Codex's model_providers table; nil inherits its configured provider.
        public var modelProvider: String?
        public var effort = "low"
        public var executable = "codex"
        /// How long a turn may wait on the model, with nothing at all coming back, before it's asked again.
        public var stallAfter: TimeInterval = 45
        /// The longest any turn may take, whatever it's doing, before it's stopped.
        public var turnLimit: TimeInterval = 300
        public init() {}
    }

    public enum Output: Sendable {
        /// Streaming reply text for the taps that started this turn.
        case reply(taps: [String], text: String)
        /// The turn's reply is done; `said` is what its taps said, for the scribe.
        case replyDone(taps: [String], text: String, said: String)
        /// What the turn is doing right now ("Checking GitHub"), for the taps waiting on it.
        case activity(taps: [String], text: String)
        /// The model has these taps now: everything said in the running turn, the latest last.
        case read(taps: [String])
        /// These taps never reached the model, and why.
        case undelivered(taps: [String], reason: String)
        /// Something went wrong in the turn these taps are in (none: a turn of tilde's own).
        case trouble(String, taps: [String])
    }

    static let maxAttempts = 3

    public struct Message: Sendable {
        public var text: String
        /// Set when Brayden said it; the turn's reply goes to that tap's message.
        public var tap: String?
        /// Paths and jobs the message concerns, to pull the right notes into the briefing.
        public var paths: [String]
        public var jobs: [String]
        /// Whether Codex accepted this message. Queuing alone is not delivery.
        var onDelivery: (@Sendable (Bool) async -> Void)?

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
    /// Job identities are resolved by the conductor, never by parsing message text or notebook notes.
    private let repositoryPaths: @Sendable ([String]) async -> [String]
    private var repositoryInstructions: [String: RepositoryInstructions.Snapshot] = [:]
    private var pendingRepositoryInstructions: [String: (snapshot: RepositoryInstructions.Snapshot, revision: String)] = [:]

    /// The day's thread, once it's ready for turns.
    private var session: CodexSession?
    private var sessionDay: String?
    /// The thread being opened; everyone who needs it meanwhile waits for this one.
    private var opening: Task<CodexSession, any Error>?
    private var inbox: [Message] = []
    /// Taps in the running turn; nil when idle.
    private var turn: [String]?
    /// Changes before a turn starts any async work, unlike the watchdog generation.
    private var turnID = UUID()
    private var streaming = ""
    private var replyText = ""
    /// What Brayden said in the running turn, for the scribe.
    private var said = ""
    private var turnStarted = Date.now
    /// Everything the running turn was asked, to ask a fresh thread again if it comes to that.
    private var asked = ""
    /// The tools the running turn has already called, so asking again never repeats them.
    private var done: [String] = []
    private var attempts = 0
    /// Set while a stalled turn is being stopped, to be asked again.
    private var retrying = false
    /// Set while a turn that ran too long is being stopped; what's said meanwhile waits for the next turn.
    private var stopping = false
    /// Counts turns, so a watchdog only ever watches its own.
    private var generation = 0

    public init(
        memory: Memory, tools: Toolset, config: Config = Config(),
        repositoryPaths: @escaping @Sendable ([String]) async -> [String] = { _ in [] }
    ) {
        self.memory = memory
        self.tools = tools
        self.config = config
        self.repositoryPaths = repositoryPaths
        (outputs, emit) = AsyncStream<Output>.makeStream(bufferingPolicy: .unbounded)
    }

    public func post(_ message: Message) {
        if message.tap != nil, turn != nil, !retrying, !stopping {
            Task { await self.steer(message) }
            return
        }
        inbox.append(message)
        pump()
    }

    /// Brought into the turn in progress, which answers it; or, if that turn just ended, given one of its own.
    private func steer(_ message: Message) async {
        guard let session, let tap = message.tap else { return requeue(message) }
        let mine = turnID
        let briefing = await withBriefing(message.text, paths: message.paths, jobs: message.jobs)
        guard turnID == mine, turn != nil, session === self.session else { return requeue(message) }
        do {
            try await session.steer(briefing.text)
        } catch {
            return requeue(message)
        }
        if turnID == mine { received(briefing.repositories) }
        guard turnID == mine, turn != nil else {
            // Codex accepted it, even if its turn finished before the RPC returned. Preserve the
            // existing reply retry, but do not acknowledge this message a second time.
            await message.onDelivery?(true)
            var retry = message
            retry.onDelivery = nil
            return requeue(retry)
        }
        Log.info("manager", "steered in: \(message.text.clipped(to: 200))")
        turn?.append(tap)
        emit.yield(.read(taps: turn ?? [tap]))
        asked += "\n\n" + briefing.text
        streaming = ""
        said = [said, message.text].filter { !$0.isEmpty }.joined(separator: "\n")
        // Record the tap in its own turn before a durable delivery receipt can suspend us.
        await message.onDelivery?(true)
    }

    private func requeue(_ message: Message) {
        inbox.append(message)
        pump()
    }

    public var isBusy: Bool { turn != nil }

    /// Starts the Codex process and thread ahead of the first message.
    public func warm() async {
        // Never mid-turn: a new day's thread waits until the running turn is done with the old one.
        guard turn == nil else { return }
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
        let mine = UUID()
        turnID = mine
        turn = batch.compactMap(\.tap)
        streaming = ""
        replyText = ""
        said = batch.filter { $0.tap != nil }.map(\.text).joined(separator: "\n")
        Task { await self.send(batch, turn: mine) }
    }

    private func send(_ batch: [Message], turn mine: UUID) async {
        let text = batch.map(\.text).joined(separator: "\n\n")
        do {
            guard turnID == mine, turn != nil else { throw CancellationError() }
            turnStarted = .now
            attempts = 0
            done = []
            repositoryInstructions = [:]
            pendingRepositoryInstructions = [:]
            Log.info("manager", "turn: \(text.clipped(to: 300))")
            let session = try await ensureSession()
            guard turnID == mine, turn != nil else { throw CancellationError() }
            let briefing = await withBriefing(text, paths: batch.flatMap(\.paths), jobs: Array(Set(batch.flatMap(\.jobs))))
            guard turnID == mine, turn != nil else { throw CancellationError() }
            asked = briefing.text
            try await session.send(asked, effort: config.effort)
            if turnID == mine { received(briefing.repositories) }
            for message in batch { await message.onDelivery?(true) }
            emit.yield(.read(taps: batch.compactMap(\.tap)))
            guard turnID == mine, turn != nil else { return }
            watch()
            await steerWaiting()
        } catch {
            for message in batch { await message.onDelivery?(false) }
            emit.yield(.undelivered(taps: batch.compactMap(\.tap), reason: "I couldn't reach Codex: \(error)"))
            if turnID == mine { endTurn() }
        }
    }

    /// What Brayden said while this turn was starting (or being asked again) joins it now, rather than
    /// waiting behind it.
    private func steerWaiting() async {
        let waiting = inbox.filter { $0.tap != nil }
        guard !waiting.isEmpty else { return }
        inbox.removeAll { $0.tap != nil }
        for message in waiting { await steer(message) }
    }

    private func withBriefing(
        _ text: String, paths: [String], jobs: [String]
    ) async -> (text: String, repositories: [RepositoryInstructions.Snapshot]) {
        let jobPaths = await repositoryPaths(jobs)
        let snapshots = await RepositoryInstructions.snapshots(for: paths, repositories: jobPaths)
        let notes = await memory.briefing(for: text, paths: paths, jobs: jobs)
        return ((snapshots.map { $0.context() } + [notes, text].compactMap { $0 }).joined(separator: "\n\n"), snapshots)
    }

    private func received(_ snapshots: [RepositoryInstructions.Snapshot]) {
        for snapshot in snapshots {
            repositoryInstructions[snapshot.root] = snapshot
            pendingRepositoryInstructions[snapshot.root] = nil
        }
    }

    /// A project discovered during the turn must be read before work is delegated or finalized.
    /// Its current instructions make the model reconsider the action, then explicitly retry.
    /// Re-read every time so edited instructions cannot be bypassed by a stale thread cache.
    func prepareRepositoryWork(repository: String, tool: String = "delegate", revision: String? = nil) -> String? {
        prepareRepositoryWork(RepositoryInstructions.load(root: repository), tool: tool, revision: revision)
    }

    private func prepareRepositoryWork(_ snapshot: RepositoryInstructions.Snapshot, tool: String, revision: String?) -> String? {
        if case .unavailable = snapshot.state { return snapshot.context() }
        let previous = repositoryInstructions[snapshot.root]
        if case .absent = snapshot.state, previous == nil, pendingRepositoryInstructions[snapshot.root] == nil {
            repositoryInstructions[snapshot.root] = snapshot
            return nil
        }
        guard previous != snapshot else { return nil }
        let token: String
        if let pending = pendingRepositoryInstructions[snapshot.root], pending.snapshot == snapshot {
            token = pending.revision
        } else {
            token = UUID().uuidString.lowercased()
            pendingRepositoryInstructions[snapshot.root] = (snapshot, token)
        }
        if revision == token {
            received([snapshot])
            return nil
        }
        // Returning context does not acknowledge it. Parallel calls made before the model sees
        // this response must also stop, and old tokens must not acknowledge changed file contents.
        return "Read these repository instructions and reconcile the action before retrying \(tool). The requested action has not run. "
            + "After reading, echo this exact argument on the retry:\n"
            + JSON.object(["repository_revision": .string(token)]).compact + "\n\n"
            + snapshot.context()
    }

    // MARK: Stalls

    /// Watches the running turn until it ends, and asks again if the model goes quiet.
    private func watch() {
        generation += 1
        let mine = generation
        let watchedTurn = turnID
        Task {
            while true {
                try? await Task.sleep(for: .seconds(min(5, config.stallAfter / 2)))
                guard generation == mine, turnID == watchedTurn, turn != nil, !retrying, let session else { return }
                if Date.now.timeIntervalSince(turnStarted) > config.turnLimit { return await overran(session, turn: mine) }
                if let quiet = await session.silence, quiet > config.stallAfter {
                    guard generation == mine, turnID == watchedTurn, turn != nil, !retrying else { return }
                    return await stalled(session)
                }
            }
        }
    }

    /// A turn that has gone on too long, whatever it's doing, is stopped: nothing waits on it forever.
    private func overran(_ session: CodexSession, turn mine: Int) async {
        let watchedTurn = turnID
        Log.info("manager", "turn still going after \(Int(config.turnLimit))s; stopping it")
        stopping = true
        // Only someone who asked hears about it; a turn of tilde's own just ends.
        if let taps = turn, !taps.isEmpty { emit.yield(.trouble("That was taking too long, so I stopped. Ask again in a moment.", taps: taps)) }
        Task {
            try? await Task.sleep(for: .seconds(10))
            // If even stopping it hangs, its process goes, and with it the turn (this one, never the next).
            if generation == mine, turnID == watchedTurn, turn != nil, session === self.session { await session.stop() }
        }
        await session.interrupt()
    }

    private func stalled(_ session: CodexSession) async {
        let mine = turnID
        attempts += 1
        retrying = true
        Log.info("manager", "nothing from the model in \(Int(config.stallAfter))s; asking again (\(attempts))")
        // Twice is no fluke: a fresh process, and so a fresh connection, asks again.
        guard attempts == 1 else { return await session.stop() }
        // If Codex can't even stop the turn (or answer being asked to), the same.
        Task {
            try? await Task.sleep(for: .seconds(10))
            if turnID == mine, retrying, session === self.session { await session.stop() }
        }
        await session.interrupt()
    }

    /// Asks a stalled turn again: the same thread carries on from where it was; a fresh one is
    /// told everything again, and what was already done.
    private func askAgain(sameThread: Bool) async {
        let mine = turnID
        retrying = false
        guard attempts < Self.maxAttempts else {
            emit.yield(.trouble("The model isn't answering right now. Try again in a minute.", taps: turn ?? []))
            return endTurn()
        }
        streaming = ""
        replyText = ""
        let already = done.isEmpty ? "" : "\n\nAlready done this turn, not to be repeated:\n" + done.map { "- \($0)" }.joined(separator: "\n")
        let text = sameThread
            ? "(No answer came back, so this is the same turn again. Carry on from where you were.)"
            : "(The connection dropped and this is a fresh thread; here is the turn again.)\n\n\(asked)\(already)"
        do {
            let session = try await ensureSession()
            guard turnID == mine, turn != nil else { return }
            try await session.send(text, effort: config.effort)
            guard turnID == mine, turn != nil else { return }
            watch()
            await steerWaiting()
        } catch {
            guard turnID == mine, turn != nil else { return }
            emit.yield(.trouble("I couldn't reach Codex: \(error)", taps: turn ?? []))
            endTurn()
        }
    }

    private func endTurn() {
        guard let taps = turn else { return }
        Log.info("manager", "turn done in \(String(format: "%.1f", Date.now.timeIntervalSince(turnStarted)))s: \(replyText.clipped(to: 200))")
        if !taps.isEmpty { emit.yield(.replyDone(taps: taps, text: replyText, said: said)) }
        said = ""
        stopping = false
        turn = nil
        pump()
    }

    private func ensureSession() async throws -> CodexSession {
        if let opening { return try await opening.value }
        let day = Date.now.day
        // A turn in progress keeps its thread even across midnight; the next idle moment starts the new day's.
        if let session, sessionDay == day || turn != nil, await session.isRunning { return session }
        if let opening { return try await opening.value }

        let previous = session
        session = nil
        let opening = Task { try await self.open(replacing: previous) }
        self.opening = opening
        defer { self.opening = nil }
        let session = try await opening.value
        self.session = session
        sessionDay = day
        return session
    }

    /// A fresh, ephemeral thread each day (or after a crash): continuity lives in the
    /// notebook and in tilde's job state, not in an ever-growing context.
    private func open(replacing previous: CodexSession?) async throws -> CodexSession {
        await previous?.stop()
        let session = CodexSession(
            cwd: memory.notebook.path, host: self, overrides: CodexSession.ownProcess(), executable: config.executable)
        Task { await self.relay(session) }
        do {
            try await session.start()
            try await session.startThread([
                "cwd": .string(memory.notebook.path),
                "model": config.model.map(JSON.string) ?? nil,
                "modelProvider": config.modelProvider.map(JSON.string) ?? nil,
                "approvalPolicy": "never",
                // Read anything to understand a project; change nothing. Workers change things.
                "sandbox": "read-only",
                "baseInstructions": .string(ManagerPrompt.make(owner: Owner.firstName, notebook: memory.notebook.path)),
                "dynamicTools": tools.codexSpecs,
                // tilde's tools are its only tools: none of the owner's servers run unasked here.
                "config": try await session.serversOff(),
                "ephemeral": true,
            ])
        } catch {
            await session.stop()
            throw error
        }
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
                guard turn != nil else { continue }
                // The answer can land just as the turn is being stopped for silence: then it's the answer.
                if retrying, !(ok && !replyText.isEmpty) {
                    await askAgain(sameThread: true)
                    continue
                }
                retrying = false
                if !ok, !stopping, let error { emit.yield(.trouble(error.clipped(to: 200), taps: turn ?? [])) }
                endTurn()
            case .notice(let text):
                emit.yield(.trouble(text.clipped(to: 200), taps: turn ?? []))
            case .exited(let status, let detail):
                self.session = nil
                if retrying {
                    await askAgain(sameThread: false)
                    continue
                }
                if status != 0, !stopping, let taps = turn { emit.yield(.trouble("The manager stopped (\(status)). \(detail.clipped(to: 200))", taps: taps)) }
                if turn != nil { endTurn() }
            case .itemStarted(let item):
                if let line = Self.trace(item) {
                    Log.info("manager", line)
                    done.append(line)
                }
                if let taps = turn, !taps.isEmpty, let doing = Self.doing(item) { emit.yield(.activity(taps: taps, text: doing)) }
            case .submitted, .turnStarted:
                break
            }
        }
    }

    /// What a step of the turn looks like from the outside, in a few words.
    static func doing(_ item: JSON) -> String? {
        switch item["type"]?.string {
        case "commandExecution": return "Looking around"
        case "webSearch": return "Searching the web"
        case "dynamicToolCall":
            return switch item["tool"]?.string {
            case "github", "pull_requests": "Checking GitHub"
            case "recall", "remember", "forget": "Checking my notes"
            case "jobs", "transcript": "Checking on the agents"
            case "projects": "Finding the project"
            case "look": "Looking at what you're doing"
            case "delegate": "Handing it to an agent"
            case "steer": "Talking to the agent"
            case "ask": "Writing you a question"
            default: nil
            }
        default: return nil
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
        if ["steer", "finish"].contains(name), let job = arguments["job"]?.string {
            let snapshots = await RepositoryInstructions.snapshots(for: [], repositories: repositoryPaths([job]))
            let unread = snapshots.compactMap { prepareRepositoryWork($0, tool: name, revision: arguments["repository_revision"]?.string) }
            if !unread.isEmpty { return .error(unread.joined(separator: "\n\n")) }
        }
        return await tools.call(name, arguments)
    }
}
