import Foundation
import Harnesses
import TildeSupport
import TildeWork
import WorkerKit

/// Running workers: starting them, relaying what they do to the manager, and
/// carrying decisions back to them.
extension Conductor {
    /// Starts `job`'s worker. `resume` reopens its session instead of starting a new one.
    func spawn(_ job: Job, brief: String, resume: Bool, submission: UUID? = nil) async throws {
        let submission = submission ?? beginSubmission(job.id)
        try await waitForGitSubmission(job.id)
        guard !Task.isCancelled, expectedSubmissions[job.id] == submission else { throw DeliveryInterrupted() }
        let generation = UUID()
        workerGenerations[job.id] = generation
        automaticApprovalJobs.remove(job.id)
        successfulTurns.remove(job.id)
        turnEnded.removeValue(forKey: job.id)
        guard let spec = job.harness.spec else { throw UnknownHarness(harness: job.harness) }
        let brief = try job.isolation == .scratch ? brief
            : RepositoryInstructions.workerBrief(brief, repository: job.repoPath, workdir: job.workdir)
        // A worktree's commits are written to the repo's own git directory.
        let writable = job.isolation == .worktree ? [(job.repoPath as NSString).appendingPathComponent(".git")] : []
        // What in that git directory makes git run code is noted now, and put back if a turn changes it.
        let snapshot = await newGitGuard(for: job)
        guard !Task.isCancelled, workerGenerations[job.id] == generation,
            expectedSubmissions[job.id] == submission else { throw DeliveryInterrupted() }
        try installGitGuard(snapshot, for: job.id)
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
        update(job.id) { $0.phase = .working; $0.ticker = resume ? "Resuming" : "Starting" }
        Task { [weak self] in
            for await event in worker.events {
                // A worker since stopped or replaced no longer speaks for its job (its late exit mustn't
                // unregister the one that took over).
                guard let self, self.workers[job.id].map({ $0 === worker }) ?? false else { continue }
                self.handle(event, from: job.id)
            }
        }
        do {
            try await worker.start(brief: brief, submission: submission)
            guard !Task.isCancelled, workerGenerations[job.id] == generation,
                workers[job.id].map({ $0 === worker }) == true else { throw DeliveryInterrupted() }
            acceptSubmission(submission, for: job.id)
        } catch {
            if workers[job.id].map({ $0 === worker }) == true {
                let stopped = await stopWorker(job.id)
                if workerGenerations[job.id] == stopped, gitGuardFailures[job.id] == nil {
                    update(job.id) { $0.phase = .failed; $0.ticker = "Worker couldn't start" }
                }
            } else {
                await worker.stop()
            }
            throw error
        }
    }

    /// Stops a job's worker; what it was waiting on goes with it.
    @discardableResult
    func stopWorker(_ id: String) async -> UUID {
        let generation = UUID()
        workerGenerations[id] = generation
        expectedSubmissions[id] = nil
        acceptedSubmissions[id] = nil
        pendingCompletions[id] = nil
        automaticApprovalJobs.remove(id)
        successfulTurns.remove(id)
        turnEnded.removeValue(forKey: id)
        for (request, pending) in requests where pending.job == id { requests.removeValue(forKey: request) }
        for item in attention where item.jobID == id && item.requestID != nil { withdraw(item.id, because: "the agent stopped") }
        let worker = workers.removeValue(forKey: id)
        _ = await beginGitCleanup(id, stopping: worker).value
        return generation
    }

