import Foundation
import TildeSupport
import TildeWork

/// What the owner can do with a job from review: read its diff, land it, discard it,
/// find its pull request, mark it done, or take it over in a terminal.
extension Conductor {
    public func diff(_ jobID: String) async -> String {
        guard let job = jobs.first(where: { $0.id == jobID }), let base = job.baseCommit else { return "" }
        return await Git.diff(workdir: job.workdir, base: base)
    }

    /// Brings the job's branch into the checkout.
    public func land(_ jobID: String) async throws {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        guard job.reviewAction == .bringIn, let base = job.baseCommit else {
            throw Git.LandFailure(description: "This job has no verified changes ready to bring in.")
        }
        guard try await !Git.checkedDiffStat(workdir: job.workdir, base: base).isEmpty else {
            update(jobID) { $0.diff = DiffStat(files: 0, insertions: 0, deletions: 0); $0.ticker = "Complete" }
            throw Git.LandFailure(description: "There are no changes to bring in. Mark the job Done instead.")
        }
        guard !Task.isCancelled, self.job(jobID)?.reviewAction == .bringIn else { return }
        await stopWorker(jobID)
        try await Git.land(job)
        await Git.removeWorktree(job, deleteBranch: true)
        update(jobID) { $0.phase = .landed; $0.ticker = "Landed"; $0.acknowledgedAt = nil }
        log.append(jobID, "Landed into \(job.projectName)")
        record(jobID, .you, .event, "Brought it into \(job.baseBranch ?? job.projectName)")
        log.journal("Landed \(job.title) in \(job.projectName)")
        await memory.notebook.commitChanges(context: "landed \(jobID)")
        Task { await scribe.reflect(on: "\(Owner.firstName) reviewed and landed the job \"\(job.title)\" in \(job.projectName). Brief: \(job.brief)\nSummary: \(job.summary ?? "")") }
    }

    public func discard(_ jobID: String) async {
        guard let job = jobs.first(where: { $0.id == jobID }), job.canDiscard, ownsWorktree(job) else { return }
        let stopped = await stopWorker(jobID)
        guard workerGenerations[jobID] == stopped, ownsWorktree(job) else { return }
        await Git.removeWorktree(job, deleteBranch: true)
        dropAttention(for: jobID)
        update(jobID) { $0.phase = .stopped; $0.ticker = "Discarded"; $0.acknowledgedAt = nil }
        log.append(jobID, "Discarded by \(Owner.firstName)")
        record(jobID, .you, .event, "Discarded")
        await memory.notebook.commitChanges(context: "discarded \(jobID)")
        Task { await manager.post(.init("<worker-stopped job=\"\(jobID)\">\(Owner.firstName) discarded this job.</worker-stopped>", jobs: [jobID])) }
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

    /// Acknowledges a completed result. A worktree is retained for later inspection or discard.
    public func dismiss(_ jobID: String) async {
        guard let job = job(jobID), job.reviewAction == .acknowledge else { return }
        if job.isolation == .worktree {
            do {
                guard let base = job.baseCommit else { return }
                let diff = try await Git.checkedDiffStat(workdir: job.workdir, base: base)
                guard diff.isEmpty else {
                    update(jobID) { $0.diff = diff; $0.ticker = "Ready for review" }
                    emit(.trouble("\(job.title) now has changes to review."))
                    return
                }
            } catch {
                emit(.trouble("Couldn't verify \(job.title)'s completion: \(error)"))
                return
            }
        }
        guard !Task.isCancelled, self.job(jobID)?.reviewAction == .acknowledge else { return }
        await stopWorker(jobID)
        guard self.job(jobID)?.reviewAction == .acknowledge else { return }
        dropAttention(for: jobID)
        update(jobID) { $0.phase = .landed; $0.ticker = "Done"; $0.acknowledgedAt = .now }
        log.append(jobID, "\(Owner.firstName) marked it done")
        record(jobID, .you, .event, "Marked it done")
        await memory.notebook.commitChanges(context: "\(jobID) done")
    }

    /// Stops the worker so Brayden can resume its session in a terminal.
    public func takeOver(_ jobID: String) async -> (command: String, cwd: String)? {
        guard let job = jobs.first(where: { $0.id == jobID }), let command = job.takeOverCommand else { return nil }
        await stopWorker(jobID)
        dropAttention(for: jobID)
        update(jobID) { $0.phase = .stopped; $0.ticker = "Taken over" }
        log.append(jobID, "\(Owner.firstName) took over in a terminal")
        record(jobID, .you, .event, "Took over in a terminal")
        return (command, job.workdir)
    }
}
