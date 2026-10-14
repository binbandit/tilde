import Foundation
import Harnesses
import TildeSupport
import TildeWork
import WorkerKit

/// What tilde holds for a job beyond what's saved with it: its worker while it has one, the message that
/// worker is on, the git setup the turn is held to, and the queue the job's work waits its turn in.
struct WorkerRun {
    var worker: (any Worker)?
    /// The latest message handed to the worker.
    var submission: Submission?
    /// The repo's git setup as it was when the current turn began, put back when it ends.
    var gitGuard: GitGuard?
    /// Counts stops: a message still waiting in the queue when one comes isn't delivered.
    var stops = 0
    /// The last of the job's work to be queued (see `Conductor.enqueue`).
    var queue: Task<Void, Never>?
    /// The latest stopped worker going, and its git setup being put back (see `Conductor.settle`).
    var settling: Task<Void, any Error>?

    /// A turn's end counts for the message it was handed only once the worker has taken the message (its
    /// send returned) and the message's marker came back on the event stream ahead of the end: an earlier
    /// turn, ending just as the message arrives, can't pass for it.
    struct Submission {
        let id: UUID
        var observed = false
        var accepted = false
        var ended = false
        /// An end that came before the send returned, held until it does.
        var early: (ok: Bool, text: String)?
    }
}

/// Running workers: starting them, relaying what they do to the manager, and
/// carrying decisions back to them.
extension Conductor {
    /// Queues `work` behind everything already queued for the job, so its deliveries, git repairs, sign-off
    /// and review actions never interleave. A worker's events and a stop don't wait here.
    @discardableResult
    func enqueue<T: Sendable>(_ jobID: String, _ work: @escaping @MainActor () async throws -> T) -> Task<T, any Error> {
        let previous = runs[jobID]?.queue
        let task = Task {
            await previous?.value
            return try await work()
        }
        runs[jobID, default: WorkerRun()].queue = Task { _ = await task.result }
        return task
    }

    /// The job's worker no longer speaks for it: its turn and open requests go too, and work begun for it
    /// finds out. Returns the worker, for the caller to stop.
    @discardableResult
    func retire(_ jobID: String) -> (any Worker)? {
        let worker = runs[jobID]?.worker
        runs[jobID]?.worker = nil
        runs[jobID]?.submission = nil
        for (id, pending) in requests where pending.job == jobID { requests.removeValue(forKey: id) }
        // Its questions went with it: nothing you type now should answer a request no one is waiting on.
        for item in attention where item.jobID == jobID && item.requestID != nil { withdraw(item.id, because: "the agent stopped") }
        return worker
    }

    /// Stops a job's agent, and with it any message still waiting to reach it.
    @discardableResult
    func stopWorker(_ jobID: String) -> Task<Void, any Error> {
        runs[jobID, default: WorkerRun()].stops += 1
        return settle(jobID, stopping: retire(jobID))
    }

    /// Stops a retired worker straight away (which also fails a send still on its way to it), then puts back
    /// what its turn changed in the repo's git setup. It doesn't wait for the job's queue; whatever there
    /// is about to run git or start a turn waits for it instead (`secureGitSetup`). A setup that can't be
    /// put back is the owner's to look at, and they're told.
    @discardableResult
    func settle(_ jobID: String, stopping worker: (any Worker)?) -> Task<Void, any Error> {
        let previous = runs[jobID]?.settling
        let settling = Task { [self] in
            await worker?.stop()
            _ = await previous?.result
            // Nothing was running, so nothing has changed since the last repair.
            guard worker != nil else { return }
            do {
                try await restoreGitSetup(jobID)
            } catch {
                needsReview(jobID, error)
                throw error
            }
        }
        runs[jobID, default: WorkerRun()].settling = settling
        return settling
    }

    /// Queues `text` for the job's agent (see `hand`). A stop before its turn in the queue comes means it
    /// isn't delivered.
    @discardableResult
    func handOver(_ text: String, to jobID: String, resume: Bool? = nil, ticker: String) -> Task<Void, any Error> {
        let stops = runs[jobID]?.stops ?? 0
        return enqueue(jobID) { [self] in
            guard runs[jobID]?.stops ?? 0 == stops else { throw DeliveryInterrupted() }
            try await hand(text, to: jobID, resume: resume, ticker: ticker)
        }
    }

