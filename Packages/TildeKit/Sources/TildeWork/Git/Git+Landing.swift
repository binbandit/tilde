import Foundation
import TildeSupport

extension Git {
    public struct LandFailure: Error, CustomStringConvertible {
        public var description: String
        public init(description: String) { self.description = description }
    }

    /// Brings a worktree job home: commit stragglers, rebase onto the checkout's
    /// current branch, then fast-forward the checkout. Never merges into a dirty tree.
    public static func land(_ job: Job) async throws {
        guard let branch = job.branch else { throw LandFailure(description: "This job worked in place; there's nothing to land.") }
        let workerBranch = try await currentBranch(job.workdir)
        guard workerBranch == branch else {
            throw LandFailure(description: "The job's worktree is on \(workerBranch), but its recorded branch is \(branch). Put the work back on \(branch) before bringing it in.")
        }
        let repo = job.repoPath
        let target = try await currentBranch(repo)
        guard target != "HEAD" else {
            throw LandFailure(description: "\(job.projectName) is on a detached HEAD. Check out a branch first.")
        }
        guard try await !isDirty(repo) else {
            throw LandFailure(description: "\(job.projectName) has uncommitted changes on \(target). Commit or stash them first.")
        }

        let newFiles = try await untracked(job.workdir)
        if try await isDirty(job.workdir) || !newFiles.isEmpty {
            try await Shell.check(["git", "add", "-A"], cwd: job.workdir)
            try await Shell.check(["git", "commit", "-m", job.title], cwd: job.workdir)
        }

        let rebase = try await Shell.run(["git", "rebase", target], cwd: job.workdir)
        if !rebase.ok {
            _ = try? await Shell.run(["git", "rebase", "--abort"], cwd: job.workdir)
            throw LandFailure(description: "\(branch) conflicts with \(target). Ask the worker to rebase and resolve them.")
        }
        try await Shell.check(["git", "merge", "--ff-only", branch], cwd: repo)
    }
}
