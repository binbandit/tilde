import Foundation
import TildeSupport
import WorkerKit

/// One harness's headless JSON-stream mode, described for `StreamWorker`: how to launch
/// it, what to write to stdin, and what each stdout line means. Dialects only translate;
/// the worker owns the process, the turn, and tilde's gate.
protocol StreamDialect: Sendable {
    /// "Amp", for notices and exit messages.
    var label: String { get }
    var gate: GateChannel { get }
    /// True when the harness has no system-prompt flag, so the supervision brief opens
    /// the first prompt of a new session instead.
    var briefInPrompt: Bool { get }
    /// A stdin line that ends the running turn cleanly before the process is signalled.
    var interrupt: JSON? { get }
    /// True when the harness exits after a failed turn, so its process is done with as the turn ends.
    var exitsOnFailure: Bool { get }

    /// Writes whatever the harness needs into `scratch` (an existing folder outside the
    /// worktree) and returns the arguments for a process on `session`, or a new session when nil.
    func prepare(_ launch: WorkerLaunch, session: String?, scratch: URL) throws -> [String]
    /// The stdin line that delivers a user message. `busy` means a turn is running.
    func prompt(_ text: String, busy: Bool) -> JSON
    func decode(_ line: JSON) -> [StreamSignal]
    /// A harness tool call in Claude Code's names and fields, which `Rails` and `Activity` speak.
    func uses(of tool: String, input: JSON) -> [ToolUse]
    /// The stdin line answering a gate call that arrived on stdout.
    func answer(_ call: GateCall, _ verdict: GateVerdict) -> JSON?
    func answer(_ dialog: StreamDialog, _ reply: WorkerAnswer) -> JSON?
}

extension StreamDialect {
    var interrupt: JSON? { nil }
    var exitsOnFailure: Bool { false }
    func answer(_ call: GateCall, _ verdict: GateVerdict) -> JSON? { nil }
    func answer(_ dialog: StreamDialog, _ reply: WorkerAnswer) -> JSON? { nil }
}

/// How a harness hands tool calls to tilde's gate.
enum GateChannel: Sendable {
    /// Calls arrive as stdout lines and are answered on stdin.
    case stream
    /// The harness runs tilde's helper program for each call (see `GateMailbox`).
    case helper
}

/// One stdout line, translated.
enum StreamSignal: Sendable, Equatable {
    case session(String)
    case activity(String)
    /// A complete assistant message from the main conversation.
    case message(String)
    /// The turn went wrong; this becomes its text when it ends.
    case failure(String)
    case turnEnded(ok: Bool)
    case notice(String)
    /// A tool call the harness holds until tilde rules on it.
    case gate(GateCall)
    /// A question the harness, or one of its extensions, puts to the user.
    case dialog(StreamDialog)
}

struct GateCall: Sendable, Equatable {
    var id: String
    /// The harness's own tool name and input.
    var tool: String
    var input: JSON
}

enum GateVerdict: Sendable, Equatable {
    case allow
    case deny(String)
}

struct StreamDialog: Sendable, Equatable {
    var id: String
    var question: WorkerQuestion
    /// The harness wants yes or no rather than text.
    var confirm: Bool
}

/// A tool call in Claude Code's names and fields ("Bash" + `command`, "Write" + `file_path`).
struct ToolUse: Sendable, Equatable {
    var name: String
    var input: JSON

    /// Every file a Codex-style `*** Begin Patch` touches, as edits.
    static func edits(inPatch patch: String) -> [ToolUse] {
        let markers = ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "]
        return patch.split(separator: "\n").compactMap { line in
            guard let marker = markers.first(where: line.hasPrefix) else { return nil }
            let path = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return ToolUse(name: "Edit", input: ["file_path": .string(path)])
        }
    }
}