    /// From the job's queue: hands `text` to its agent as a new message, starting the agent first if it
    /// isn't running. `resume` picks its session back up (by default, when it has one). A failure leaves
    /// the job failed, without a worker.
    private func hand(_ text: String, to jobID: String, resume: Bool?, ticker: String) async throws {
        guard let job = job(jobID) else { return }
        let submission = UUID()
        runs[jobID, default: WorkerRun()].submission = WorkerRun.Submission(id: submission)
        update(jobID) {
            $0.lastTurn = nil
            $0.phase = .working
            $0.ticker = ticker
        }
        do {
            if let worker = runs[jobID]?.worker {
                // A turn under way stays held to the setup it began with.
                if runs[jobID]?.gitGuard == nil { try await guardGitSetup(job, for: submission) }
                try await worker.steer(text, submission: submission)
            } else {
                try await spawn(job, brief: text, resume: resume ?? (job.sessionID != nil), submission: submission)
            }
        } catch {
            // A stop (or exit) meanwhile has already said where the job is.
            guard runs[jobID]?.submission?.id == submission else { throw error }
            await retire(jobID)?.stop()
            update(jobID) {
                $0.phase = .failed
                $0.ticker = error is GitSetupNeedsReview ? "Git setup needs review" : "Couldn't reach the agent: \(error)".clipped(to: 80)
            }
            do { try await restoreGitSetup(jobID) } catch { needsReview(jobID, error) }
            throw error
        }
        guard runs[jobID]?.submission?.id == submission else { throw DeliveryInterrupted() }
        accept(submission, for: jobID)
    }

    /// Starts `job`'s worker with `brief`.
    private func spawn(_ job: Job, brief: String, resume: Bool, submission: UUID) async throws {
        guard let spec = job.harness.spec else { throw UnknownHarness(harness: job.harness) }
        try await guardGitSetup(job, for: submission)
        let place: Supervision.Place =
            switch job.isolation {
            case .worktree: .worktree
            case .inPlace: .checkout
            case .scratch: .scratch
            }
        // A worktree's commits are written to the git directory its repo's worktrees share.
        let writable = job.isolation == .worktree ? [try await Git.commonDirectory(job.repoPath)] : []
        // A stop during that lookup may have retired the submission before a worker existed to stop.
        guard runs[job.id]?.submission?.id == submission else { throw DeliveryInterrupted() }
        let worker = spec.make(WorkerLaunch(
            workdir: job.workdir, sessionID: job.sessionID, resume: resume, model: job.model,
            instructions: Supervision.brief(owner: Owner.firstName, place: place), writable: writable))
        runs[job.id]?.worker = worker
        Task { [weak self] in
            for await event in worker.events {
                // A worker since stopped or replaced no longer speaks for its job (its late exit mustn't
                // unregister the one that took over).
                guard let self, self.runs[job.id]?.worker === worker else { continue }
                self.handle(event, from: job.id)
            }
        }
        // A new session gets the repo's AGENTS.md with its brief: not every harness reads it on its own.
        let instructions = resume || job.isolation == .scratch ? nil : RepositoryInstructions.tagged(repository: job.repoPath)
        try await worker.start(brief: instructions.map { "\($0)\n\n\(brief)" } ?? brief, submission: submission)
    }

    /// Holds the turn about to start to the repo's git setup as it stands now (the owner's to change
    /// between turns).
    private func guardGitSetup(_ job: Job, for submission: UUID) async throws {
        let snapshot = try await secureGitSetup(job)
        guard runs[job.id]?.submission?.id == submission else { throw DeliveryInterrupted() }
        runs[job.id]?.gitGuard = snapshot
    }

    /// The worker took the message: its turn's end can count now, including one that came first.
    private func accept(_ submission: UUID, for jobID: String) {
        guard runs[jobID]?.submission?.id == submission else { return }
        runs[jobID]?.submission?.accepted = true
        if let early = runs[jobID]?.submission?.early { endTurn(jobID, ok: early.ok, text: early.text) }
    }

