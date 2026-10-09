import TildeSupport

/// A tool call Claude wants permission for (or an AskUserQuestion it wants answered).
public struct ClaudePermissionRequest: Sendable {
    public var toolName: String
    public var input: JSON
    public var toolUseID: String?
    /// Why Claude escalated, when it says (e.g. auto mode's classifier reason).
    public var reason: String?
    public var blockedPath: String?
}

public enum ClaudePermissionDecision: Sendable {
    /// Run the tool with this (possibly edited) input. For AskUserQuestion the
    /// input carries the `answers` map.
    case allow(JSON)
    case deny(String, interrupt: Bool = false)
}

public enum ClaudeHookDecision: Sendable {
    /// Let Claude's own permission mode decide.
    case proceed
    /// Force a permission prompt, which lands in `ClaudeHost.canUseTool`.
    case ask(reason: String)
    case deny(reason: String)
}

/// The supervising side of a Claude session. tilde answers everything Claude
/// would otherwise ask a human in a terminal.
public protocol ClaudeHost: Sendable {
    func canUseTool(_ request: ClaudePermissionRequest) async -> ClaudePermissionDecision
    func preToolUse(tool: String, input: JSON) async -> ClaudeHookDecision
    /// Handles one JSON-RPC message for a hosted MCP server. Return nil for notifications.
    func mcp(server: String, message: JSON) async -> JSON?
}

extension ClaudeHost {
    public func preToolUse(tool: String, input: JSON) async -> ClaudeHookDecision { .proceed }
    public func mcp(server: String, message: JSON) async -> JSON? { nil }
}
