import Foundation
import TildeSupport

extension Git {
    /// Creates `path` as a new worktree of `repo` on a fresh `branch` from the checkout's HEAD.
    /// Returns the base branch and commit the job started from.
    public static func addWorktree(repo: String, path: String, branch: String) async throws -> (base: String, commit: String) {
        let base = try await currentBranch(repo)
        let commit = try await head(repo)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try await Shell.check(["git", "worktree", "add", "-b", branch, path, commit], cwd: repo)
        return (base, commit)
    }

    /// A branch name under `tilde/` that doesn't exist yet.
    public static func freeBranch(repo: String, slug: String) async -> String {
        var candidate = "tilde/\(slug)"
        var n = 2
        while (try? await Shell.check(["git", "rev-parse", "--verify", "--quiet", "refs/heads/\(candidate)"], cwd: repo)) != nil {
            candidate = "tilde/\(slug)-\(n)"
            n += 1
        }
        return candidate
    }

    /// Removes a job's worktree and, if `deleteBranch`, its branch.
    public static func removeWorktree(_ job: Job, deleteBranch: Bool) async {
        guard job.isolation == .worktree else { return }
        _ = try? await Shell.run(["git", "worktree", "remove", "--force", job.workdir], cwd: job.repoPath)
        if deleteBranch, let branch = job.branch {
            _ = try? await Shell.run(["git", "branch", "-D", branch], cwd: job.repoPath)
        }
    }
}
