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

    /// Active workers pick their sessions back up.
    func resumeActive() {
        for job in jobs where job.phase.isActive {
            // Waiting on a question tilde asked rather than one from its worker: the worker isn't mid-turn, so it stays put.
            if job.phase == .needsYou, attention.contains(where: { $0.jobID == job.id && $0.requestID == nil }) { continue }
            update(job.id) { $0.phase = .working; $0.ticker = "Resuming after a restart" }
            Task {
                do {
                    try await spawn(job, brief: "tilde restarted while you were working. Continue where you left off.", resume: true)
                } catch {
                    guard !(error is DeliveryInterrupted) else { return }
                    update(job.id) { $0.phase = .failed; $0.ticker = "Couldn't resume: \(error)" }
                }
            }
        }
    }

    /// Moves an unreadable state file out of the way, keeping it for a person (or a newer tilde) to read.
    func setAside(_ url: URL) {
        let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date.now.timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: url, to: aside)
        Log.info("state", "couldn't read \(url.lastPathComponent); set it aside as \(aside.lastPathComponent)")
    }
}
