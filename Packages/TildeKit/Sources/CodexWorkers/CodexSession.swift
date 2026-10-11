import Foundation
import TildeSupport
import WorkerKit

public enum CodexEvent: Sendable {
    case turnStarted(id: String)
    case textDelta(String)
    /// A complete agent message.
    case message(String)
    case itemStarted(JSON)
    case turnCompleted(ok: Bool, error: String?)
    case notice(String)
    case exited(status: Int32, detail: String)
}

/// One `codex app-server` process speaking JSON-RPC over stdio.
public actor CodexSession {
    public nonisolated let events: AsyncStream<CodexEvent>
    private let emit: AsyncStream<CodexEvent>.Continuation
    private let cwd: String
    private let arguments: [String]
    private let executable: String
    private let environment: [String: String]
    private let host: any CodexHost
    private var process: ChildProcess?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Result<JSON, Failure>, Never>] = [:]
    public private(set) var threadID: String?
    public private(set) var activeTurn: String?
    /// When Codex last said anything at all.
    public private(set) var lastHeard = Date.now
    /// Tool calls, commands and the like in flight: while one runs, quiet is expected.
    private var working: Set<String> = []

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    /// `overrides` become `-c key=value` config overrides for this process only.
    public init(
        cwd: String, host: any CodexHost, overrides: [String] = [], executable: String = "codex",
        environment: [String: String] = UserEnvironment.shared.variables
    ) {
        self.cwd = cwd
        self.host = host
        self.executable = executable
        self.environment = environment
        arguments = ["app-server"] + overrides.flatMap { ["-c", $0] }
        (events, emit) = AsyncStream<CodexEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    public var isRunning: Bool { process != nil && process?.exitStatus == nil }

    public func start() async throws {
        let process = try ChildProcess(.init(executable: executable, arguments: arguments, cwd: cwd, environment: environment))
        self.process = process
        Task { await self.pump(process) }
        _ = try await request("initialize", [
            "clientInfo": ["name": "tilde", "title": "tilde", "version": "1"],
            "capabilities": ["experimentalApi": true, "requestAttestation": false],
        ])
        try notify("initialized")
    }

    /// Starts a thread. `params` follows ThreadStartParams (model, cwd, sandbox, dynamicTools, ...).
    @discardableResult
    public func startThread(_ params: JSON) async throws -> String {
        let result = try await request("thread/start", params)
        guard let id = result["thread"]?["id"]?.string else { throw Failure(description: "Codex didn't start a thread") }
        threadID = id
        return id
    }

    @discardableResult
    public func resumeThread(_ id: String, _ params: JSON = [:]) async throws -> String {
        var params = params.object ?? [:]
        params["threadId"] = .string(id)
        params["excludeTurns"] = true
        let result = try await request("thread/resume", .object(params))
        threadID = result["thread"]?["id"]?.string ?? id
        return threadID!
    }

    /// Seconds since Codex last said anything, while a turn waits on the model rather than a tool.
    /// A turn that stays silent long after it should have started streaming has stalled.
    public var silence: TimeInterval? {
        guard activeTurn != nil, working.isEmpty else { return nil }
        return Date.now.timeIntervalSince(lastHeard)
    }

    /// Adds to the turn in progress. Throws when there isn't one, rather than starting one.
    public func steer(_ text: String) async throws {
        guard let threadID, let activeTurn else { throw Failure(description: "No turn to steer") }
        let input: JSON = [["type": "text", "text": .string(text), "text_elements": []]]
        _ = try await request("turn/steer", ["threadId": .string(threadID), "expectedTurnId": .string(activeTurn), "input": input])
    }

    /// Starts a turn, or steers the one in progress.
    public func send(_ text: String, effort: String? = nil, outputSchema: JSON? = nil) async throws {
        guard let threadID else { throw Failure(description: "No Codex thread") }
        let input: JSON = [["type": "text", "text": .string(text), "text_elements": []]]
        if let activeTurn {
            _ = try await request("turn/steer", ["threadId": .string(threadID), "expectedTurnId": .string(activeTurn), "input": input])
            return
        }
        var params: [String: JSON] = ["threadId": .string(threadID), "input": input]
        if let effort { params["effort"] = .string(effort) }
        if let outputSchema { params["outputSchema"] = outputSchema }
        let result = try await request("turn/start", .object(params))
        activeTurn = result["turn"]?["id"]?.string
    }

    /// The effective configuration this process loaded (`config.toml` plus overrides).
    public func readConfig() async throws -> JSON {
        try await request("config/read", [:])["config"] ?? [:]
    }

    public func interrupt() async {
        guard let threadID, let activeTurn else { return }
        _ = try? await request("turn/interrupt", ["threadId": .string(threadID), "turnId": .string(activeTurn)])
    }

    public func stop() async {
        await process?.terminate()
    }

    // MARK: JSON-RPC

    /// One JSON-RPC request. A Codex that never answers (stuck behind a prompt, say) fails it after `timeout`
    /// rather than holding up everything waiting on it.
    private func request(_ method: String, _ params: JSON, timeout: Duration = .seconds(120)) async throws -> JSON {
        nextID += 1
        let id = nextID
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expire(id, method)
        }
        defer { deadline.cancel() }
        let result = await withCheckedContinuation { continuation in
            pending[id] = continuation
            do {
                try write(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(returning: .failure(Failure(description: "\(error)")))
            }
        }
        return try result.get()
    }

    private func expire(_ id: Int, _ method: String) {
        pending.removeValue(forKey: id)?.resume(returning: .failure(Failure(description: "Codex didn't answer \(method)")))
    }

    private func notify(_ method: String) throws {
        try write(["jsonrpc": "2.0", "method": .string(method)])
    }

    private func write(_ message: JSON) throws {
        guard let process else { throw Failure(description: "Codex isn't running") }
        try process.write(message.line())
    }

    private func pump(_ process: ChildProcess) async {
        for await line in process.lines {
            lastHeard = .now
            guard let message = JSON.parse(line) else { continue }
            handle(message)
        }
        let status = await process.waitForExit()
        for continuation in pending.values { continuation.resume(returning: .failure(Failure(description: "Codex exited"))) }
        pending = [:]
        activeTurn = nil
        emit.yield(.exited(status: status, detail: String(process.stderr.suffix(2000))))
        emit.finish()
    }

    private func handle(_ message: JSON) {
        let method = message["method"]?.string
        if let id = message["id"], !id.isNull {
            if let method {
                // A request from Codex: answer it off the actor so slow humans don't block the stream.
                let params = message["params"] ?? [:]
                Task {
                    let reply = await self.serve(method, params)
                    try? self.write(reply.merging(["jsonrpc": "2.0", "id": id]))
                }
            } else if let n = id.int, let continuation = pending.removeValue(forKey: n) {
                if let error = message["error"] {
                    continuation.resume(returning: .failure(Failure(description: error["message"]?.string ?? error.compact)))
                } else {
                    continuation.resume(returning: .success(message["result"] ?? nil))
                }
            }
            return
        }

        let params = message["params"] ?? [:]
        switch method {
        case "turn/started":
            activeTurn = params["turn"]?["id"]?.string ?? activeTurn
            working = []
            emit.yield(.turnStarted(id: activeTurn ?? ""))
        case "item/agentMessage/delta":
            if let delta = params["delta"]?.string { emit.yield(.textDelta(delta)) }
        case "item/started":
            guard let item = params["item"] else { return }
            if !Self.quietItems.contains(item["type"]?.string ?? ""), let id = item["id"]?.string { working.insert(id) }
            emit.yield(.itemStarted(item))
        case "item/completed":
            if let id = params["item"]?["id"]?.string { working.remove(id) }
            if params["item"]?["type"]?.string == "agentMessage", let text = params["item"]?["text"]?.string {
                emit.yield(.message(text))
            }
        case "turn/completed":
            activeTurn = nil
            working = []
            let turn = params["turn"]
            emit.yield(.turnCompleted(
                ok: turn?["status"]?.string == "completed", error: turn?["error"]?["message"]?.string))
        case "error":
            if params["willRetry"]?.bool != true, let text = params["error"]?["message"]?.string {
                emit.yield(.notice(text))
            }
        default:
            break
        }
    }

    /// Items the model streams itself; anything else (a command, a tool call) can run quietly for a while.
    private static let quietItems: Set<String> = ["agentMessage", "reasoning", "userMessage"]

    private nonisolated func serve(_ method: String, _ params: JSON) async -> JSON {
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            let ok = await host.approveCommand(
                params["command"]?.string ?? "", cwd: params["cwd"]?.string, reason: params["reason"]?.string)
            return ["result": ["decision": ok ? "accept" : "decline"]]
        case "item/fileChange/requestApproval", "applyPatchApproval":
            let ok = await host.approveFileChange(reason: params["reason"]?.string, root: params["grantRoot"]?.string)
            return ["result": ["decision": ok ? "accept" : "decline"]]
        case "item/tool/requestUserInput":
            let raw = params["questions"]?.array ?? []
            let questions = raw.map {
                WorkerQuestion(
                    question: $0["question"]?.string ?? "",
                    options: ($0["options"]?.array ?? []).compactMap { $0["label"]?.string }, multiSelect: false)
            }
            let answers = await host.answer(questions) ?? []
            var map: [String: JSON] = [:]
            for (q, answer) in zip(raw, answers) {
                if let id = q["id"]?.string { map[id] = ["answers": [.string(answer)]] }
            }
            return ["result": ["answers": .object(map)]]
        case "mcpServer/elicitation/request":
            // Approval prompts from MCP tools arrive as forms; computer use asks
            // this way before touching an app. Anything else we can't fill in.
            let meta = params["_meta"]
            let connector = meta?["connector_name"]?.string ?? params["serverName"]?.string ?? "A tool"
            let message = params["message"]?.string ?? params["description"]?.string ?? "\(connector) wants to act."
            guard meta?["codex_approval_kind"] != nil else {
                return ["result": ["action": "decline", "content": nil, "_meta": nil]]
            }
            let tool = meta?["tool_name"]?.string ?? meta?["tool_title"]?.string ?? Self.toolName(in: message)
            let ok = await host.approveToolUse(connector: connector, tool: tool, message: message)
            return ["result": ["action": ok ? "accept" : "decline", "content": nil, "_meta": nil]]
        case "item/permissions/requestApproval":
            let requested = params["permissions"] ?? [:]
            let ok = await host.approvePermissions(reason: params["reason"]?.string, requested: requested)
            // Granting nothing is how a request is refused.
            let granted: JSON = ok ? .object((requested.object ?? [:]).filter { !$0.value.isNull }) : [:]
            return ["result": ["permissions": granted, "scope": "turn"]]
        case "item/tool/call":
            let result = await host.callTool(params["tool"]?.string ?? "", arguments: params["arguments"] ?? [:])
            return ["result": [
                "contentItems": [["type": "inputText", "text": .string(result.text)]], "success": .bool(!result.isError),
            ]]
        default:
            return ["error": ["code": -32601, "message": .string("tilde doesn't handle \(method)")]]
        }
    }

    /// Plain MCP servers name the tool only in the prompt: `Allow the linear MCP server to run tool "get_issue"?`
    static func toolName(in message: String) -> String? {
        guard let start = message.range(of: "tool \""), let end = message[start.upperBound...].firstIndex(of: "\"") else { return nil }
        let name = message[start.upperBound..<end]
        return name.isEmpty ? nil : String(name)
    }
}
