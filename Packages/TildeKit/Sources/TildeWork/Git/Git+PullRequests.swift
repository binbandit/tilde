import Foundation
import TildeSupport

extension Git {
    /// The newest pull request whose head is the job's branch, via the GitHub CLI.
    public static func pullRequest(for job: Job) async -> PullRequest? {
        guard job.isolation != .scratch else { return nil }
        var branch = job.branch
        if branch == nil, let current = try? await currentBranch(job.repoPath), current != "HEAD" { branch = current }
        guard let branch else { return nil }
        guard let output = try? await Shell.check(
            ["gh", "pr", "list", "--head", branch, "--state", "all", "--limit", "1", "--json", "number,url,title,state"],
            cwd: job.repoPath),
            let data = output.data(using: .utf8)
        else { return nil }
        return (try? JSONDecoder().decode([PullRequest].self, from: data))?.first
    }
}
