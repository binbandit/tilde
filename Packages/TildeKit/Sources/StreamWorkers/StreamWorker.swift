import Foundation
import TildeSupport
import WorkerKit

/// A worker for any harness with a long-lived headless JSON stream, configured by a
/// `StreamDialect`. One process serves many turns. When it has gone (an error ended it,
/// or tilde restarted), the next instruction starts a new one on the same session.
///
/// Every tool call the dialect gates passes `Rails`: ordinary work is allowed on the
/// spot and anything crossing a rail becomes a `WorkerRequest`.
public actor StreamWorker: Worker {
    public nonisolated let events: AsyncStream<WorkerEvent>
    private let emit: AsyncStream<WorkerEvent>.Continuation
    private let dialect: any StreamDialect
    private let launch: WorkerLaunch
    private let executable: String
    private let environment: [String: String]
    /// Generated files (gate helper, settings, extension), outside the worktree.
    private let scratch: URL
    private var process: ChildProcess?
    private var mailbox: GateMailbox?
    private var session: String?
    private var announced: String?
    private var briefPending = false
    private var busy = false
    private var ended = false
    private var lastMessage = ""
    private var failure: String?
    private var waiting: [String: CheckedContinuation<WorkerAnswer, Never>] = [:]
    /// Follow-ups held for the end of the running turn, when the dialect doesn't acknowledge prompts.
    private var queued: [(text: String, submission: UUID?)] = []
    /// Prompts sent but not yet acknowledged, by request id, with the submission each one carries.
    private var unacknowledged: [String: UUID?] = [:]

    /// A `launch.sessionID` is always resumed: harnesses that mint ids open or create it,
    /// and for the rest an id only exists once the harness has reported it.
    init(
        _ dialect: some StreamDialect, launch: WorkerLaunch, executable: String,
        environment: [String: String] = UserEnvironment.shared.variables,
        scratch: URL = FileManager.default.temporaryDirectory.appending(path: "tilde-stream-\(UUID().uuidString.lowercased())")
    ) {
        self.dialect = dialect
        self.launch = launch
        self.executable = executable
        self.environment = environment
        self.scratch = scratch
        session = launch.sessionID
        (events, emit) = AsyncStream<WorkerEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    public func start(brief: String, submission: UUID?) async throws {
        try spawn()
        try send(brief, submission: submission)
    }

    public func steer(_ text: String, submission: UUID?) async throws {
        try Task.checkCancellation()
        guard !ended else { throw ChildProcess.Failure.stdinClosed }
        if busy, !dialect.acknowledgesPrompts {
            queued.append((text, submission))
            return
        }
        // An exit `pump` hasn't caught up with yet counts as gone too.
        if process?.exitStatus != nil || process == nil { try spawn() }
        try send(text, submission: submission)
    }

    public func resolve(_ requestID: String, _ answer: WorkerAnswer) {
        waiting.removeValue(forKey: requestID)?.resume(returning: answer)
    }

    public func stop() async {
        guard !ended else { return }
        ended = true
        queued = []
        unacknowledged = [:]
        denyWaiting()
        if let process {
            if busy, let interrupt = dialect.interrupt, (try? process.write(interrupt.line())) != nil {
                await settle(within: .seconds(3))
            }
            self.process = nil
            await process.terminate(grace: .seconds(5))
        }
        end(nil)
    }

    /// Gives an interrupted turn a moment to wind down, so the harness saves its session cleanly.
    private func settle(within limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        while busy, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    // MARK: Process

    private func spawn() throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let arguments = try dialect.prepare(launch, session: session, scratch: scratch)
        if dialect.gate == .helper, mailbox == nil {
            mailbox = try GateMailbox(in: scratch) { [weak self] call in
                Task { await self?.gate(call, from: nil) }
            }
        }
        let process = try ChildProcess(.init(
            executable: executable, arguments: arguments, cwd: launch.workdir, environment: environment))
        self.process = process
        unacknowledged = [:]
        briefPending = dialect.briefInPrompt && session == nil
        if let session { announce(session) }
        Task { await self.pump(process) }
    }

    private func send(_ text: String, submission: UUID?) throws {
        try Task.checkCancellation()
        guard let process else { throw ChildProcess.Failure.stdinClosed }
        let text = briefPending ? "\(launch.instructions)\n\n---\n\n\(text)" : text
        var prompt = dialect.prompt(text)
        let id = UUID().uuidString.lowercased()
        if dialect.acknowledgesPrompts { prompt = prompt.merging(["id": .string(id)]) }
        try process.write(prompt.line())
        briefPending = false
        if dialect.acknowledgesPrompts {
            // Its turn begins at the acknowledgment (see `.promptResponse`).
            unacknowledged.updateValue(submission, forKey: id)
        } else {
            if let submission { emit.yield(.submitted(submission)) }
            lastMessage = ""
            failure = nil
            busy = true
        }
    }

    private func pump(_ process: ChildProcess) async {
        for await line in process.lines {
            guard let message = JSON.parse(line) else { continue }
            for signal in dialect.decode(message) { handle(signal, from: process) }
        }
        let status = await process.waitForExit()
        guard process === self.process, !ended else { return }
        self.process = nil
        // Between turns the process may come and go; the next instruction starts another.
        guard busy || !unacknowledged.isEmpty else { return }
        let detail = process.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        ended = true
        denyWaiting()
        end("\(dialect.label) exited (\(status)). \(String(detail.suffix(2_000)))")
    }

    private func end(_ detail: String?) {
        busy = false
        queued = []
        unacknowledged = [:]
        mailbox?.close()
        mailbox = nil
        try? FileManager.default.removeItem(at: scratch)
        emit.yield(.exited(detail))
        emit.finish()
    }

    // MARK: Events

    private func handle(_ signal: StreamSignal, from source: ChildProcess) {
        guard source === process else { return }
        if ended {
            // Stopping: only note that the interrupted turn has wound down.
            if case .turnEnded = signal { busy = false }
            return
        }
        switch signal {
        case .promptResponse(let id, let accepted, let disposition, let error):
            guard let submission = unacknowledged.removeValue(forKey: id) else { return }
            // The harness answers before the prompt's run starts: what came before this belongs to earlier turns.
            if let submission { emit.yield(.submitted(submission)) }
            switch (accepted, disposition) {
            case (true, "started"):
                busy = true
                lastMessage = ""
                failure = nil
            case (true, "queued"):
                // Folded into the running turn, whose end answers for it.
                busy = true
            case (false, _):
                let problem = error ?? "\(dialect.label) refused the prompt."
                // The running turn still ends once, but cannot sign off an instruction it rejected.
                if busy {
                    failure = problem
                    emit.yield(.notice(problem))
                } else { emit.yield(.turnEnded(ok: false, text: problem)) }
            default:
                let problem =
                    if disposition == "handled" { "\(dialect.label) handled the prompt without a model turn." }
                    else { "\(dialect.label) didn't confirm a model turn for the prompt (\(disposition ?? "no disposition"))." }
                // A running turn still ends on its own, and answers for this prompt too. Otherwise nothing
                // else will end this one.
                if busy { emit.yield(.notice(problem)) }
                else { emit.yield(.turnEnded(ok: false, text: problem)) }
            }
        case .session(let id):
            session = id
            announce(id)
        case .activity(let text):
            // Anything the agent does means a turn is running, even one it queued itself.
            busy = true
            emit.yield(.activity(text))
        case .message(let text):
            busy = true
            lastMessage = text
            emit.yield(.message(text))
        case .failure(let text):
            failure = text
            emit.yield(.notice(text.clipped(to: 120)))
        case .notice(let text):
            emit.yield(.notice(text))
        case .turnEnded(let ok):
            guard busy else { return }
            busy = false
            var failed = !ok || failure != nil
            // It's already on its way out: the next instruction starts another process on the
            // session rather than being written into this one as it closes.
            if failed, dialect.exitsOnFailure {
                process = nil
                Task { await source.terminate(grace: .seconds(2)) }
            }
            let followUps = queued
            queued = []
            if !failed, let last = followUps.last {
                // They start the next turn, which answers for them.
                do {
                    if process == nil { try spawn() }
                    try send(followUps.map(\.text).joined(separator: "\n\n"), submission: last.submission)
                    return
                } catch {
                    failure = "Couldn't send the follow-up: \(error)"
                    failed = true
                }
            }
            // A failed turn answers for the follow-ups held behind it, which were never sent.
            if let submission = followUps.last?.submission { emit.yield(.submitted(submission)) }
            emit.yield(.turnEnded(ok: !failed, text: failed ? failure ?? lastMessage : lastMessage))
        case .gate(let call):
            Task { await gate(call, from: source) }
        case .dialog(let dialog):
            Task { await ask(dialog, from: source) }
        }
    }

    private func announce(_ id: String) {
        guard id != announced else { return }
        announced = id
        emit.yield(.session(id: id))
    }

    // MARK: Gate

    /// Rules on a held tool call and answers through whichever channel it came from.
    private func gate(_ call: GateCall, from source: ChildProcess?) async {
        let verdict = await rule(on: dialect.uses(of: call.tool, input: call.input))
        if let source {
            if let line = dialect.answer(call, verdict) { try? source.write(line.line()) }
        } else {
            mailbox?.reply(call.id, verdict)
        }
    }

    private func rule(on uses: [ToolUse]) async -> GateVerdict {
        for use in uses.map(anchored) {
            guard let rail = Rails.check(tool: use.name, input: use.input, workdir: launch.workdir) else { continue }
            let action = Activity.action(tool: use.name, input: use.input)
            switch await ask(.permission(tool: use.name, action: action, rail: rail)) {
            case .allow: continue
            case .deny(let reason), .reply(let reason): return .deny(reason)
            }
        }
        return .allow
    }

    /// Harnesses may give paths relative to the worktree; `Rails` needs them absolute.
    private func anchored(_ use: ToolUse) -> ToolUse {
        guard let path = use.input["file_path"]?.string, !path.hasPrefix("/"), !path.hasPrefix("~") else { return use }
        let absolute = URL(fileURLWithPath: launch.workdir).appending(path: path).path
        return ToolUse(name: use.name, input: use.input.merging(["file_path": .string(absolute)]))
    }

    private func ask(_ dialog: StreamDialog, from source: ChildProcess) async {
        let reply = await ask(.question([dialog.question]))
        if let line = dialect.answer(dialog, reply) { try? source.write(line.line()) }
    }

    private func ask(_ kind: WorkerRequest.Kind) async -> WorkerAnswer {
        guard !ended else { return .deny("The job was stopped.") }
        let id = IDs.make("r")
        return await withCheckedContinuation { continuation in
            waiting[id] = continuation
            emit.yield(.request(WorkerRequest(id: id, kind: kind)))
        }
    }

    private func denyWaiting() {
        for continuation in waiting.values { continuation.resume(returning: .deny("The job was stopped.")) }
        waiting = [:]
    }
}
