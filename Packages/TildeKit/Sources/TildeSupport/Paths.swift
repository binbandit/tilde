import Foundation

/// Path containment that sees through `~` and symlinks, for deciding what lies inside a worktree.
public enum Paths {
    /// Whether `path` is `dir` itself or somewhere under it.
    public static func isInside(_ path: String, _ dir: String) -> Bool {
        let file = canonical(path), root = canonical(dir)
        return file == root || file.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Resolves symlinks (/tmp vs /private/tmp) even for paths that don't exist yet.
    private static func canonical(_ path: String) -> String {
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var trailing: [String] = []
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            trailing.insert(url.lastPathComponent, at: 0)
            url.deleteLastPathComponent()
        }
        var resolved = url.resolvingSymlinksInPath()
        for component in trailing { resolved.append(path: component) }
        return resolved.path
    }
}
