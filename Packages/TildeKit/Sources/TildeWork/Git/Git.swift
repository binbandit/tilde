import Foundation
import TildeSupport

/// The git plumbing behind jobs: worktrees in, diffs out, landing back home.
public enum Git {
    public static func root(of path: String) async throws -> String {
        try await Shell.check(["git", "rev-parse", "--show-toplevel"], cwd: path)
    }

    /// The git directory all of `repo`'s worktrees share, absolute: `.git` in a plain checkout, elsewhere
    /// for a submodule or when `repo` is itself a linked worktree.
    public static func commonDirectory(_ repo: String) async throws -> String {
        try await Shell.check(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: repo)
    }

    public static func currentBranch(_ repo: String) async throws -> String {
        try await Shell.check(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd: repo)
    }

    public static func head(_ repo: String) async throws -> String {
        try await Shell.check(["git", "rev-parse", "HEAD"], cwd: repo)
    }

    /// Tracked changes only; untracked files never block a fast-forward of unrelated paths.
    public static func isDirty(_ repo: String) async throws -> Bool {
        try await !Shell.check(["git", "status", "--porcelain", "--untracked-files=no"], cwd: repo).isEmpty
    }
}
