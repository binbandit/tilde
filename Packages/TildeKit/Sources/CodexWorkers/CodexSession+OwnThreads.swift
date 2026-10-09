import TildeSupport

/// Threads that are tilde's own (the manager, memory passes, the background review) aren't the
/// owner's Codex sessions, so they don't load what the owner set up for those: plugins (computer
/// use, the browser), account connectors, MCP servers and hooks.
extension CodexSession {
    /// Settings for a process that runs tilde's own threads. `connectors` keeps the account's
    /// apps (GitHub, Gmail, Calendar, ...) for the review, which fences them to reads.
    public static func ownProcess(connectors: Bool = false) -> [String] {
        ["features.plugins=false", "features.hooks=false"] + (connectors ? [] : ["features.apps=false"])
    }

    /// Thread config turning off every MCP server in the owner's config. (`-c mcp_servers={}`
    /// doesn't: Codex merges an override into the configured servers rather than replacing them.)
    public func serversOff() async throws -> JSON {
        let servers = try await readConfig()["mcp_servers"]?.object ?? [:]
        return ["mcp_servers": .object(servers.mapValues { _ in ["enabled": false] })]
    }
}
