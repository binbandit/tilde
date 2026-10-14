import Foundation
import TildeSupport
import TildeWork

/// What the owner can do with a job from review: read its diff, land it, discard it,
/// find its pull request, mark it done, or take it over in a terminal.
///
/// Each action waits its turn in the job's queue, stops a worker that's still up, and checks the repo's
/// git setup before git runs there.
extension Conductor {
    public func diff(_ jobID: String) async -> String {
        guard let job = jobs.first(where: { $0.id == jobID }), let base = job.baseCommit else { return "" }
        return await Git.diff(workdir: job.workdir, base: base)
    }

    /// Brings the job's branch into the checkout.
    public func land(_ jobID: String) async throws {
        try await enqueue(jobID) { [self] in
            guard let job = job(jobID), job.reviewAction == .bringIn, let base = job.baseCommit else {
                throw ActionRefused(description: "This job has no verified changes ready to bring in.")
            }
            await retire(jobID)?.stop()
            try await secureGitSetup(job)
            guard try await !Git.diffStat(workdir: job.workdir, base: base).isEmpty else {
                update(jobID) { $0.diff = DiffStat(files: 0, insertions: 0, deletions: 0); $0.ticker = "Complete" }
                throw ActionRefused(description: "There are no changes to bring in. Mark the job Done instead.")
            }
            try await Git.land(job)
            await Git.removeWorktree(job, deleteBranch: true)
            update(jobID) { $0.phase = .landed; $0.ticker = "Landed" }
            log.append(jobID, "Landed into \(job.projectName)")
            record(jobID, .you, .event, "Brought it into \(job.baseBranch ?? job.projectName)")
            log.journal("Landed \(job.title) in \(job.projectName)")
            await memory.notebook.commitChanges(context: "landed \(jobID)")
            Task { await scribe.reflect(on: "\(Owner.firstName) reviewed and landed the job \"\(job.title)\" in \(job.projectName). Brief: \(job.brief)\nSummary: \(job.summary ?? "")") }
        }.value
    }

    /// Removes the job's worktree and branch. Nothing brings them back.
    public func discard(_ jobID: String) async throws {
        try await enqueue(jobID) { [self] in
            guard let job = job(jobID), job.canDiscard, ownsWorktree(job) else { return }
            await retire(jobID)?.stop()
            try await secureGitSetup(job)
            await Git.removeWorktree(job, deleteBranch: true)
            dropAttention(for: jobID)
            update(jobID) { $0.phase = .stopped; $0.ticker = "Discarded" }
            log.append(jobID, "Discarded by \(Owner.firstName)")
            record(jobID, .you, .event, "Discarded")
            await memory.notebook.commitChanges(context: "discarded \(jobID)")
            Task { await manager.post(.init("<worker-stopped job=\"\(jobID)\">\(Owner.firstName) discarded this job.</worker-stopped>", jobs: [jobID])) }
        }.value
    }

    /// Branch names and worktree paths can be reused after removal. An older card never owns
    /// a directory or branch now assigned to a newer job, even if its old path exists again.
    private func ownsWorktree(_ job: Job) -> Bool {
        let workdir = URL(fileURLWithPath: job.workdir).standardizedFileURL.resolvingSymlinksInPath()
        let repo = URL(fileURLWithPath: job.repoPath).standardizedFileURL.resolvingSymlinksInPath()
        return !jobs.contains { other in
            guard other.id != job.id, other.createdAt >= job.createdAt else { return false }
            return URL(fileURLWithPath: other.workdir).standardizedFileURL.resolvingSymlinksInPath() == workdir
                || (job.branch != nil && other.branch == job.branch
                    && URL(fileURLWithPath: other.repoPath).standardizedFileURL.resolvingSymlinksInPath() == repo)
        }
    }

    /// Looks up the job's pull request on GitHub and remembers it.
    @discardableResult
    public func refreshPullRequest(_ jobID: String) async -> PullRequest? {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return nil }
        let pr = await Git.pullRequest(for: job)
        if pr != job.pullRequest { update(jobID) { $0.pullRequest = pr } }
        return pr
    }

    /// Marks a result with nothing to bring in as done. A worktree stays, to look at or discard.
    public func dismiss(_ jobID: String) async throws {
        try await enqueue(jobID) { [self] in
            guard let job = job(jobID), job.reviewAction == .acknowledge else { return }
            await retire(jobID)?.stop()
            if job.isolation == .worktree {
                // Checked again: something may have changed in the worktree since the sign-off.
                guard let base = job.baseCommit else { throw ActionRefused(description: "The job's change baseline is unknown.") }
                try await secureGitSetup(job)
                let diff = try await Git.diffStat(workdir: job.workdir, base: base)
                guard diff.isEmpty else {
                    update(jobID) { $0.diff = diff; $0.ticker = "Ready for review" }
                    throw ActionRefused(description: "\(job.title) has changes now. Bring them in instead.")
                }
            }
            dropAttention(for: jobID)
            update(jobID) { $0.phase = .done; $0.ticker = "Done" }
            log.append(jobID, "\(Owner.firstName) marked it done")
            record(jobID, .you, .event, "Marked it done")
            await memory.notebook.commitChanges(context: "\(jobID) done")
        }.value
    }

    /// Stops the worker so Brayden can resume its session in a terminal.
    public func takeOver(_ jobID: String) async -> (command: String, cwd: String)? {
        guard let job = jobs.first(where: { $0.id == jobID }), let command = job.takeOverCommand else { return nil }
        let stopping = stopWorker(jobID)
        let stops = runs[jobID]?.stops
        let messages = runs[jobID]?.messages
        return try? await enqueue(jobID) { [self] () async throws -> (command: String, cwd: String)? in
            // A newer message or stop wins, even if the message is still waiting in the queue.
            @MainActor func current() -> Bool {
                runs[jobID]?.stops == stops && runs[jobID]?.messages == messages
                    && runs[jobID]?.submission == nil && runs[jobID]?.worker == nil
            }
            guard current() else { return nil }
            let stopped = await stopping.result
            guard current() else { return nil }
            dropAttention(for: jobID)
            guard case .success = stopped else {
                update(jobID) { $0.phase = .stopped }
                return nil
            }
            do {
                // An absent worker doesn't mean a previous repair succeeded. Check again before
                // handing the setup to the owner's terminal, on the same queue as new turns.
                try await secureGitSetup(job)
            } catch {
                guard current() else { return nil }
                update(jobID) { $0.phase = .stopped }
                needsReview(jobID, error)
                return nil
            }
            guard current() else { return nil }
            update(jobID) { $0.phase = .stopped; $0.ticker = "Taken over" }
            log.append(jobID, "\(Owner.firstName) took over in a terminal")
            record(jobID, .you, .event, "Took over in a terminal")
            return (command, job.workdir)
        }.value
    }
}

/// Something asked of a job that doesn't fit where it is.
struct ActionRefused: Error, CustomStringConvertible {
    var description: String
}
