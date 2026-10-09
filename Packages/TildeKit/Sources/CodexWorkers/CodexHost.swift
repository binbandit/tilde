import TildeSupport
import WorkerKit

/// The supervising side of a Codex thread. Defaults refuse, so a host only
/// implements what it supports.
public protocol CodexHost: Sendable {
    func approveCommand(_ command: String, cwd: String?, reason: String?) async -> Bool
    func approveFileChange(reason: String?, root: String?) async -> Bool
    /// One answer per question, or nil to decline.
    func answer(_ questions: [WorkerQuestion]) async -> [String]?
    func callTool(_ name: String, arguments: JSON) async -> ToolResult
    /// An MCP tool (computer use, mostly) asking before it acts.
    func approveToolUse(connector: String, message: String) async -> Bool
    /// Extra sandbox permissions (network, paths outside the workspace).
    func approvePermissions(reason: String?, requested: JSON) async -> Bool
}

extension CodexHost {
    public func approveCommand(_ command: String, cwd: String?, reason: String?) async -> Bool { false }
    public func approveFileChange(reason: String?, root: String?) async -> Bool { false }
    public func answer(_ questions: [WorkerQuestion]) async -> [String]? { nil }
    public func callTool(_ name: String, arguments: JSON) async -> ToolResult { .error("Unknown tool.") }
    public func approveToolUse(connector: String, message: String) async -> Bool { false }
    public func approvePermissions(reason: String?, requested: JSON) async -> Bool { false }
}
