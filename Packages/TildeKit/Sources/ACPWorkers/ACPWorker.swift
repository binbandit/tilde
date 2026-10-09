import Foundation
import TildeSupport
import WorkerKit

/// A worker for any agent that speaks the Agent Client Protocol (v1).
///
/// ACP agents ask before they act. tilde answers like an auto mode: work that
/// stays inside the worktree goes ahead, while anything crossing a rail (or
/// that tilde can't see into) becomes a request for the manager. ACP has no
/// system prompt, so the supervision brief opens a new session's first prompt.
public actor ACPWorker: Worker {
    public nonisolated let events: AsyncStream<WorkerEvent>
    private let emit: AsyncStream<WorkerEvent>.Continuation
    private let command: ACPCommand
    private var launch: WorkerLaunch
    private var connection: ACPConnection?
    private var sessionID: String?
    /// From `start` until the last queued prompt is answered.
    private var busy = false
    /// Steers that arrived mid-turn; ACP v1 has no way to add to a running turn.
    private var queued: [String] = []
    private var stopping = false
    /// While `session/load` replays history we've already reported.
    private var replaying = false
    private var turn = Turn()
    private var lastMessage = ""
    /// What the manager turned down this turn, in case the agent stops without a word.
    private var declined: [String] = []
    private var waiting: [String: CheckedContinuation<WorkerAnswer, Never>] = [:]
    /// Outside paths the manager let this session write, so a later `fs/write_text_file` doesn't ask twice.
    private var approvedPaths: [String] = []
    private var idle: [CheckedContinuation<Void, Never>] = []

    /// What the current prompt has streamed so far.
    private struct Turn {
        var toolCalls: [String: ACPToolCall] = [:]
        var text = ""
        var messageID: String?
        var activity: String?
    }

    public init(_ command: ACPCommand, launch: WorkerLaunch) {
        self.command = command
        self.launch = launch
        (events, emit) = AsyncStream<WorkerEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    public func start(brief: String) async throws {
        busy = true
        stopping = false
        do {
            let connection = try ACPConnection(.init(
                executable: command.executable, arguments: command.arguments, cwd: launch.workdir, environment: command.environment))
            self.connection = connection
            connection.listen { [weak self] in await self?.receive($0, from: connection) }
            let fresh = try await open(connection)
            run(fresh ? Self.preamble(launch.instructions, brief) : brief)
        } catch {
            busy = false
            queued = []
            // Detach first: the caller hears about this failure from the throw, not an `.exited`.
            let failed = connection
            connection = nil
            await failed?.terminate()
            throw error
        }
    }

    public func steer(_ text: String) async throws {
        if busy {
            queued.append(text)
            return
        }
        guard let connection, await !connection.hasExited else {
            // The agent is gone (crash, restart): reopen its session and carry on.
            if let sessionID {
                launch.sessionID = sessionID
                launch.resume = true
            }
            try await start(brief: text)
            return
        }
        run(text)
    }

    public func resolve(_ requestID: String, _ answer: WorkerAnswer) {
        waiting.removeValue(forKey: requestID)?.resume(returning: answer)
    }

    /// Cancels the turn, gives the agent a moment to wind down, then ends its process group.
    public func stop() async {
        stopping = true
        queued = []
        if busy, let sessionID { await connection?.notify("session/cancel", ["sessionId": .string(sessionID)]) }
        // Pending permission requests now answer `cancelled`, as the spec requires after a cancel.
        for continuation in waiting.values { continuation.resume(returning: .deny("The job was stopped.")) }
        waiting = [:]
        await settle(within: .seconds(2))
        await connection?.terminate()
    }

    // MARK: Session

    /// Negotiates the protocol and opens the session. Returns whether it's a new one.
    private func open(_ connection: ACPConnection) async throws -> Bool {
        let hello = try await connection.request("initialize", [
            "protocolVersion": 1,
            "clientCapabilities": [
                "fs": ["readTextFile": true, "writeTextFile": true],
                "terminal": false,
                "elicitation": ["form": [:]],
            ],
            "clientInfo": ["name": "tilde", "title": "tilde", "version": "1"],
        ])
        guard let version = hello["protocolVersion"]?.int, version == 1 else {
            throw ACPError(code: ACPError.invalidParams, message: "\(command.label) speaks ACP version \(hello["protocolVersion"]?.compact ?? "?"); tilde speaks 1")
        }
        let capabilities = hello["agentCapabilities"] ?? [:]
        let base: [String: JSON] = ["cwd": .string(launch.workdir), "mcpServers": []]
        var session: JSON = [:]
        var fresh = true

        if launch.resume, let id = launch.sessionID {
            // `session/resume` skips the history replay that `session/load` sends.
            let canResume = capabilities["sessionCapabilities"]?["resume"].map { !$0.isNull } ?? false
            let method = canResume ? "session/resume" : capabilities["loadSession"]?.bool == true ? "session/load" : nil
            if let method {
                do {
                    replaying = method == "session/load"
                    defer { replaying = false }
                    session = try await call(connection, method, .object(base.merging(["sessionId": .string(id)]) { $1 }))
                    sessionID = id
                    fresh = false
                } catch let error as ACPError where error.code != ACPError.authRequired {
                    emit.yield(.notice("Couldn't reopen \(command.label) session \(id) (\(error)), so this is a fresh one"))
                }
            } else {
                emit.yield(.notice("\(command.label) can't reopen sessions, so this is a fresh one"))
            }
        }
        if fresh {
            session = try await call(connection, "session/new", .object(base))
            guard let id = session["sessionId"]?.string else {
                throw ACPError(code: ACPError.internalError, message: "\(command.label) didn't start a session")
            }
            sessionID = id
        }
        emit.yield(.session(id: sessionID!))
        if command.selectsModel { await chooseModel(from: session["configOptions"], on: connection) }
        return fresh
    }

    /// A setup request, with sign-in failures explained.
    private func call(_ connection: ACPConnection, _ method: String, _ params: JSON) async throws -> JSON {
        do {
            return try await connection.request(method, params)
        } catch let error as ACPError where error.code == ACPError.authRequired {
            throw ACPError(code: error.code, message: "\(command.label) isn't signed in. Run `\(command.executable)` in a terminal to sign in. (\(error.message))")
        }
    }

    /// Picks `launch.model` through the agent's model selector, when it has one.
    private func chooseModel(from options: JSON?, on connection: ACPConnection) async {
        guard let model = launch.model, let sessionID,
              let selector = options?.array?.first(where: { $0["category"]?.string == "model" && $0["type"]?.string == "select" })
        else { return }
        // Options come flat or in groups.
        let choices = (selector["options"]?.array ?? []).flatMap { $0["options"]?.array ?? [$0] }
        let match = choices.first { $0["value"]?.string == model }
            ?? choices.first { $0["name"]?.string?.caseInsensitiveCompare(model) == .orderedSame }
        guard let value = match?["value"]?.string else {
            emit.yield(.notice("\(command.label) has no model \(model); using \(selector["currentValue"]?.string ?? "its default")"))
            return
        }
        guard value != selector["currentValue"]?.string else { return }
        do {
            _ = try await connection.request("session/set_config_option", [
                "sessionId": .string(sessionID), "configId": selector["id"] ?? "model", "value": .string(value),
            ])
        } catch {
            emit.yield(.notice("Couldn't switch \(command.label) to \(model): \(error)"))
        }
    }

    static func preamble(_ instructions: String, _ brief: String) -> String {
        "<instructions from=\"tilde\">\n\(instructions)\n</instructions>\n\n\(brief)"
    }

    // MARK: Turns

    private func run(_ text: String) {
        busy = true
        Task { await self.prompt(text) }
    }

    /// Prompts until nothing is queued, then reports it all as one turn, so
    /// the manager reviews the work once the steer has been acted on too.
    private func prompt(_ text: String) async {
        defer {
            busy = false
            wake()
        }
        guard let connection, let sessionID else { return }
        var text = text
        lastMessage = ""
        declined = []
        while true {
            turn = Turn()
            var ok = false, reason: String?
            do {
                let result = try await connection.request("session/prompt", [
                    "sessionId": .string(sessionID), "prompt": [["type": "text", "text": .string(text)]],
                ])
                (ok, reason) = Self.outcome(result["stopReason"]?.string, label: command.label)
            } catch {
                reason = "\(error)"
            }
            finishMessage()
            // A crash is reported once, as `.exited`; a deliberate stop needs no report.
            let exited = await connection.hasExited
            if stopping || exited { break }
            if !queued.isEmpty {
                text = queued.joined(separator: "\n\n")
                queued = []
                continue
            }
            let summary = [reason, lastMessage.isEmpty ? silence : lastMessage].compactMap(\.self).joined(separator: "\n\n")
            emit.yield(.turnEnded(ok: ok, text: summary))
            break
        }
    }

    /// Some agents end the turn without a word once a request is declined.
    private var silence: String {
        declined.isEmpty
            ? "\(command.label) ended the turn without a reply."
            : "\(command.label) ended the turn without a reply after tilde declined: \(declined.joined(separator: "; "))"
    }

    static func outcome(_ stopReason: String?, label: String) -> (ok: Bool, reason: String?) {
        switch stopReason {
        case "end_turn": (true, nil)
        case "max_tokens": (false, "\(label) hit its output token limit.")
        case "max_turn_requests": (false, "\(label) hit its limit of model requests for one turn.")
        case "refusal": (false, "\(label) refused to continue.")
        case "cancelled": (false, "The turn was cancelled.")
        default: (false, "\(label) stopped (\(stopReason ?? "no reason given")).")
        }
    }

    /// Waits until the current turn is over, or `limit` passes.
    private func settle(within limit: Duration) async {
        guard busy else { return }
        let timer = Task {
            try? await Task.sleep(for: limit)
            wake()
        }
        await withCheckedContinuation { idle.append($0) }
        timer.cancel()
    }

    private func wake() {
        idle.forEach { $0.resume() }
        idle = []
    }

    // MARK: Updates

    private func receive(_ message: ACPConnection.Incoming, from source: ACPConnection) {
        switch message {
        case .notification("session/update", let params):
            guard !replaying, params["sessionId"]?.string == sessionID else { return }
            apply(params["update"] ?? [:])
        case .notification:
            break
        case .request(let id, let method, let params):
            // Off the stream: a request may wait on the manager for a while.
            Task {
                let reply = await self.serve(method, params)
                await source.respond(to: id, reply)
            }
        case .exited(let status, let stderr):
            guard source === connection else { return }
            for continuation in waiting.values { continuation.resume(returning: .deny("The worker exited.")) }
            waiting = [:]
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            emit.yield(.exited(stopping || status == 0 ? nil : "\(command.label) exited (\(status)). \(detail)"))
        }
    }

    private func apply(_ update: JSON) {
        switch update["sessionUpdate"]?.string {
        case "agent_message_chunk":
            guard let text = update["content"]?["text"]?.string else { return }
            let messageID = update["messageId"]?.string
            if let messageID, messageID != turn.messageID { finishMessage() }
            turn.messageID = messageID ?? turn.messageID
            turn.text += text
        case "agent_thought_chunk":
            tick("Thinking")
        case "tool_call", "tool_call_update":
            finishMessage()
            guard let id = update["toolCallId"]?.string else { return }
            var call = turn.toolCalls[id] ?? ACPToolCall()
            call.merge(update)
            turn.toolCalls[id] = call
            if call.isRunning, let activity = call.activity { tick(activity) }
        case "plan":
            let current = update["entries"]?.array?.first { $0["status"]?.string == "in_progress" }?["content"]?.string
            tick(current.map { $0.clipped(to: 60) } ?? "Planning")
        default:
            break
        }
    }

    /// Text before a tool call, a new message id, or the end of the turn is one whole message.
    private func finishMessage() {
        let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
        turn.text = ""
        turn.messageID = nil
        guard !text.isEmpty else { return }
        lastMessage = text
        emit.yield(.message(text))
    }

    private func tick(_ activity: String) {
        guard activity != turn.activity else { return }
        turn.activity = activity
        emit.yield(.activity(activity))
    }

    // MARK: Agent requests

    private func serve(_ method: String, _ params: JSON) async -> Result<JSON, ACPError> {
        switch method {
        case "session/request_permission": .success(await permission(params))
        case "fs/read_text_file": read(params)
        case "fs/write_text_file": await write(params)
        case "elicitation/create": await elicit(params)
        default: .failure(ACPError(code: ACPError.methodNotFound, message: "tilde doesn't handle \(method)"))
        }
    }

    private func permission(_ params: JSON) async -> JSON {
        let id = params["toolCall"]?["toolCallId"]?.string ?? ""
        var call = turn.toolCalls[id] ?? ACPToolCall()
        call.merge(params["toolCall"] ?? [:])
        let allowed: Bool
        switch call.verdict(workdir: launch.workdir) {
        case .allow:
            allowed = true
        case .ask(let rail):
            allowed = await ask(.permission(tool: call.tool, action: call.action, rail: rail)).isAllow
            if allowed, call.kind != "execute" { approvedPaths += call.paths.map(resolve) }
            if !allowed { declined.append("\(call.tool): \(call.action)") }
        }
        if stopping { return ["outcome": ["outcome": "cancelled"]] }
        let options = params["options"]?.array ?? []
        let pick = { (kind: String) in options.first { $0["kind"]?.string == kind }?["optionId"] }
        // Never "always": each call is judged on its own.
        if allowed, let option = pick("allow_once") { return ["outcome": ["outcome": "selected", "optionId": option]] }
        if allowed { emit.yield(.notice("\(command.label) only offered a standing permission for \(call.tool), so tilde declined")) }
        if let option = pick("reject_once") { return ["outcome": ["outcome": "selected", "optionId": option]] }
        return ["outcome": ["outcome": "cancelled"]]
    }

    private func read(_ params: JSON) -> Result<JSON, ACPError> {
        guard let raw = params["path"]?.string else { return .failure(ACPError(code: ACPError.invalidParams, message: "No path")) }
        let path = resolve(raw)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .failure(ACPError(code: ACPError.resourceNotFound, message: "Can't read \(path)"))
        }
        let start = max(params["line"]?.int ?? 1, 1)
        guard start > 1 || params["limit"]?.int != nil else { return .success(["content": .string(text)]) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst(start - 1)
        return .success(["content": .string(lines.prefix(params["limit"]?.int ?? lines.count).joined(separator: "\n"))])
    }

    /// Writes inside the worktree; outside it, only what the manager approves.
    private func write(_ params: JSON) async -> Result<JSON, ACPError> {
        guard let raw = params["path"]?.string, let content = params["content"]?.string else {
            return .failure(ACPError(code: ACPError.invalidParams, message: "Needs a path and content"))
        }
        let path = resolve(raw)
        if let rail = Rails.check(tool: "Write", input: ["file_path": .string(path)], workdir: launch.workdir),
           !approvedPaths.contains(where: { Paths.isInside(path, $0) }) {
            guard await ask(.permission(tool: "Write", action: path, rail: rail)).isAllow, !stopping else {
                declined.append("Write: \(path)")
                return .failure(ACPError(code: ACPError.internalError, message: "tilde refused: \(rail)"))
            }
            approvedPaths.append(path)
        }
        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // In place rather than atomically, so the file keeps its mode (scripts stay executable).
            try Data(content.utf8).write(to: url)
            return .success([:])
        } catch {
            return .failure(ACPError(code: ACPError.internalError, message: error.localizedDescription))
        }
    }

    private func elicit(_ params: JSON) async -> Result<JSON, ACPError> {
        guard params["mode"]?.string == "form" else {
            return .failure(ACPError(code: ACPError.invalidParams, message: "tilde only answers form elicitations"))
        }
        let form = ACPForm(params)
        let answer = await ask(.question(form.questions))
        if stopping { return .success(["action": "cancel"]) }
        switch answer {
        case .reply(let text): return .success(["action": "accept", "content": form.content(text)])
        case .allow: return .success(form.fields.isEmpty ? ["action": "accept"] : ["action": "cancel"])
        case .deny: return .success(["action": "decline"])
        }
    }

    private func ask(_ kind: WorkerRequest.Kind) async -> WorkerAnswer {
        if stopping { return .deny("The job was stopped.") }
        let id = IDs.make("r")
        return await withCheckedContinuation { continuation in
            waiting[id] = continuation
            emit.yield(.request(WorkerRequest(id: id, kind: kind)))
        }
    }

    /// ACP paths are absolute; be forgiving of agents that send relative ones.
    private func resolve(_ path: String) -> String {
        path.hasPrefix("/") ? path : (launch.workdir as NSString).appendingPathComponent(path)
    }
}
