import Foundation

/// A terminal handoff crosses two parsers: the shell, then AppleScript's string literal.
nonisolated enum TerminalCommand {
    static func shell(_ command: String, in directory: String) -> String {
        let quoted = "'" + directory.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        return "cd -- \(quoted) && \(command)"
    }

    static func appleScript(_ command: String, in directory: String) -> String {
        "tell application \"Terminal\" to do script \(literal(shell(command, in: directory)))"
    }

    static func literal(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
