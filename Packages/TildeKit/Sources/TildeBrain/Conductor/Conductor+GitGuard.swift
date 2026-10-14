import Foundation
import TildeSupport
import TildeWork

/// A worktree job's worker can write its repo's git directory (its commits go there), and so what makes
/// git run code: config like core.fsmonitor, and hooks. git would run that as the owner, outside the
/// worker's sandbox, the next time anyone uses the repo. So each turn is held to the git setup as it was
/// when the turn began (`WorkerRun.gitGuard`), and what it changed there is put back when it ends.
///
/// This runs on the job's queue, or in a `settle` that queued work waits for: never alongside a turn
/// starting or another repair.
extension Conductor {
    /// Puts back what changed in the repo's git setup since the current turn began. A setup that can't be
    /// put back keeps its snapshot, and every later action tries again against that (throwing until it
    /// can), so nothing a worker left there is ever taken for the owner's own setup.
    func restoreGitSetup(_ jobID: String) async throws {
        // Claimed while it's put back, so nothing else puts it back at the same time.
        guard let snapshot = runs[jobID]?.gitGuard, let job = job(jobID) else { return }
        runs[jobID]?.gitGuard = nil
        let result = await snapshot.restore()
        guard result.refused.isEmpty else {
            if runs[jobID]?.gitGuard == nil { runs[jobID]?.gitGuard = snapshot }
            throw GitSetupNeedsReview(paths: result.refused)
        }
        guard !result.restored.isEmpty else { return }
        let what = "The agent changed \(result.restored.joined(separator: ", ")) in the repo's git setup, which make git run code; tilde put them back."
        Log.info("guard", "\(jobID): \(what)")
        record(jobID, .tilde, .event, what)
        emit(.said("\(job.title): \(what)", jobID: jobID))
    }

    /// Before git runs for a worktree job, or a turn starts there: waits for a stopped worker to be gone,
    /// puts back what it left changed, then checks the setup as it stands, which is what a new turn is held
    /// to. Throws when any of that can't be done safely; once the owner has sorted the repo out, it can.
    @discardableResult
    func secureGitSetup(_ job: Job) async throws -> GitGuard? {
        guard job.isolation == .worktree else { return nil }
        _ = await runs[job.id]?.settling?.result
        try await restoreGitSetup(job.id)
        let snapshot = await GitGuard.snapshot(repository: job.repoPath)
        guard snapshot.snapshotRefusals.isEmpty else { throw GitSetupNeedsReview(paths: snapshot.snapshotRefusals) }
        return snapshot
    }

    /// Tells the owner about a git setup only they can sort out, when no one's waiting on an answer to say so.
    func needsReview(_ jobID: String, _ error: any Error) {
        Log.info("guard", "\(jobID): \(error)")
        record(jobID, .tilde, .event, "\(error)")
        update(jobID) { $0.ticker = "Git setup needs review" }
        emit(.trouble("\(job(jobID)?.title ?? jobID): \(error)"))
    }
}

/// git mustn't run for the job until someone has looked at its repo's git setup.
struct GitSetupNeedsReview: Error, CustomStringConvertible {
    let paths: [String]
    var description: String {
        "The repo's git setup needs a look: tilde couldn't safely check or put back \(paths.joined(separator: ", ")), so it won't run git or an agent there until that's sorted out."
    }
}
