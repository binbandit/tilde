import Foundation
import Harnesses
import TildeWork

/// tilde's own jobs: stuck, or done and forgotten.
enum JobWatch {
    static func notices(_ jobs: [Job]) -> [Notice] {
        jobs.compactMap { job in
            let idle = Date.now.timeIntervalSince(job.updatedAt)
            if job.phase == .working, idle > 15 * 60 {
                return Notice(
                    key: "job:\(job.id):stuck:\(Int(job.updatedAt.timeIntervalSince1970))", subject: "job:\(job.id)", urgency: .soon,
                    summary: "\(job.title) (\(job.harness.label)) hasn't made progress in \(Int(idle / 60)) minutes. Last: \(job.ticker).",
                    project: job.repoPath, suggestion: "check on it, nudge it, or move it to another harness")
            }
            if job.phase == .ready, idle > 2 * 3600 {
                return Notice(
                    key: "job:\(job.id):unreviewed", subject: "job:\(job.id)", urgency: .fyi,
                    summary: "\(job.title) in \(job.projectName) has been ready for review for \(Int(idle / 3600))h.",
                    project: job.repoPath, suggestion: "remind them, or land/discard it if they've said so before")
            }
            return nil
        }
    }
}
