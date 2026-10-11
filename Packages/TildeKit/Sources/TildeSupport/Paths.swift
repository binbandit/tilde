import Foundation

/// Path containment that sees through `~` and symlinks, for deciding what lies inside a worktree.
public enum Paths {
    /// Whether `path` is `dir` itself or somewhere under it.
    public static func isInside(_ path: String, _ dir: String) -> Bool {
        let file = canonical(path), root = canonical(dir)
        return file == root || file.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Resolves symlinks (/tmp vs /private/tmp) even for paths that don't exist yet. One component at a time,
    /// so a link is followed to where it points before a `..` after it climbs from there (collapsing `..`
    /// as text first would put `worktree/link/../x` inside the worktree when it lands wherever `link` goes).
    private static func canonical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        var resolved = "/"
        for component in absolute.split(separator: "/").map(String.init) {
            switch component {
            case ".": continue
            case "..": resolved = (resolved as NSString).deletingLastPathComponent
            default:
                let next = (resolved as NSString).appendingPathComponent(component)
                resolved = FileManager.default.fileExists(atPath: next) ? URL(fileURLWithPath: next).resolvingSymlinksInPath().path : next
            }
        }
        return resolved
    }
}
