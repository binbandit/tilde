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
        await stopWorker(jobID)
        try await Git.land(job)
        await Git.removeWorktree(job, deleteBranch: true)
        update(jobID) { $0.phase = .landed; $0.ticker = "Landed" }
        log.append(jobID, "Landed into \(job.projectName)")
        record(jobID, .you, .event, "Brought it into \(job.baseBranch ?? job.projectName)")
        log.journal("Landed \(job.title) in \(job.projectName)")
        await memory.notebook.commitChanges(context: "landed \(jobID)")
        Task { await scribe.reflect(on: "\(Owner.firstName) reviewed and landed the job \"\(job.title)\" in \(job.projectName). Brief: \(job.brief)\nSummary: \(job.summary ?? "")") }
    }

    public func discard(_ jobID: String) async {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        await stopWorker(jobID)
        await Git.removeWorktree(job, deleteBranch: true)
        dropAttention(for: jobID)
        update(jobID) { $0.phase = .stopped; $0.ticker = "Discarded" }
        log.append(jobID, "Discarded by \(Owner.firstName)")
        record(jobID, .you, .event, "Discarded")
        await memory.notebook.commitChanges(context: "discarded \(jobID)")
        Task { await manager.post(.init("<worker-stopped job=\"\(jobID)\">\(Owner.firstName) discarded this job.</worker-stopped>", jobs: [jobID])) }
    }

    /// Looks up the job's pull request on GitHub and remembers it.
    @discardableResult
    public func refreshPullRequest(_ jobID: String) async -> PullRequest? {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return nil }
        let pr = await Git.pullRequest(for: job)
        if pr != job.pullRequest { update(jobID) { $0.pullRequest = pr } }
        return pr
    }

    /// Marks a job that has nothing to land (scratch work) as done.
    public func dismiss(_ jobID: String) async {
        await stopWorker(jobID)
        update(jobID) { $0.phase = .landed; $0.ticker = "Done" }
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
