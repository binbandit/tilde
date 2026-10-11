import Foundation
import Harnesses
import TildeSupport
import TildeWork
import WorkerKit

/// Running workers: starting them, relaying what they do to the manager, and
/// carrying decisions back to them.
extension Conductor {
    /// Starts `job`'s worker. `resume` reopens its session instead of starting a new one.
    func spawn(_ job: Job, brief: String, resume: Bool) async throws {
        guard let spec = job.harness.spec else { throw UnknownHarness(harness: job.harness) }
        // A worktree's commits are written to the repo's own git directory.
        let writable = job.isolation == .worktree ? [(job.repoPath as NSString).appendingPathComponent(".git")] : []
        // What in that git directory makes git run code is noted now, and put back if a turn changes it.
        if let git = writable.first { gitGuards[job.id] = GitGuard.snapshot(gitDirectory: git) }
        let place: Supervision.Place =
            switch job.isolation {
            case .worktree: .worktree
            case .inPlace: .checkout
            case .scratch: .scratch
            }
        let worker = spec.make(WorkerLaunch(
            workdir: job.workdir, sessionID: job.sessionID, resume: resume, model: job.model,
            instructions: Supervision.brief(owner: Owner.firstName, place: place), writable: writable))
        workers[job.id] = worker
        Task { [weak self] in
            for await event in worker.events { self?.handle(event, from: job.id) }
        }
        try await worker.start(brief: brief)
    }

    func stopWorker(_ id: String) async { await workers.removeValue(forKey: id)?.stop() }

    private func handle(_ event: WorkerEvent, from jobID: String) {
        switch event {
        case .session(let id):
            update(jobID) { $0.sessionID = id }
        case .activity(let text):
            record(jobID, .agent, .step, text)
            update(jobID) {
                $0.ticker = text
                if $0.phase == .starting { $0.phase = .working }
            }
        case .message(let text):
            record(jobID, .agent, .message, text)
            // While it works, its latest words; once tilde signs it off, that sign-off stays.
            update(jobID) { if !$0.phase.isOpen || $0.phase.isActive { $0.summary = text } }
        case .notice(let text):
            record(jobID, .agent, .event, text)
            update(jobID) { $0.ticker = text }
        case .request(let request):
            record(jobID, .agent, .request, request.headline)
            requests[request.id] = (jobID, request)
            update(jobID) { $0.phase = .deciding }
            let standing = { if case .permission(_, _, .some) = request.kind { true } else { false } }() && unallowedRail(request, job: jobID) == nil
            Task { await manager.post(.init(Self.describe(request, job: jobID, standing: standing), jobs: [jobID])) }
        case .turnEnded(let ok, let text):
            guard let job = jobs.first(where: { $0.id == jobID }), job.phase.isActive else { return }
            let tampered = gitGuards[jobID]?.restore(gitDirectory: (job.repoPath as NSString).appendingPathComponent(".git")) ?? []
            if !tampered.isEmpty {
                let what = "The agent changed the repo's \(tampered.joined(separator: ", ")), which make git run code; tilde put them back."
                Log.info("guard", "\(jobID): \(what)")
                record(jobID, .tilde, .event, what)
                emit(.said("\(job.title): \(what)", jobID: jobID))
            }
            Task {
                var diff: DiffStat?
                if let base = job.baseCommit { diff = await Git.diffStat(workdir: job.workdir, base: base) }
                record(jobID, .agent, .turnEnded, diff?.label ?? "")
                update(jobID) {
                    $0.diff = diff
                    $0.phase = .deciding
                    $0.ticker = "Reviewing the work"
                }
                await refreshPullRequest(jobID)
                await manager.post(.init("""
                    <worker-finished job="\(jobID)" ok="\(ok)" workdir="\(job.workdir)" changes="\(diff?.label ?? "unknown")">
                    \(text.clipped(to: 6_000, keepLines: true))
                    </worker-finished>
                    """, jobs: [jobID]))
            }
        case .exited(let detail):
            workers.removeValue(forKey: jobID)
            guard let job = jobs.first(where: { $0.id == jobID }), job.phase.isActive else { return }
            update(jobID) {
                $0.phase = detail == nil ? .stopped : .failed
                $0.ticker = detail.map { $0.clipped(to: 80) } ?? "Stopped"
            }
            record(jobID, .agent, .event, detail ?? "Exited")
            for (id, pending) in requests where pending.job == jobID { requests.removeValue(forKey: id) }
            Task {
                await manager.post(.init(
                    "<worker-stopped job=\"\(jobID)\">\(detail ?? "The worker exited.")</worker-stopped>", jobs: [jobID]))
            }
        }
    }

    /// Answers a worker's open request and logs the decision on its job.
    func resolve(_ requestID: String, _ answer: WorkerAnswer, by decider: JobEntry.Speaker) {
        guard let pending = requests.removeValue(forKey: requestID), let worker = workers[pending.job] else { return }
        Task { await worker.resolve(requestID, answer) }
        update(pending.job) { if [.deciding, .needsYou].contains($0.phase) { $0.phase = .working } }
        let verdict =
            switch answer {
            case .allow: "allowed"
            case .deny(let why): "denied (\(why))"
            case .reply(let text): "answered: \(text)"
            }
        log.append(pending.job, "\(pending.request.headline): \(verdict)")
        record(pending.job, decider, .decision, verdict)
    }

    /// `standing`: the owner has said Always to this request's rail in its project.
    nonisolated static func describe(_ request: WorkerRequest, job: String, standing: Bool = false) -> String {
        switch request.kind {
        case .permission(let tool, let action, let rail):
            return """
                <worker-request job="\(job)" request="\(request.id)" tool="\(tool)"\(rail.map { " rail=\"\(escape($0))\"" } ?? "")\(standing ? " owner-allows=\"always\"" : "")>
                \(action.clipped(to: 2_000, keepLines: true))
                </worker-request>
                """
        case .question(let questions):
            let body = questions.map { q in
                "Q: \(q.question)" + (q.options.isEmpty ? "" : "\nOptions: \(q.options.joined(separator: " | "))")
            }.joined(separator: "\n")
            return "<worker-question job=\"\(job)\" request=\"\(request.id)\">\n\(body)\n</worker-question>"
        }
    }
}

/// A job whose harness isn't in the catalog (uninstalled since, or from a newer build).
struct UnknownHarness: Error, CustomStringConvertible {
    var harness: Harness
    var description: String { "Unknown harness \(harness)" }
}
