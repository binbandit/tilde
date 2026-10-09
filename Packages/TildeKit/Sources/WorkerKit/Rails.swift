import Foundation
import TildeSupport

/// Hard rails: actions that always reach the manager as an explicit decision,
/// however permissive the worker's own permission mode is. They mark anything
/// that leaves the worktree or can't be undone; the manager then either finds
/// a rule in rules.md that allows it or asks Brayden.
public enum Rails {
    /// Returns why `tool` with `input` crosses a rail, or nil if it doesn't.
    public static func check(tool: String, input: JSON, workdir: String) -> String? {
        switch tool {
        case "Bash":
            if input["dangerouslyDisableSandbox"]?.bool == true { return "Runs outside the sandbox, where it can change anything on this Mac" }
            return input["command"]?.string.flatMap { command(in: $0, workdir: workdir) }
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            guard let path = input["file_path"]?.string ?? input["notebook_path"]?.string else { return nil }
            return Paths.isInside(path, workdir) ? nil : "Writes outside the job's worktree (\(path))"
        default:
            return nil
        }
    }

    private static let outward: [(pattern: String, reason: String)] = [
        (#"\bgit\s+push\b"#, "Pushes to a remote"),
        (#"\bgh\s+(pr|release|repo|issue)\s+(create|merge|close|delete|edit|comment|review)\b"#, "Changes something on GitHub"),
        (#"\bgh\s+api\b.*-X\s*(POST|PUT|PATCH|DELETE)"#, "Changes something on GitHub"),
        (#"\b(npm|pnpm|yarn|bun|cargo|gem|twine|pod)\s+(publish|trunk\s+push)\b"#, "Publishes a package"),
        (#"\b(vercel|netlify|wrangler|firebase|fly|flyctl|heroku|railway)\b.*\b(deploy|publish|--prod)\b"#, "Deploys"),
        (#"\b(kubectl|helm)\s+(apply|delete|install|upgrade|rollout)\b"#, "Changes a cluster"),
        (#"\bterraform\s+(apply|destroy)\b"#, "Changes infrastructure"),
        (#"\bdocker\s+push\b"#, "Pushes an image"),
        (#"\b(aws|gcloud|az)\s"#, "Talks to a cloud account"),
        (#"\bsudo\b"#, "Runs as root"),
        (#"\b(ssh|scp|rsync)\s+\S*@"#, "Reaches another machine"),
        (#"\bxcrun\s+(altool|notarytool)\b"#, "Submits to Apple"),
        (#"(curl|wget)[^|]*\|\s*(sh|bash|zsh)\b"#, "Pipes a download into a shell"),
    ]

    static func command(in command: String, workdir: String) -> String? {
        for rail in outward where command.range(of: rail.pattern, options: .regularExpression) != nil {
            return rail.reason
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
