import Foundation
import TildeSupport

/// Human-sized descriptions of tool calls, in Claude Code's tool vocabulary, which
/// every harness family translates its own tools into.
public enum Activity {
    /// Present tense, for tickers ("Reading Nav.swift").
    public static func describe(tool: String, input: JSON) -> String {
        let file = input["file_path"]?.string.map { ($0 as NSString).lastPathComponent }
        switch tool {
        case "Bash":
            if let description = input["description"]?.string, !description.isEmpty { return description }
            return "Running " + (input["command"]?.string ?? "a command").clipped(to: 48)
        case "Read": return "Reading \(file ?? "a file")"
        case "Edit", "MultiEdit": return "Editing \(file ?? "a file")"
        case "Write": return "Writing \(file ?? "a file")"
        case "NotebookEdit": return "Editing a notebook"
        case "WebSearch": return "Searching the web"
        case "WebFetch": return "Reading " + (input["url"]?.string.flatMap { URL(string: $0)?.host() } ?? "a web page")
        case "Task", "Agent": return "Handing part of it to a subagent"
        case "TodoWrite", "TaskCreate", "TaskUpdate": return "Planning"
        case "Skill": return "Using the \(input["skill"]?.string ?? "a") skill"
        case "ToolSearch": return "Looking for the right tool"
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
                return "Using \(parts.dropFirst().joined(separator: " "))"
            }
            return tool
        }
    }

    /// Exactly what the call would do, for a permission request: the command, the file, the URL.
    public static func action(tool: String, input: JSON) -> String {
        switch tool {
        case "Bash": input["command"]?.string ?? "a command"
        case "Write", "Edit", "MultiEdit": input["file_path"]?.string ?? "a file"
        case "WebFetch": input["url"]?.string ?? "a URL"
        default: input.compact.clipped(to: 300)
        }
    }
}