    private func handle(_ event: WorkerEvent, from jobID: String) {
        switch event {
        case .submitted(let id):
            if runs[jobID]?.submission?.id == id { runs[jobID]?.submission?.observed = true }
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
                // Signed off already: nothing it asks now is anyone's to decide.
                if let worker = runs[jobID]?.worker { Task { await worker.resolve(request.id, .deny("This job is no longer active.")) } }
                return
            }
            record(jobID, .agent, .request, request.headline)
            requests[request.id] = (jobID, request)
            // A question already waiting on the owner keeps the job theirs.
            let needsOwner = attention.contains { $0.jobID == jobID }
            update(jobID) { $0.phase = needsOwner ? .needsYou : .deciding }
            let standing = { if case .permission(_, _, .some) = request.kind { true } else { false } }() && unallowedRail(request, job: jobID) == nil
            Task { await manager.post(.init(Self.describe(request, job: jobID, standing: standing), jobs: [jobID])) }
        case .turnEnded(let ok, let text):
            guard var submission = runs[jobID]?.submission, submission.observed, !submission.ended else { return }
            guard submission.accepted else {
                submission.early = (ok, text)
                runs[jobID]?.submission = submission
                return
            }
            endTurn(jobID, ok: ok, text: text)
        case .exited(let detail):
            let wasActive = job(jobID)?.phase.isActive == true
            settle(jobID, stopping: retire(jobID))
            guard wasActive else { return }
            update(jobID) {
                $0.phase = detail == nil ? .stopped : .failed
                $0.ticker = detail.map { $0.clipped(to: 80) } ?? "Stopped"
            }
            record(jobID, .agent, .event, detail ?? "Exited")
            Task {
                await manager.post(.init(
                    "<worker-stopped job=\"\(jobID)\">\(detail ?? "The worker exited.")</worker-stopped>", jobs: [jobID]))
            }
        }
    }

    /// The worker is done with the message it was handed. After whatever is already queued for the job,
    /// what the turn changed in the repo's git setup is put back, its changes counted, and the manager told.
    private func endTurn(_ jobID: String, ok: Bool, text: String) {
        guard let submission = runs[jobID]?.submission?.id else { return }
        runs[jobID]?.submission?.ended = true
        enqueue(jobID) { [self] in
            // A stop, or a newer message, since then says where the job is now.
            guard runs[jobID]?.submission?.id == submission, let job = job(jobID), job.phase.isActive else { return }
            do {
                try await restoreGitSetup(jobID)
            } catch {
                // What the turn left can't be safely put back: its worker goes, and the owner looks.
                await retire(jobID)?.stop()
                update(jobID) {
                    $0.phase = .failed
                    $0.lastTurn = .failed
                }
                needsReview(jobID, error)
                return
            }
            var diff: DiffStat?
            if let base = job.baseCommit { diff = try? await Git.diffStat(workdir: job.workdir, base: base) }
            guard runs[jobID]?.submission?.id == submission, self.job(jobID)?.phase.isActive == true else { return }
            record(jobID, .agent, .turnEnded, ok ? (diff?.label ?? "changes unknown") : "Turn failed")
            update(jobID) {
                $0.diff = diff
                $0.lastTurn = ok ? .succeeded : .failed
                $0.phase = ok ? .deciding : .failed
                $0.ticker = ok ? "Reviewing the work" : "Worker turn failed"
            }
            Task { await refreshPullRequest(jobID) }
            if let job = self.job(jobID) { await manager.post(Self.finished(job, text: text)) }
        }
    }

    /// Tells the manager how a job's worker ended its turn: what it said, and what changed.
    static func finished(_ job: Job, text: String) -> Manager.Message {
        .init("""
            <worker-finished job="\(job.id)" ok="\(job.lastTurn == .succeeded)" workdir="\(job.workdir)" changes="\(job.diff?.label ?? "unknown")">
            \(untrusted(text.clipped(to: 6_000, keepLines: true)))
            </worker-finished>
            """, jobs: [job.id])
    }

    /// Answers a worker's open request and logs the decision on its job. Returns false, leaving the
    /// request open, when its worker is gone or the answer isn't one it can take: a permission takes allow
    /// or deny, a question an answer, and a rail is the owner's to allow (unless they said Always).
    @discardableResult
    func resolve(_ requestID: String, _ answer: WorkerAnswer, by decider: JobEntry.Speaker) -> Bool {
        guard let pending = requests[requestID], let worker = runs[pending.job]?.worker else { return false }
        switch (pending.request.kind, answer) {
        case (.permission, .reply), (.question, .allow): return false
        case (.permission, .allow) where decider != .you && unallowedRail(pending.request, job: pending.job) != nil: return false
        default: break
        }
        requests.removeValue(forKey: requestID)
        let verdict =
            switch answer {
            case .allow: "allowed"
            case .deny(let why): "denied (\(why))"
            case .reply(let text): "answered: \(text)"
            }
        log.append(pending.job, "\(pending.request.headline): \(verdict) by \(decider == .you ? Owner.firstName : "tilde")")
        record(pending.job, decider, .decision, "\(pending.request.headline): \(verdict)")
        for item in attention where item.requestID == requestID { withdraw(item.id, because: "the request was answered") }
        let needsOwner = attention.contains { $0.jobID == pending.job }
        let deciding = requests.values.contains { $0.job == pending.job }
        update(pending.job) {
            if [.deciding, .needsYou].contains($0.phase) { $0.phase = needsOwner ? .needsYou : deciding ? .deciding : .working }
        }
        Task { await worker.resolve(requestID, answer) }
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

/// A stop got there first.
struct DeliveryInterrupted: Error, CustomStringConvertible {
    var description: String { "The agent was stopped before this reached it." }
}