    private func handle(_ event: WorkerEvent, from jobID: String) {
        switch event {
        case .submitted(let submission):
            observedSubmissions[jobID] = submission
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
            guard job(jobID)?.phase.isActive == true else {
                if let worker = workers[jobID] { Task { await worker.resolve(request.id, .deny("This job is no longer active.")) } }
                return
            }
            record(jobID, .agent, .request, request.headline)
            requests[request.id] = (jobID, request)
            let needsOwner = attention.contains { $0.jobID == jobID }
            update(jobID) { $0.phase = needsOwner ? .needsYou : .deciding }
            if automaticApprovalReason(request, job: jobID) != nil,
                resolve(request.id, .allow, by: .tilde) { return }
            let standing = { if case .permission(_, _, .some) = request.kind { true } else { false } }() && unallowedRail(request, job: jobID) == nil
            Task { await manager.post(.init(Self.describe(request, job: jobID, standing: standing), jobs: [jobID])) }
        case .turnEnded(let ok, let text):
            automaticApprovalJobs.remove(jobID)
            guard let job = jobs.first(where: { $0.id == jobID }), job.phase.isActive,
                let submission = expectedSubmissions[jobID], observedSubmissions[jobID] == submission else { return }
            guard acceptedSubmissions[jobID] == submission else {
                pendingCompletions[jobID] = (submission, event)
                return
            }
            let ended = Date.now
            turnEnded[jobID] = ended
            successfulTurns.remove(jobID)
            let cleanup = beginGitCleanup(jobID)
            Task {
                guard await cleanup.value, expectedSubmissions[jobID] == submission,
                    acceptedSubmissions[jobID] == submission, self.job(jobID)?.phase.isActive == true,
                    turnEnded[jobID] == ended, (handed[jobID] ?? .distantPast) <= ended else { return }
                var diff: DiffStat?
                if let base = job.baseCommit { diff = try? await Git.diffStat(workdir: job.workdir, base: base) }
                // Stopped (or taken over) while that was being worked out: it stays that way.
                guard expectedSubmissions[jobID] == submission, acceptedSubmissions[jobID] == submission,
                    self.job(jobID)?.phase.isActive == true, turnEnded[jobID] == ended,
                    (handed[jobID] ?? .distantPast) <= ended else { return }
                if ok { successfulTurns.insert(jobID) }
                record(jobID, .agent, .turnEnded, ok ? (diff?.label ?? "changes unknown") : "Turn failed")
                update(jobID) {
                    $0.diff = diff
                    $0.phase = ok ? .deciding : .failed
                    $0.ticker = ok ? "Reviewing the work" : "Worker turn failed"
                }
                await refreshPullRequest(jobID)
                await manager.post(.init("""
                    <worker-finished job="\(jobID)" ok="\(ok)" workdir="\(job.workdir)" changes="\(diff?.label ?? "unknown")">
                    \(Self.untrusted(text.clipped(to: 6_000, keepLines: true)))
                    </worker-finished>
                    """, jobs: [jobID]))
            }
        case .exited(let detail):
            let generation = UUID()
            workerGenerations[jobID] = generation
            expectedSubmissions[jobID] = nil
            acceptedSubmissions[jobID] = nil
            pendingCompletions[jobID] = nil
            automaticApprovalJobs.remove(jobID)
            let worker = workers.removeValue(forKey: jobID)
            for (id, pending) in requests where pending.job == jobID { requests.removeValue(forKey: id) }
            for item in attention where item.jobID == jobID && item.requestID != nil { withdraw(item.id, because: "the agent stopped") }
            let wasActive = job(jobID)?.phase.isActive == true
            let cleanup = beginGitCleanup(jobID, stopping: worker)
            Task {
                guard await cleanup.value, workerGenerations[jobID] == generation else { return }
                guard wasActive else { return }
                update(jobID) {
                    $0.phase = detail == nil ? .stopped : .failed
                    $0.ticker = detail.map { $0.clipped(to: 80) } ?? "Stopped"
                }
                record(jobID, .agent, .event, detail ?? "Exited")
                await manager.post(.init(
                    "<worker-stopped job=\"\(jobID)\">\(detail ?? "The worker exited.")</worker-stopped>", jobs: [jobID]))
            }
        }
    }

    /// Invalidates old completion before any suspended preparation of the next message.
    func beginSubmission(_ jobID: String) -> UUID {
        let submission = UUID()
        automaticApprovalJobs.remove(jobID)
        if job(jobID)?.acknowledgedAt != nil { update(jobID) { $0.acknowledgedAt = nil } }
        expectedSubmissions[jobID] = submission
        acceptedSubmissions[jobID] = nil
        pendingCompletions[jobID] = nil
        successfulTurns.remove(jobID)
        turnEnded[jobID] = nil
        handed[jobID] = .now
        return submission
    }

