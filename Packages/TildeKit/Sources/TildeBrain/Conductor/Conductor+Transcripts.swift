import Foundation
import TildeSupport
import TildeWork
import WorkerKit

/// Each job's conversation (what its agent was told, said, did and asked, and who answered),
/// and talking to an agent directly from its view.
extension Conductor {
    /// Keeps a job's conversation in `transcripts` from now on, for a view that shows it.
    public func loadTranscript(_ jobID: String) {
        guard transcripts[jobID] == nil, let job = job(jobID) else { return }
        let entries = transcriptStore.load(jobID)
        // Jobs from before conversations were kept still show their brief.
        transcripts[jobID] = entries.isEmpty ? [JobEntry(at: job.createdAt, from: .tilde, kind: .message, text: job.brief)] : entries
    }

    func record(_ jobID: String, _ from: JobEntry.Speaker, _ kind: JobEntry.Kind, _ text: String) {
        let entry = JobEntry(from: from, kind: kind, text: text)
        transcriptStore.append(entry, to: jobID)
        transcripts[jobID]?.append(entry)
    }

    /// Brayden talks to a job's agent directly. tilde hears about it too, so it doesn't contradict him.
    public func message(_ jobID: String, _ text: String) async throws {
        try await deliver(text, to: jobID, from: .you)
        log.append(jobID, "\(Owner.firstName) told the worker: \(text)")
        Task { await manager.post(.init("<owner-message job=\"\(jobID)\">\n\(text)\n</owner-message>", jobs: [jobID])) }
    }

    /// Hands words to a job's agent. One that had stopped picks its session back up.
    func deliver(_ text: String, to jobID: String, from: JobEntry.Speaker) async throws {
        guard let job = job(jobID) else { return }
        guard deliveriesInFlight[jobID] == nil else { throw DeliveryInProgress() }
        deliveriesInFlight[jobID] = 1
        defer { deliveriesInFlight[jobID] = nil }
        let submission = beginSubmission(jobID)
        do {
            if let worker = workers[jobID] {
                // The git setup as it stands now is what this turn is held to.
                if job.isolation == .worktree {
                    gitGuards[jobID] = await GitGuard.snapshot(gitDirectory: (job.repoPath as NSString).appendingPathComponent(".git"))
                }
                let brief = job.isolation == .scratch ? text
                    : try RepositoryInstructions.workerBrief(text, repository: job.repoPath, workdir: job.workdir)
                guard !Task.isCancelled, expectedSubmissions[jobID] == submission,
                    workers[jobID].map({ $0 === worker }) == true else { throw DeliveryInterrupted() }
                update(jobID) {
                    $0.phase = .working
                    $0.ticker = from == .you ? "Working on your message" : "Working on feedback"
                }
                try await worker.steer(brief, submission: submission)
                guard !Task.isCancelled, expectedSubmissions[jobID] == submission,
                    workers[jobID].map({ $0 === worker }) == true else { throw DeliveryInterrupted() }
                acceptSubmission(submission, for: jobID)
            } else {
                try await spawn(job, brief: text, resume: job.sessionID != nil, submission: submission)
            }
            record(jobID, from, .message, text)
        } catch {
            if expectedSubmissions[jobID] == submission {
                let stopped = await stopWorker(jobID)
                if workerGenerations[jobID] == stopped {
                    update(jobID) { $0.phase = .failed; $0.ticker = "Message delivery interrupted" }
                }
            }
            throw error
        }
    }

    /// Stops a job's agent where it is. Its work stays, and a message starts it again.
    public func stop(_ jobID: String) async {
        let stopped = await stopWorker(jobID)
        guard workerGenerations[jobID] == stopped else { return }
        dropAttention(for: jobID)
        update(jobID) { $0.phase = .stopped; $0.ticker = "Stopped" }
        record(jobID, .you, .event, "Stopped")
        log.append(jobID, "Stopped by \(Owner.firstName)")
        Task { await manager.post(.init("<worker-stopped job=\"\(jobID)\">\(Owner.firstName) stopped it.</worker-stopped>", jobs: [jobID])) }
    }
}

struct DeliveryInterrupted: Error, CustomStringConvertible {
    var description: String { "The worker stopped or was replaced while receiving this message. Try again." }
}

private struct DeliveryInProgress: Error, CustomStringConvertible {
    var description: String { "A message is still being delivered to this worker. Try again once it is received." }
}
