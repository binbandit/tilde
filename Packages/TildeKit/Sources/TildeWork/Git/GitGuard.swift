import Foundation

/// The parts of a repo's git directory that make git run code: its config (fsmonitor, diff drivers,
/// hooksPath, aliases) and its hooks. A worker in a worktree needs to write objects and refs there,
/// never these, so tilde notes them when a worker starts and puts back anything changed since.
public struct GitGuard: Sendable, Equatable {
    /// Relative path to contents.
    var files: [String: Data]

    static let watched = ["config", "config.worktree", "info/attributes"]

    public static func snapshot(gitDirectory: String) -> GitGuard {
        let root = URL(fileURLWithPath: gitDirectory)
        var files: [String: Data] = [:]
        for path in watched + hooks(in: root) {
            if let data = try? Data(contentsOf: root.appending(path: path)) { files[path] = data }
        }
        return GitGuard(files: files)
    }

    /// Puts the watched files back as they were and removes hooks that weren't there. Returns what had changed.
    @discardableResult
    public func restore(gitDirectory: String) -> [String] {
        let root = URL(fileURLWithPath: gitDirectory)
        var changed: [String] = []
        for path in Set(Self.watched + Self.hooks(in: root) + files.keys).sorted() {
            let url = root.appending(path: path)
            let now = try? Data(contentsOf: url)
            guard now != files[path] else { continue }
            changed.append(path)
            if let before = files[path] {
                try? before.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return changed
    }

    private static func hooks(in root: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "hooks").path)) ?? []
        return names.map { "hooks/\($0)" }
    }
}
