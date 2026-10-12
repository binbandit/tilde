import Foundation
import TildeSupport
import TildeWork
import WorkerKit

/// Same-job barriers keep a new submission from treating an unfinished repair as its baseline.
/// They do not serialize unrelated jobs that share a repository.
extension Conductor {
    struct GitCleanup {
        let id: UUID
        let task: Task<Bool, Never>
    }

    /// Reserve synchronously, before any stop/restore await or event-handler Task can yield.
    @discardableResult
    func beginGitCleanup(_ jobID: String, stopping worker: (any Worker)? = nil) -> Task<Bool, Never> {
        let previous = gitCleanups[jobID]?.task
        let snapshot = gitGuards[jobID]
        let job = job(jobID)
        let token = UUID()
        let task = Task { @MainActor in
            await worker?.stop()
            if let previous { _ = await previous.value }
            var safe = gitGuardFailures[jobID] == nil
            if let snapshot, let job {
                let result = await snapshot.restoreSafely(gitDirectory: (job.repoPath as NSString).appendingPathComponent(".git"))
                safe = result.refused.isEmpty
                if safe {
                    if gitGuards[jobID] == snapshot { gitGuards[jobID] = nil }
                    gitGuardFailures[jobID] = nil
                    if !result.restored.isEmpty {
                        let what = "Restored the job's git setup: \(result.restored.joined(separator: ", "))."
                        Log.info("guard", "\(jobID): \(what)")
                        record(jobID, .tilde, .event, what)
                        emit(.said("\(job.title): \(what)", jobID: jobID))
                    }
                } else {
                    failGitIntegrity(jobID, paths: result.refused)
                    if let active = workers.removeValue(forKey: jobID) {
                        workerGenerations[jobID] = UUID()
                        expectedSubmissions[jobID] = nil
                        acceptedSubmissions[jobID] = nil
                        pendingCompletions[jobID] = nil
                        for (id, pending) in requests where pending.job == jobID { requests.removeValue(forKey: id) }
                        for item in attention where item.jobID == jobID && item.requestID != nil {
                            withdraw(item.id, because: "the job's git setup needs review")
                        }
                        await active.stop()
                    }
                }
            }
            if gitCleanups[jobID]?.id == token { gitCleanups[jobID] = nil }
            return safe
        }
        gitCleanups[jobID] = GitCleanup(id: token, task: task)
        return task
    }

    func waitForGitCleanup(_ jobID: String) async throws {
        while let cleanup = gitCleanups[jobID] { _ = await cleanup.task.value }
        try requireGitIntegrity(jobID)
    }

    func waitForGitSubmission(_ jobID: String) async throws {
        while gitCleanups[jobID] != nil || gitReviews[jobID] != nil {
            if let cleanup = gitCleanups[jobID] { _ = await cleanup.task.value }
            if gitReviews[jobID] != nil {
                await withCheckedContinuation { gitReviews[jobID, default: []].append($0) }
            }
        }
        try requireGitIntegrity(jobID)
    }

    func requireGitIntegrity(_ jobID: String) throws {
        if let paths = gitGuardFailures[jobID] { throw GitIntegrityFailure(paths: paths) }
    }

    /// The caller checks its submission/generation again before installing the returned snapshot.
    func newGitGuard(for job: Job) async -> GitGuard? {
        guard job.isolation == .worktree else { return nil }
        // A mid-turn steer retains the first baseline. Worker edits are never adopted as owner changes.
        if let existing = gitGuards[job.id] { return existing }
        return await GitGuard.snapshot(gitDirectory: (job.repoPath as NSString).appendingPathComponent(".git"))
    }

    /// Install only after the caller rechecks its submission/generation following snapshot's await.
    func installGitGuard(_ snapshot: GitGuard?, for jobID: String) throws {
        if let snapshot, !snapshot.snapshotRefusals.isEmpty {
            failGitIntegrity(jobID, paths: snapshot.snapshotRefusals)
            throw GitIntegrityFailure(paths: snapshot.snapshotRefusals)
        }
        gitGuards[jobID] = snapshot
    }

    private func failGitIntegrity(_ jobID: String, paths: [String]) {
        let first = gitGuardFailures[jobID] != paths
        gitGuardFailures[jobID] = paths
        automaticApprovalJobs.remove(jobID)
        successfulTurns.remove(jobID)
        update(jobID) { $0.phase = .failed; $0.ticker = "Git setup needs review" }
        guard first else { return }
        let message = GitIntegrityFailure(paths: paths).description
        Log.info("guard", "\(jobID): \(message)")
        record(jobID, .tilde, .event, message)
        emit(.trouble("\(job(jobID)?.title ?? jobID): \(message)"))
    }

    /// Review mutations retain a reservation through cleanup and the final git operation.
    func beginGitReview(_ jobID: String) throws {
        guard gitReviews[jobID] == nil else { throw GitReviewInProgress() }
        gitReviews[jobID] = []
    }

    func endGitReview(_ jobID: String) {
        gitReviews.removeValue(forKey: jobID)?.forEach { $0.resume() }
    }
}

struct GitIntegrityFailure: Error, CustomStringConvertible {
    let paths: [String]
    var description: String {
        "Couldn't safely guard the job's git setup (\(paths.joined(separator: ", "))). Work and review actions are paused; the repository metadata needs manual review."
    }
}

private struct GitReviewInProgress: Error, CustomStringConvertible {
    var description: String { "A review action is still finishing for this job." }
}
