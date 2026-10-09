import Foundation
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

    /// Picks up where tilde left off: open jobs come back, active workers resume their sessions.
    func restore() {
        guard let data = try? Data(contentsOf: snapshotURL), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        jobs = snapshot.jobs
        attention = []  // their workers' pending requests died with the old process
        for job in jobs where job.phase.isActive {
            update(job.id) { $0.phase = .working; $0.ticker = "Resuming after a restart" }
            Task {
                do {
                    try await spawn(job, brief: "tilde restarted while you were working. Continue where you left off.", resume: true)
                } catch {
                    update(job.id) { $0.phase = .failed; $0.ticker = "Couldn't resume: \(error)" }
                }
            }
        }
    }
}
