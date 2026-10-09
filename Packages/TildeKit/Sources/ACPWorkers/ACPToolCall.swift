import Foundation
import TildeSupport
import WorkerKit

/// What tilde knows about one ACP tool call, merged across its updates.
///
/// ACP standardizes a tool call's `kind`, `title` and `locations`; `rawInput`
/// is each agent's own, so the command and file paths are read from the keys
/// the common agents use.
struct ACPToolCall: Sendable {
    var title = ""
    var kind = "other"
    var status = "pending"
    var name: String?
    var rawInput: JSON = nil
    var locations: [String] = []
    var diffPaths: [String] = []

    /// Whether tilde lets the call through or puts it to the manager.
    enum Verdict: Equatable {
        case allow
        case ask(rail: String?)
    }

    init(_ update: JSON = [:]) { merge(update) }

    /// Applies a `tool_call` or `tool_call_update`: present fields replace, absent ones stay.
    mutating func merge(_ update: JSON) {
        if let title = update["title"]?.string { self.title = title }
        if let kind = update["kind"]?.string { self.kind = kind }
        if let status = update["status"]?.string { self.status = status }
        if let name = update["name"]?.string { self.name = name }
        // Agents may send `{}` while the input is still streaming in; keep what we had.
        if let input = update["rawInput"], !input.isNull, input != [:] { rawInput = input }
        if let locations = update["locations"]?.array { self.locations = locations.compactMap { $0["path"]?.string } }
        if let content = update["content"]?.array {
            diffPaths = content.filter { $0["type"]?.string == "diff" }.compactMap { $0["path"]?.string }
        }
    }

    var isRunning: Bool { status == "pending" || status == "in_progress" }

    /// The shell command, when the agent says what it is.
    var command: String? {
        let raw = rawInput["command"] ?? rawInput["cmd"]
        if let command = raw?.string { return command }
        if let argv = raw?.array?.compactMap(\.string), !argv.isEmpty { return argv.joined(separator: " ") }
        // Agents that put nothing in rawInput tend to title the call with the command itself.
        return title.contains(" ") ? title : nil
    }

    /// The files it touches.
    var paths: [String] {
        let input = ["path", "file_path", "filePath", "filepath", "absolute_path", "notebook_path"].compactMap { rawInput[$0]?.string }
        let files = (rawInput["files"]?.array ?? []).flatMap { [$0["filePath"]?.string, $0["movePath"]?.string].compactMap(\.self) }
        var seen = Set<String>()
        return (diffPaths + locations + input + files).filter { seen.insert($0).inserted }
    }

    /// Where a command runs, when the agent says.
    private var directories: [String] {
        locations + ["cwd", "workdir", "directory", "dir_path"].compactMap { rawInput[$0]?.string }
    }

    private var url: String? { rawInput["url"]?.string }

    /// A ticker line, like `Activity.describe` for Claude's tools.
    var activity: String? {
        let file = paths.first.map { ($0 as NSString).lastPathComponent }
        switch kind {
        case "execute":
            if let description = rawInput["description"]?.string, !description.isEmpty { return description }
            return "Running " + (command ?? "a command").clipped(to: 48)
        case "read": return "Reading \(file ?? "files")"
        case "edit": return "Editing \(file ?? "files")"
        case "delete": return "Deleting \(file ?? "files")"
        case "move": return "Moving \(file ?? "files")"
        case "search": return "Searching the code"
        case "fetch": return "Reading " + (url.flatMap { URL(string: $0)?.host() } ?? "a web page")
        case "think": return "Thinking"
        case "switch_mode": return "Switching modes"
        default: return title.isEmpty ? name : title.clipped(to: 60)
        }
    }

    /// The tool, as the manager sees it in a permission request.
    var tool: String {
        switch kind {
        case "execute": "Shell"
        case "edit": "Edit"
        case "delete": "Delete"
        case "move": "Move"
        case "read": "Read"
        case "search": "Search"
        case "fetch": "Fetch"
        case "switch_mode": "Mode"
        default: name ?? (title.isEmpty ? "Tool" : title.clipped(to: 40))
        }
    }

    /// What exactly it wants to do, for the manager.
    var action: String {
        switch kind {
        case "execute": return command ?? title
        case "edit", "delete", "move": return paths.isEmpty ? title : paths.joined(separator: ", ")
        case "fetch": return url ?? title
        default:
            let input = rawInput.isNull ? nil : rawInput.compact.clipped(to: 300)
            return [title, input].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    /// tilde's stand-in for an auto mode: anything that stays inside the
    /// worktree and crosses no rail goes ahead; anything that crosses one, or
    /// that tilde can't see into, goes to the manager.
    func verdict(workdir: String) -> Verdict {
        let resolve = { (path: String) in path.hasPrefix("/") || path.hasPrefix("~") ? path : workdir + "/" + path }
        switch kind {
        case "read", "search", "think", "fetch":
            return .allow
        case "execute":
            guard let command else { return .ask(rail: nil) }
            if let rail = Rails.check(tool: "Bash", input: ["command": .string(command)], workdir: workdir) { return .ask(rail: rail) }
            if let outside = directories.first(where: { !Paths.isInside(resolve($0), workdir) }) {
                return .ask(rail: "Runs outside the job's worktree (\(outside))")
            }
            return .allow
        case "edit", "delete", "move":
            guard !paths.isEmpty else { return .ask(rail: nil) }
            let rail = paths.lazy.compactMap { Rails.check(tool: "Write", input: ["file_path": .string(resolve($0))], workdir: workdir) }.first
            return rail.map { .ask(rail: $0) } ?? .allow
        default:
            let outside = paths.first { !Paths.isInside(resolve($0), workdir) }
            return .ask(rail: outside.map { "Reaches outside the job's worktree (\($0))" })
        }
    }
}
