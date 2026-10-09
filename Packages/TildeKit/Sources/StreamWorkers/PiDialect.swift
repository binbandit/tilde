import Foundation
import TildeSupport
import WorkerKit

/// Pi (pi.dev) in RPC mode: `pi --mode rpc` takes JSONL commands on stdin and streams
/// session events on stdout, one long-lived process per session. tilde mints the session
/// id and `--session-id` opens or creates it, so resuming is the same command.
///
/// Pi never asks before running a tool, so tilde loads a small extension that holds every
/// shell command and file write until tilde answers through Pi's extension UI
/// sub-protocol. Dialogs from the user's own extensions reach the manager as questions.
struct PiDialect: StreamDialect {
    let label = "Pi"
    let gate = GateChannel.stream
    let briefInPrompt = false
    var interrupt: JSON? { ["type": "abort"] }

    static let gateTitle = "tilde:gate"

    func prepare(_ launch: WorkerLaunch, session: String?, scratch: URL) throws -> [String] {
        let gate = scratch.appending(path: "tilde-gate.ts")
        try Data(Self.gateExtension.utf8).write(to: gate, options: .atomic)
        var arguments = ["--mode", "rpc", "--extension", gate.path, "--append-system-prompt", launch.instructions]
        if let session { arguments += ["--session-id", session] }
        if let model = launch.model { arguments += ["--model", model] }
        return arguments
    }

    func prompt(_ text: String, busy: Bool) -> JSON {
        // Pi ignores `streamingBehavior` when idle and steers when busy, so it's always safe to send.
        ["type": "prompt", "message": .string(text), "streamingBehavior": "steer"]
    }

    func decode(_ line: JSON) -> [StreamSignal] {
        switch line["type"]?.string {
        case "tool_execution_start":
            return [.activity(describe(line["toolName"]?.string ?? "", line["args"] ?? [:]))]
        case "message_end":
            guard let message = line["message"], message["role"]?.string == "assistant" else { return [] }
            let text = (message["content"]?.array ?? [])
                .compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
            var signals: [StreamSignal] = text.isEmpty ? [] : [.message(text)]
            if message["stopReason"]?.string == "error" {
                signals.append(.failure(message["errorMessage"]?.string ?? "Pi's model call failed."))
            }
            return signals
        case "agent_settled":
            return [.turnEnded(ok: line["aborted"]?.bool != true)]
        case "auto_retry_start":
            return [.notice("Model hiccup, retrying (attempt \(line["attempt"]?.int ?? 1))")]
        case "compaction_start":
            return [.notice("Compacting the conversation")]
        case "extension_error":
            return [.notice("A Pi extension failed: \(line["error"]?.string ?? "unknown error")")]
        case "response":
            guard line["success"]?.bool == false else { return [] }
            let error = line["error"]?.string ?? "Pi refused a command."
            // A refused prompt never starts a run, so nothing else will end the turn.
            return line["command"]?.string == "prompt" ? [.failure(error), .turnEnded(ok: false)] : [.notice(error)]
        case "extension_ui_request":
            return request(line)
        default:
            return []
        }
    }

    private func request(_ line: JSON) -> [StreamSignal] {
        guard let id = line["id"]?.string else { return [] }
        let title = line["title"]?.string ?? ""
        func dialog(_ detail: String?, options: [String] = [], confirm: Bool = false) -> [StreamSignal] {
            let question = [title, detail].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n\n")
            return [.dialog(StreamDialog(
                id: id, question: WorkerQuestion(question: question, options: options, multiSelect: false), confirm: confirm))]
        }
        switch line["method"]?.string {
        case "input" where title == Self.gateTitle:
            let call = line["placeholder"]?.string.flatMap { JSON.parse($0) }
            return [.gate(GateCall(id: id, tool: call?["tool"]?.string ?? "", input: call?["input"] ?? [:]))]
        case "confirm": return dialog(line["message"]?.string, options: ["Yes", "No"], confirm: true)
        case "select": return dialog(nil, options: line["options"]?.array?.compactMap(\.string) ?? [])
        case "input": return dialog(line["placeholder"]?.string)
        case "editor": return dialog(line["prefill"]?.string)
        case "notify" where ["warning", "error"].contains(line["notifyType"]?.string):
            return line["message"]?.string.map { [.notice($0)] } ?? []
        default: return []
        }
    }

    func answer(_ call: GateCall, _ verdict: GateVerdict) -> JSON? {
        let value =
            switch verdict {
            case .allow: "allow"
            case .deny(let reason): "deny: \(reason)"
            }
        return ["type": "extension_ui_response", "id": .string(call.id), "value": .string(value)]
    }

    func answer(_ dialog: StreamDialog, _ reply: WorkerAnswer) -> JSON? {
        var response: [String: JSON] = ["type": "extension_ui_response", "id": .string(dialog.id)]
        switch reply {
        case .allow where dialog.confirm: response["confirmed"] = true
        case .allow, .deny: response["cancelled"] = true
        case .reply(let text) where dialog.confirm: response["confirmed"] = .bool(WorkerAnswer.isYes(text))
        case .reply(let text):
            let label = dialog.question.options.first { $0.caseInsensitiveCompare(text) == .orderedSame }
            response["value"] = .string(label ?? text)
        }
        return .object(response)
    }

    func uses(of tool: String, input: JSON) -> [ToolUse] {
        switch tool {
        case "bash": [ToolUse(name: "Bash", input: ["command": input["command"] ?? ""])]
        case "read": [ToolUse(name: "Read", input: ["file_path": input["path"] ?? ""])]
        case "edit": [ToolUse(name: "Edit", input: ["file_path": input["path"] ?? ""])]
        case "write": [ToolUse(name: "Write", input: ["file_path": input["path"] ?? ""])]
        default: [ToolUse(name: tool, input: input)]
        }
    }

    private func describe(_ tool: String, _ input: JSON) -> String {
        switch tool {
        case "grep", "find": "Searching the code"
        case "ls": "Looking around the project"
        case "codemode": "Running a script"
        default: uses(of: tool, input: input).first.map { Activity.describe(tool: $0.name, input: $0.input) } ?? tool
        }
    }

    /// Holds shell commands and file writes for tilde. In RPC mode Pi turns `ctx.ui.input`
    /// into an `extension_ui_request` and waits for the matching `extension_ui_response`.
    static let gateExtension = """
        // Written by tilde for one Pi run. Every shell command and file write waits for tilde,
        // which allows ordinary work at once and escalates anything crossing one of its rails.
        export default function (pi) {
          pi.on("tool_call", async (event, ctx) => {
            if (!["bash", "edit", "write"].includes(event.toolName)) return undefined;
            const call = JSON.stringify({ tool: event.toolName, input: event.input });
            const verdict = await ctx.ui.input("\(gateTitle)", call, { signal: ctx.signal });
            if (verdict === "allow") return undefined;
            return { block: true, reason: (verdict ?? "").replace(/^deny: /, "") || "tilde did not allow this." };
          });
        }

        """
}
