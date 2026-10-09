import TildeSupport

/// How the background review is kept read-only in the owner's connected apps.
///
/// `approvalPolicy: never` isn't enough on its own: Codex runs any tool config.toml pre-approves
/// (a Linear `save_issue` set to `approve`, say) without asking. So the review's thread switches
/// every connector to `writes` mode, where only tools annotated read-only run unasked and every
/// other call comes to tilde as a prompt, and `allows` answers each prompt by the tool's name.
/// Nothing else (commands, sandbox, permissions) can escalate at all.
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

    /// Whether a connector tool reads like a read: it starts with a reading verb and says nothing about changing anything.
    static func allows(_ tool: String) -> Bool {
        let words = words(of: tool)
        guard let verb = words.first, reads.contains(verb) else { return false }
        return !words.contains(where: changes.contains)
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

    /// Thread config that puts every configured MCP server and app (and each tool config.toml
    /// pre-approves) in `writes` mode. Nil when a name can't be written as a dotted config key;
    /// the review then runs without connectors rather than with unfenced ones.
    static func fence(_ config: JSON) -> [String: JSON]? {
        var fence: [String: JSON] = [:]
        for table in ["mcp_servers", "apps"] {
            for (name, entry) in config[table]?.object ?? [:] {
                guard isBareKey(name) else { return nil }
                fence["\(table).\(name).default_tools_approval_mode"] = "writes"
                if table == "apps" { fence["apps.\(name).destructive_enabled"] = false }
                for tool in (entry["tools"]?.object ?? [:]).keys {
                    guard isBareKey(tool) else { return nil }
                    fence["\(table).\(name).tools.\(tool).approval_mode"] = "writes"
                }
            }
        }
        return fence
    }

    private static func isBareKey(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}
