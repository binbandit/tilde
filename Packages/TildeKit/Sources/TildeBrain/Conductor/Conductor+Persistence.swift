import Foundation
import TildeSupport
import TildeWork

/// Jobs and open questions survive a restart in `state/jobs.json`.
extension Conductor {
    private struct Snapshot: Codable {
        var jobs: [Job]
        var attention: [Attention]
    }

    private var snapshotURL: URL { home.state.appending(path: "jobs.json") }

    func persist() {
        let snapshot = Snapshot(jobs: jobs.filter { $0.phase.isOpen || $0.updatedAt > .now.addingTimeInterval(-86_400 * 3) }, attention: attention)
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: snapshotURL, options: .atomic) }
    }

    /// Picks up where tilde left off: its jobs and open questions, before anything can be said or saved.
    /// A file it can't read is set aside rather than overwritten by the next save.
    func restore() {
        guard let data = try? Data(contentsOf: snapshotURL) else { return }
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return setAside(snapshotURL) }
        jobs = snapshot.jobs
        // Questions for workers died with their requests; tilde's own still stand.
        attention = snapshot.attention.filter { $0.requestID == nil }
    }

    /// Workers that were mid-turn pick their sessions back up.
    func resumeActive() {
        for job in jobs where job.phase.isActive {
            // Waiting on a question tilde asked rather than one from its worker: the worker isn't mid-turn, so it stays put.
            if job.phase == .needsYou, attention.contains(where: { $0.jobID == job.id && $0.requestID == nil }) { continue }
            // Its turn was over: the manager (a new thread now) hears how it went again, and decides.
            if job.lastTurn != nil {
                Task { await manager.post(Self.finished(job, text: job.summary ?? "")) }
                continue
            }
            // One that can't be resumed says so on the job.
            handOver("tilde restarted while you were working. Continue where you left off.", to: job.id,
                     resume: true, ticker: "Resuming after a restart")
        }
    }

    /// Moves an unreadable state file out of the way, keeping it for a person (or a newer tilde) to read.
    func setAside(_ url: URL) {
        let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date.now.timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: url, to: aside)
        Log.info("state", "couldn't read \(url.lastPathComponent); set it aside as \(aside.lastPathComponent)")
    }
}
