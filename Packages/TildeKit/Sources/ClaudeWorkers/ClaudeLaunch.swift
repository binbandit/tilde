import Foundation
import TildeSupport

/// How to start one `claude -p` process.
public struct ClaudeLaunch: Sendable {
    public var cwd: String
    /// tilde mints session ids up front so "take over" and resume are exact.
    public var sessionID: String
    public var resume = false
    public var model: String?
    public var effort: String?
    public var permissionMode = "default"
    /// Replaces Claude Code's system prompt entirely (the manager).
    public var systemPrompt: String?
    /// Appended to Claude Code's own system prompt (workers).
    public var appendSystemPrompt: String?
    public var tools: [String]?
    public var allowedTools: [String] = []
    public var disallowedTools: [String] = []
    public var addDirectories: [String] = []
    /// `nil` loads the user's normal settings, CLAUDE.md, skills and plugins.
    public var settingSources: String?
    public var settings: JSON?
    /// MCP servers tilde hosts in-process; Claude reaches them over the control channel.
    public var hostedServers: [String] = []
    /// Ask Claude to run every tool call past `ClaudeHost.preToolUse` first.
    public var preToolUseHook = false
    public var executable = "claude"
    public var environment = UserEnvironment.shared.variables

    public init(cwd: String, sessionID: String = UUID().uuidString.lowercased()) {
        self.cwd = cwd
        self.sessionID = sessionID
    }

    var arguments: [String] {
        var args = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages",
            "--permission-prompt-tool", "stdio",
            "--permission-mode", permissionMode,
        ]
        args += resume ? ["--resume", sessionID] : ["--session-id", sessionID]
        if let model { args += ["--model", model] }
        if let effort { args += ["--effort", effort] }
        if let systemPrompt { args += ["--system-prompt", systemPrompt] }
        if let appendSystemPrompt { args += ["--append-system-prompt", appendSystemPrompt] }
        if let tools { args += ["--tools", tools.joined(separator: ",")] }
        if !allowedTools.isEmpty { args += ["--allowedTools", allowedTools.joined(separator: ",")] }
        if !disallowedTools.isEmpty { args += ["--disallowedTools", disallowedTools.joined(separator: ",")] }
        for dir in addDirectories { args += ["--add-dir", dir] }
        if let settingSources { args += ["--setting-sources", settingSources] }
        if let settings { args += ["--settings", settings.compact] }
        if !hostedServers.isEmpty {
            let servers = JSON.object(Dictionary(uniqueKeysWithValues: hostedServers.map {
                ($0, JSON.object(["type": "sdk", "name": .string($0)]))
            }))
            args += ["--mcp-config", JSON.object(["mcpServers": servers]).compact]
        }
        return args
    }
}
