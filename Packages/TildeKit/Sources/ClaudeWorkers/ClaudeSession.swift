import Foundation
import TildeSupport

public enum ClaudeEvent: Sendable {
    case ready(sessionID: String, model: String)
    /// Streaming assistant text from the main conversation (not subagents).
    case textDelta(String)
    case text(String)
    case toolUse(id: String, name: String, input: JSON)
    case toolResult(id: String, isError: Bool, output: String)
    case turnDone(ClaudeTurn)
    /// Retries, compaction, rate-limit warnings: worth a status line, not a decision.
    case notice(String)
    case exited(status: Int32, detail: String)
}

public struct ClaudeTurn: Sendable {
    public var ok: Bool
    public var text: String
    public var sessionID: String
    public var costUSD: Double?
    public var denials: [String]
}

/// One live `claude -p` process speaking the stream-json control protocol.
public actor ClaudeSession {
    public nonisolated let launch: ClaudeLaunch
    public nonisolated let events: AsyncStream<ClaudeEvent>
    private let emit: AsyncStream<ClaudeEvent>.Continuation
    private let host: any ClaudeHost
    private var process: ChildProcess?
    private var pendingControl: [String: CheckedContinuation<JSON, Never>] = [:]
    private var inFlight: [String: Task<Void, Never>] = [:]

    public init(_ launch: ClaudeLaunch, host: any ClaudeHost) {
        self.launch = launch
        self.host = host
        (events, emit) = AsyncStream<ClaudeEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    public var isRunning: Bool { process?.exitStatus == nil && process != nil }

    public func start() async throws {
        let process = try ChildProcess(.init(
            executable: launch.executable, arguments: launch.arguments, cwd: launch.cwd,
            environment: launch.environment))
        self.process = process
        Task { await self.pump(process) }

        var initialize: [String: JSON] = ["subtype": "initialize"]
        if !launch.hostedServers.isEmpty { initialize["sdkMcpServers"] = .array(launch.hostedServers.map { .string($0) }) }
        if launch.preToolUseHook {
            initialize["hooks"] = ["PreToolUse": [["hookCallbackIds": [JSON.string(Self.preToolUseCallback)]]]]
        }
        _ = try await control(.object(initialize))
    }

    /// Sends a user turn. Claude queues it if a turn is already running.
    public func send(_ text: String) throws {
        try write([
            "type": "user", "uuid": .string(UUID().uuidString.lowercased()), "session_id": "",
            "message": ["role": "user", "content": .string(text)], "parent_tool_use_id": nil,
        ])
    }

    /// Stops the current turn without ending the session.
    public func interrupt() async {
        _ = try? await control(["subtype": "interrupt"])
    }

    /// Ends the session: closing stdin lets Claude finish cleanly; the group is killed after `grace`.
    public func stop(grace: Duration = .seconds(5)) async {
        inFlight.values.forEach { $0.cancel() }
        await process?.terminate(grace: grace)
    }

    // MARK: Wire

    private static let preToolUseCallback = "tilde.pretool"

    private func write(_ message: JSON) throws {
        guard let process else { throw ChildProcess.Failure.stdinClosed }
        try process.write(message.line())
    }

    private func control(_ request: JSON) async throws -> JSON {
        let id = "tilde-\(UUID().uuidString.lowercased())"
        try write(["type": "control_request", "request_id": .string(id), "request": request])
        return await withCheckedContinuation { pendingControl[id] = $0 }
    }

    private func respond(_ requestID: String, _ response: JSON) {
        try? write(["type": "control_response", "response": [
            "subtype": "success", "request_id": .string(requestID), "response": response,
        ]])
    }

    private func pump(_ process: ChildProcess) async {
        for await line in process.lines {
            guard let message = JSON.parse(line) else { continue }
            handle(message)
        }
        let status = await process.waitForExit()
        for continuation in pendingControl.values { continuation.resume(returning: nil) }
        pendingControl = [:]
        emit.yield(.exited(status: status, detail: String(process.stderr.suffix(2000))))
        emit.finish()
    }

    private func handle(_ message: JSON) {
        switch message["type"]?.string {
        case "control_request":
            guard let id = message["request_id"]?.string, let request = message["request"] else { return }
            // Each request is answered on its own task: a permission prompt can
            // wait hours for a human while MCP calls keep flowing.
            inFlight[id] = Task {
                let response = await self.answer(request)
                self.finish(id, response)
            }
        case "control_response":
            let response = message["response"]
            if let id = response?["request_id"]?.string, let continuation = pendingControl.removeValue(forKey: id) {
                continuation.resume(returning: response?["response"] ?? nil)
            }
        case "control_cancel_request":
            if let id = message["request_id"]?.string { inFlight.removeValue(forKey: id)?.cancel() }
        case "system":
            switch message["subtype"]?.string {
            case "init":
                emit.yield(.ready(
                    sessionID: message["session_id"]?.string ?? launch.sessionID,
                    model: message["model"]?.string ?? ""))
            case "api_retry":
                emit.yield(.notice("Claude API hiccup, retrying (attempt \(message["attempt"]?.int ?? 0))"))
            case "compact_boundary":
                emit.yield(.notice("Compacted the conversation"))
            default: break
            }
        case "stream_event":
            guard message["parent_tool_use_id"]?.isNull ?? true else { return }
            let event = message["event"]
            if event?["type"]?.string == "content_block_delta", event?["delta"]?["type"]?.string == "text_delta",
                let text = event?["delta"]?["text"]?.string
            {
                emit.yield(.textDelta(text))
            }
        case "assistant":
            guard message["parent_tool_use_id"]?.isNull ?? true else { return }
            for block in message["message"]?["content"]?.array ?? [] {
                switch block["type"]?.string {
                case "text":
                    if let text = block["text"]?.string, !text.isEmpty { emit.yield(.text(text)) }
                case "tool_use":
                    emit.yield(.toolUse(
                        id: block["id"]?.string ?? "", name: block["name"]?.string ?? "", input: block["input"] ?? nil))
                default: break
                }
            }
        case "user":
            guard message["parent_tool_use_id"]?.isNull ?? true else { return }
            for block in message["message"]?["content"]?.array ?? [] where block["type"]?.string == "tool_result" {
                emit.yield(.toolResult(
                    id: block["tool_use_id"]?.string ?? "", isError: block["is_error"]?.bool ?? false,
                    output: Self.flatten(block["content"])))
            }
        case "result":
            emit.yield(.turnDone(ClaudeTurn(
                ok: message["subtype"]?.string == "success" && !(message["is_error"]?.bool ?? false),
                text: message["result"]?.string ?? message["errors"]?.array?.compactMap(\.string).joined(separator: "\n") ?? "",
                sessionID: message["session_id"]?.string ?? launch.sessionID,
                costUSD: message["total_cost_usd"]?.number,
                denials: (message["permission_denials"]?.array ?? []).compactMap { $0["tool_name"]?.string })))
        case "rate_limit_event":
            if message["rate_limit_info"]?["status"]?.string == "rejected" {
                emit.yield(.notice("Hit the Claude usage limit"))
            }
        default: break
        }
    }

    private func finish(_ id: String, _ response: JSON) {
        guard inFlight.removeValue(forKey: id) != nil else { return }
        respond(id, response)
    }

    private nonisolated func answer(_ request: JSON) async -> JSON {
        switch request["subtype"]?.string {
        case "can_use_tool":
            let decision = await host.canUseTool(ClaudePermissionRequest(
                toolName: request["tool_name"]?.string ?? "", input: request["input"] ?? [:],
                toolUseID: request["tool_use_id"]?.string, reason: request["decision_reason"]?.string,
                blockedPath: request["blocked_path"]?.string))
            switch decision {
            case .allow(let input): return ["behavior": "allow", "updatedInput": input]
            case .deny(let message, let interrupt):
                return ["behavior": "deny", "message": .string(message), "interrupt": .bool(interrupt)]
            }
        case "hook_callback":
            let input = request["input"] ?? [:]
            let decision = await host.preToolUse(tool: input["tool_name"]?.string ?? "", input: input["tool_input"] ?? [:])
            let output: (String, String)? =
                switch decision {
                case .proceed: nil
                case .ask(let reason): ("ask", reason)
                case .deny(let reason): ("deny", reason)
                }
            guard let (verdict, reason) = output else { return [:] }
            return ["hookSpecificOutput": [
                "hookEventName": "PreToolUse", "permissionDecision": .string(verdict),
                "permissionDecisionReason": .string(reason),
            ]]
        case "mcp_message":
            let server = request["server_name"]?.string ?? ""
            let reply = await host.mcp(server: server, message: request["message"] ?? [:])
            // Notifications get an empty ack; Claude only needs a response to unblock.
            return ["mcp_response": reply ?? ["jsonrpc": "2.0", "id": 0, "result": [:]]]
        default:
            return [:]
        }
    }

    static func flatten(_ content: JSON?) -> String {
        if let text = content?.string { return text }
        return (content?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
    }
}
