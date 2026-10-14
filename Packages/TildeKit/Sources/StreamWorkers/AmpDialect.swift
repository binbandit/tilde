import Foundation
import TildeSupport
import WorkerKit

/// Sourcegraph's Amp in execute mode: `amp -x --stream-json --stream-json-input` speaks
/// Claude Code's stream-json on stdout and takes user messages on stdin, one process per
/// thread; `amp threads continue <id>` picks a thread back up the same way.
///
/// In stream-json mode a tool that needs approval ends the run, so tilde starts Amp with a
/// copy of the user's settings whose first permission rules delegate every shell command
/// and file write to tilde's gate helper, which always answers allow or reject.
struct AmpDialect: StreamDialect {
    /// The user's own settings, which tilde's copy builds on so their MCP servers and
    /// preferences still apply.
    var userSettings: URL?

    let label = "Amp"
    let gate = GateChannel.helper
    /// An inference error ends Amp's run with an error result, and the process with it.
    let exitsOnFailure = true
    let briefInPrompt = true

    /// Amp's tools that run commands or change files.
    static let gated = ["Bash", "shell_command", "create_file", "edit_file", "apply_patch", "delete_file", "undo_edit"]

    /// Where Amp reads settings from for this user.
    static func userSettings(in environment: [String: String]) -> URL {
        environment["AMP_SETTINGS_FILE"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory()).appending(path: ".config/amp/settings.json")
    }

    func prepare(_ launch: WorkerLaunch, session: String?, scratch: URL) throws -> [String] {
        let helper = try GateMailbox.installHelper(in: scratch)
        let user = userSettings.flatMap { try? Data(contentsOf: $0) }.flatMap { JSON.parse($0) }
        let settings = scratch.appending(path: "amp-settings.json")
        // A copy of the user's settings can hold tokens: keep it private to them.
        guard FileManager.default.createFile(
            atPath: settings.path, contents: Self.settings(user: user, helper: helper.path).line(),
            attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: settings.path]) }

        var arguments = session.map { ["threads", "continue", $0] } ?? []
        arguments += ["--execute", "--stream-json", "--stream-json-input", "--settings-file", settings.path, "--no-ide"]
        // Amp picks models by mode (smart, rush, deep, ...); a continued thread keeps its own.
        if session == nil, let mode = launch.model { arguments += ["--mode", mode] }
        return arguments
    }

    /// The user's settings with tilde's gate first in line and Amp's allow-everything switch off.
    static func settings(user: JSON?, helper: String) -> JSON {
        var settings = user?.object ?? [:]
        let gate = gated.map { JSON.object(["tool": .string($0), "action": "delegate", "to": .string(helper)]) }
        settings["amp.permissions"] = .array(gate + (settings["amp.permissions"]?.array ?? []))
        settings["amp.dangerouslyAllowAll"] = false
        return .object(settings)
    }

    func prompt(_ text: String) -> JSON {
        ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": .string(text)]]]]
    }

    func decode(_ line: JSON) -> [StreamSignal] {
        switch line["type"]?.string {
        case "system":
            if line["subtype"]?.string == "init" { return line["session_id"]?.string.map { [.session($0)] } ?? [] }
            return line["error"]?.string.map { [.failure($0)] } ?? []
        case "assistant":
            // Subagent traffic carries its parent's tool id; only the main thread speaks for the job.
            guard line["parent_tool_use_id"]?.isNull ?? true, let message = line["message"] else { return [] }
            let blocks = message["content"]?.array ?? []
            var signals: [StreamSignal] = blocks.compactMap { block in
                switch block["type"]?.string {
                case "text": block["text"]?.string.flatMap { $0.isEmpty ? nil : .message($0) }
                case "tool_use": .activity(describe(block["name"]?.string ?? "", block["input"] ?? [:]))
                default: nil
                }
            }
            // Amp's own test for a finished turn: a complete reply that ends the turn and calls no tools.
            if message["stop_reason"]?.string == "end_turn", !blocks.contains(where: { $0["type"]?.string == "tool_use" }) {
                signals.append(.turnEnded(ok: true))
            }
            return signals
        case "result":
            // Long-lived stdin sessions end each prompt on assistant/end_turn. A success
            // result is the run summary (often only at EOF), never a second turn boundary.
            guard line["is_error"]?.bool == true else { return [] }
            return [.failure(line["error"]?.string ?? "Amp stopped with an error."), .turnEnded(ok: false)]
        default:
            return []
        }
    }

    func uses(of tool: String, input: JSON) -> [ToolUse] {
        switch tool {
        case "Bash": [ToolUse(name: "Bash", input: ["command": input["cmd"] ?? ""])]
        case "shell_command": [ToolUse(name: "Bash", input: ["command": input["command"] ?? ""])]
        case "create_file": [ToolUse(name: "Write", input: ["file_path": input["path"] ?? ""])]
        case "edit_file", "undo_edit", "delete_file": [ToolUse(name: "Edit", input: ["file_path": input["path"] ?? ""])]
        case "apply_patch":
            (input.object?.values.compactMap(\.string) ?? []).flatMap(ToolUse.edits(inPatch:))
        case "Read": [ToolUse(name: "Read", input: ["file_path": input["path"] ?? ""])]
        case "read_web_page": [ToolUse(name: "WebFetch", input: ["url": input["url"] ?? ""])]
        case "web_search": [ToolUse(name: "WebSearch", input: input)]
        default: [ToolUse(name: tool, input: input)]
        }
    }

    private func describe(_ tool: String, _ input: JSON) -> String {
        switch tool {
        case "Grep", "glob", "finder": return "Searching the code"
        case "oracle": return "Consulting the oracle"
        case "librarian": return "Researching with the librarian"
        case "look_at": return "Looking at " + (input["path"]?.string.map { ($0 as NSString).lastPathComponent } ?? "a file")
        case "painter": return "Generating an image"
        case "handoff": return "Handing off to a new thread"
        default:
            // Only a patch with no file headers maps to nothing.
            guard let use = uses(of: tool, input: input).first else { return "Editing files" }
            return Activity.describe(tool: use.name, input: use.input)
        }
    }
}