    /// A completion can arrive before the adapter's send RPC returns. It becomes eligible only
    /// after that submission was accepted, with its marker observed on the same ordered stream.
    func acceptSubmission(_ submission: UUID, for jobID: String) {
        guard expectedSubmissions[jobID] == submission else { return }
        acceptedSubmissions[jobID] = submission
        if let pending = pendingCompletions.removeValue(forKey: jobID), pending.submission == submission {
            handle(pending.event, from: jobID)
        }
    }

    /// Queues an answer to a live worker. Rejected answers leave the request open for its owner.
    @discardableResult
    func resolve(_ requestID: String, _ answer: WorkerAnswer, by decider: JobEntry.Speaker) -> Bool {
        guard let pending = requests[requestID], let worker = workers[pending.job], job(pending.job)?.phase.isActive == true else { return false }
        var policyReason: String?
        if case .permission = pending.request.kind {
            // A text answer must never act as an approval through a permissive harness adapter.
            if case .reply = answer { return false }
            if answer.isAllow, decider != .you {
                guard approvalBlock(pending.request, job: pending.job) == nil else { return false }
                policyReason = automaticApprovalReason(pending.request, job: pending.job)
            }
        } else if answer.isAllow { return false }
        requests.removeValue(forKey: requestID)
        let verdict =
            switch answer {
            case .allow: "allowed"
            case .deny(let why): "denied (\(why))"
            case .reply(let text): "answered: \(text)"
            }
        let action = policyReason == nil ? pending.request.headline : "Bash: \(pending.request.permissionContext?.input["command"]?.string ?? pending.request.headline)"
        let decision = "\(requestID): \(action): \(verdict)" + (policyReason.map { " (\($0))" } ?? "")
        Task {
            // Stopping, replacing a worker, or revoking the opt-in before this task runs must not
            // deliver a stale approval or leave an audit entry claiming it was sent.
            guard workers[pending.job].map({ $0 === worker }) == true, job(pending.job)?.phase.isActive == true else { return }
            if answer.isAllow, decider != .you, approvalBlock(pending.request, job: pending.job) != nil {
                requests[requestID] = pending
                let needsOwner = attention.contains { $0.jobID == pending.job }
                update(pending.job) { $0.phase = needsOwner ? .needsYou : .deciding }
                await manager.post(.init(Self.describe(pending.request, job: pending.job), jobs: [pending.job]))
                return
            }
            for item in attention where item.requestID == requestID { withdraw(item.id, because: "the request was answered") }
            let needsOwner = attention.contains { $0.jobID == pending.job }
            let hasRequests = requests.values.contains { $0.job == pending.job }
            update(pending.job) {
                if [.deciding, .needsYou].contains($0.phase) { $0.phase = needsOwner ? .needsYou : hasRequests ? .deciding : .working }
            }
            await worker.resolve(requestID, answer)
            // Delivery has returned. Keep this decision even if that worker exited or was replaced
            // during the actor hop; registration is only a guard against dispatching stale answers.
            log.append(pending.job, "\(decider.rawValue) \(decision)")
            record(pending.job, decider, .decision, decision)
        }
        return true
    }

    /// `standing`: the owner has said Always to this request's rail in its project.
    nonisolated static func describe(_ request: WorkerRequest, job: String, standing: Bool = false) -> String {
        switch request.kind {
        case .permission(let tool, let action, let rail):
            return """
                <worker-request job="\(job)" request="\(request.id)" tool="\(tool)"\(rail.map { " rail=\"\(escape($0))\"" } ?? "")\(standing ? " owner-allows=\"always\"" : "")>
                \(untrusted(action.clipped(to: 2_000, keepLines: true)))
                </worker-request>
                """
        case .question(let questions):
            let body = untrusted(questions.map { q in
                "Q: \(q.question)" + (q.options.isEmpty ? "" : "\nOptions: \(q.options.joined(separator: " | "))")
            }.joined(separator: "\n"))
            return "<worker-question job=\"\(job)\" request=\"\(request.id)\">\n\(body)\n</worker-question>"
        }
    }
}

/// A job whose harness isn't in the catalog (uninstalled since, or from a newer build).
struct UnknownHarness: Error, CustomStringConvertible {
    var harness: Harness
    var description: String { "Unknown harness \(harness)" }
}
