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

    /// Hands words to a job's agent once whatever is already queued for the job is done. One that had
    /// stopped picks its session back up; a stop before then means they aren't delivered.
    func deliver(_ text: String, to jobID: String, from: JobEntry.Speaker) async throws {
        try await handOver(text, to: jobID, ticker: from == .you ? "Working on your message" : "Working on feedback").value
        record(jobID, from, .message, text)
    }

    /// Stops a job's agent where it is. Its work stays, and a message starts it again.
    public func stop(_ jobID: String) async {
        let stopping = stopWorker(jobID)
        dropAttention(for: jobID)
        update(jobID) { $0.phase = .stopped; $0.ticker = "Stopped" }
        record(jobID, .you, .event, "Stopped")
        log.append(jobID, "Stopped by \(Owner.firstName)")
        Task { await manager.post(.init("<worker-stopped job=\"\(jobID)\">\(Owner.firstName) stopped it.</worker-stopped>", jobs: [jobID])) }
        _ = await stopping.result
    }
}
