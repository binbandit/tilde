import Foundation
import TildeSupport

/// Hard rails: actions that always reach a person as an explicit decision, however
/// permissive the worker's own permission mode is. They mark anything that leaves the
/// worktree or can't be undone. A rail is only ever one of tilde's own labels, never a
/// worker's account of itself, and only the owner can allow it (the conductor enforces
/// that: the manager can deny one, or ask, but not allow it).
public enum Rails {
    /// Running a command with the sandbox off.
    public static let outsideSandbox = "Runs outside the sandbox, where it can change anything on this Mac"

    /// Rails too broad to allow for good: "always" to any one of them would cover anything at all.
    public static let neverStanding: Set<String> = [
        outsideSandbox, "Steps outside the job's sandbox", "Writes outside the job's worktree",
    ]

    /// Returns why `tool` with `input` crosses a rail, or nil if it doesn't.
    public static func check(tool: String, input: JSON, workdir: String) -> String? {
        switch tool {
        case "Bash":
            // What the command does comes first: a push run outside the sandbox is a push, not just "outside".
            if let rail = input["command"]?.string.flatMap({ command(in: $0, workdir: workdir) }) { return rail }
            return input["dangerouslyDisableSandbox"]?.bool == true ? outsideSandbox : nil
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            guard let path = input["file_path"]?.string ?? input["notebook_path"]?.string else { return nil }
            return Paths.isInside(path, workdir) ? nil : "Writes outside the job's worktree (\(path))"
        default:
            return nil
        }
    }

    private static let outward: [(pattern: String, reason: String)] = [
        // Options can sit between git and its command (git -c x=y push, git -C dir push).
        (#"\bgit(\s+(-c|-C)\s+\S+|\s+--[a-z-]+(=\S+)?)*\s+push\b"#, "Pushes to a remote"),
        // Kite publishes, opens PRs, and may force-push when it undoes a published land.
        (#"\bkt\s+(publish|pr|undo)\b"#, "Pushes to a remote"),
        (#"\bkt\s+land\b.*--push\b"#, "Pushes to a remote"),
        (#"\bgh\s+(pr|release|repo|issue)\s+(create|merge|close|delete|edit|comment|review|reopen|upload|fork|ready|update-branch|lock|unlock|sync|archive|unarchive|rename|set-default|transfer|pin|unpin|develop)\b"#, "Changes something on GitHub"),
        (#"\bgh\s+(workflow\s+(run|enable|disable)|run\s+(rerun|cancel|delete)|secret\s+(set|delete)|variable\s+(set|delete)|label\s+(create|edit|delete)|gist\s+(create|edit|delete)|ruleset|cache\s+delete)\b"#, "Changes something on GitHub"),
        // gh api writes with an explicit method, or implicitly by sending fields.
        (#"\bgh\s+api\b.*(-X|--method)[\s=]*(POST|PUT|PATCH|DELETE)"#, "Changes something on GitHub"),
        (#"\bgh\s+api\b.*\s(-f|-F|--field|--raw-field|--input)\b"#, "Changes something on GitHub"),
        (#"\b(npm|pnpm|yarn|bun|cargo|gem|twine|pod)\s+(publish|trunk\s+push)\b"#, "Publishes a package"),
        (#"\b(vercel|netlify|wrangler|firebase|fly|flyctl|heroku|railway)\b.*\b(deploy|publish|--prod)\b"#, "Deploys"),
        (#"\b(kubectl|helm)\s+(apply|delete|install|upgrade|rollout)\b"#, "Changes a cluster"),
        (#"\bterraform\s+(apply|destroy)\b"#, "Changes infrastructure"),
        (#"\bdocker\s+push\b"#, "Pushes an image"),
        (#"\b(aws|gcloud|az)\s"#, "Talks to a cloud account"),
        (#"\bsudo\b"#, "Runs as root"),
        // As the command being run, not a word in a message or a search.
        (#"^\s*(\w+=\S*\s+)*(ssh|scp|sftp)\s"#, "Reaches another machine"),
        (#"^\s*(\w+=\S*\s+)*rsync\b.*\s\S*[A-Za-z0-9_.-]+:"#, "Reaches another machine"),
        (#"\bxcrun\s+(altool|notarytool)\b"#, "Submits to Apple"),
    ]

    static func command(in command: String, workdir: String) -> String? {
        // A download piped into a shell is about the pipe itself.
        if command.range(of: #"(curl|wget)[^|]*\|\s*(sudo\s+)?(sh|bash|zsh)\b"#, options: .regularExpression) != nil {
            return "Pipes a download into a shell"
        }
        // Each command in a chain on its own: `| cut -f 2` isn't a field sent to `gh api`, and a quoted word
        // in a commit message isn't a command.
        for segment in command.components(separatedBy: CharacterSet(charactersIn: ";|&\n")) {
            for rail in outward where segment.range(of: rail.pattern, options: .regularExpression) != nil {
                // A GraphQL query reads; only a mutation (or a body from a file) writes.
                if segment.range(of: #"\bgh\s+api\s+graphql\b"#, options: .regularExpression) != nil,
                    segment.range(of: "mutation", options: .caseInsensitive) == nil, !segment.contains("--input"), !segment.contains("=@")
                {
                    continue
                }
                return rail.reason
            }
        }
        // Recursive deletes of anything outside the worktree.
        if command.range(of: #"\brm\s+(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)"#, options: .regularExpression) != nil {
            let targets = command.split(whereSeparator: \.isWhitespace).map(String.init).filter {
                $0.hasPrefix("/") || $0.hasPrefix("~") || $0.hasPrefix("..") || $0 == "*" || $0 == "."
            }
            if let outside = targets.first(where: { !Paths.isInside($0, workdir) || $0 == "." || $0 == "*" }) {
                return "Recursively deletes \(outside)"
            }
        }
        return nil
    }
}
