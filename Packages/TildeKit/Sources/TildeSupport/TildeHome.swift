import Foundation

/// Everything tilde keeps on disk lives under one folder, `~/.tilde` by default.
///
///     notebook/    long-term memory, a git repo of markdown the manager maintains
///     worktrees/   one git worktree per delegated job
///     state/       live state snapshots and activity logs (not memory)
public struct TildeHome: Sendable {
    public let root: URL

    public static let `default` = TildeHome(
        root: ProcessInfo.processInfo.environment["TILDE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".tilde"))

    public init(root: URL) { self.root = root }

    public var notebook: URL { root.appending(path: "notebook") }
    public var worktrees: URL { root.appending(path: "worktrees") }
    public var state: URL { root.appending(path: "state") }
    public var scratch: URL { root.appending(path: "scratch") }

    public func prepare() throws {
        for dir in [root, notebook, worktrees, state] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
