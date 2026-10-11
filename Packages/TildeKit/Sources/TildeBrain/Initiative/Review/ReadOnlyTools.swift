import TildeSupport

/// How the background review is kept read-only in the owner's connected apps.
///
/// `approvalPolicy: never` isn't enough on its own: Codex runs any tool config.toml pre-approves
/// (a Linear `save_issue` set to `approve`, say) without asking. So the review's thread switches
/// every connector to `writes` mode, where only tools annotated read-only run unasked and every
/// other call comes to tilde as a prompt, and `allows` answers each prompt by the tool's name.
/// Nothing else (commands, sandbox, permissions) can escalate at all, and plugins, whose servers
/// (computer use, the browser) act rather than read, aren't loaded (`CodexSession.ownProcess`).
enum ReadOnlyTools {
    /// Escalate nothing but connector tool prompts.
    static let approvalPolicy: JSON = [
        "granular": [
            "sandbox_approval": false, "rules": false, "skill_approval": false, "request_permissions": false,
            "mcp_elicitations": true,
        ],
    ]

    private static let reads: Set<String> = ["get", "list", "search", "read", "query", "fetch", "view"]

    /// Words that betray a change even after a reading verb ("get_or_create", "list_and_archive").
    /// Only unambiguous verbs: nouns like "commit", "comment" or "run" are things reads return.
    private static let changes: Set<String> = [
        "add", "append", "apply", "approve", "archive", "assign", "buy", "cancel", "close", "create", "delete", "disable",
        "edit", "enable", "exec", "execute", "insert", "install", "invite", "mark", "modify", "move", "patch", "publish",
        "purchase", "push", "put", "reject", "remove", "rename", "reopen", "replace", "reply", "resolve", "revert", "save",
        "send", "set", "share", "submit", "unarchive", "unassign", "uninstall", "unshare", "update", "upload", "upsert", "write",
    ]

    /// What a "read" can't be about: a tool that fetches any URL, runs any query or makes any request can
    /// write, or carry what the review has read (mail, the calendar, the notebook) somewhere else.
    private static let anything: Set<String> = ["url", "urls", "sql", "http", "https", "request", "requests", "web", "webpage", "raw", "graphql"]

    /// Whether a connector tool reads like a read: it starts with a reading verb, names what it reads (not just
    /// anything: a URL, SQL, the web), and says nothing about changing anything. Account connectors namespace
    /// their tools (`gmail.search_emails`); the verb follows the last dot.
    static func allows(_ tool: String) -> Bool {
        let words = words(of: tool.split(separator: ".").last.map(String.init) ?? "")
        guard let verb = words.first, reads.contains(verb), words.count > 1 else { return false }
        return !words.contains(where: changes.contains) && !words.contains(where: anything.contains)
    }

    /// `list_issues`, `getIssue`, `search-docs`, "List issues": lowercased words.
    static func words(of name: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in name {
            if character.isLetter || character.isNumber {
                if character.isUppercase, let last = current.last, last.isLowercase || last.isNumber {
                    words.append(current)
                    current = ""
                }
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }

    /// Thread config that puts every app (the account's connectors: GitHub, Gmail, Calendar, ...)
    /// and every configured MCP server, and each tool config.toml pre-approves, in `writes` mode.
    /// Nested objects, not dotted keys, so any server name works; Codex merges them into config.
    static func fence(_ config: JSON) -> JSON {
        let app: [String: JSON] = ["default_tools_approval_mode": "writes", "destructive_enabled": false]
        var apps: [String: JSON] = ["_default": .object(app)]
        for (name, entry) in config["apps"]?.object ?? [:] { apps[name] = .object(app.merging(tools(entry)) { $1 }) }
        let servers = (config["mcp_servers"]?.object ?? [:]).mapValues { entry in
            JSON.object(["default_tools_approval_mode": "writes"].merging(tools(entry)) { $1 })
        }
        return ["apps": .object(apps), "mcp_servers": .object(servers)]
    }

    /// Each tool config.toml names (to pre-approve it, say), put back in `writes` mode.
    private static func tools(_ entry: JSON) -> [String: JSON] {
        guard let tools = entry["tools"]?.object, !tools.isEmpty else { return [:] }
        return ["tools": .object(tools.mapValues { _ in ["approval_mode": "writes"] })]
    }
}
