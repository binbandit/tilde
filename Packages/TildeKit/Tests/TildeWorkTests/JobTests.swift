import Foundation
import Testing
import WorkerKit
@testable import TildeWork

@Suite struct JobTests {
    @Test func legacyUnknownDiffNeverOffersLandingOrAcknowledgement() {
        var job = Job(id: "old", title: "Old", brief: "", projectName: "app", repoPath: "/repo", workdir: "/tree",
                      harness: Harness(rawValue: "claude"), isolation: .worktree)
        job.phase = .ready
        #expect(job.reviewAction == .unavailable)
        job.isolation = .scratch
        #expect(job.reviewAction == .acknowledge)
    }

    @Test func onlyADoneJobsWorktreeIsLeftToDiscard() {
        var job = Job(id: "done", title: "Done", brief: "", projectName: "app", repoPath: "/repo", workdir: "/tree",
                      harness: Harness(rawValue: "claude"), isolation: .worktree)
        job.phase = .done
        #expect(job.canDiscard)
        job.isolation = .scratch
        #expect(!job.canDiscard)
        job.phase = .landed
        job.isolation = .worktree
        #expect(!job.canDiscard)
    }

    @Test(arguments: [Job.Isolation.worktree, .inPlace, .scratch])
    func markedLegacyAcknowledgementsDecodeAsDone(_ isolation: Job.Isolation) throws {
        var job = Job(id: "old", title: "Old", brief: "", projectName: "app", repoPath: "/repo", workdir: "/tree",
                      harness: Harness(rawValue: "claude"), isolation: isolation)
        job.phase = .landed
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        json["acknowledgedAt"] = Date.now.timeIntervalSinceReferenceDate
        let decoded = try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.phase == .done)
        #expect(decoded.canDiscard == (isolation == .worktree))
        let persisted = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(persisted["phase"] as? String == "done")
        #expect(persisted["acknowledgedAt"] == nil)
    }

    @Test func unmarkedLegacyLandingsStayLanded() throws {
        var job = Job(id: "landed", title: "Landed", brief: "", projectName: "app", repoPath: "/repo", workdir: "/tree",
                      harness: Harness(rawValue: "claude"), isolation: .worktree)
        job.phase = .landed
        let decoded = try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(job))
        #expect(decoded.phase == .landed)
        #expect(!decoded.canDiscard)
    }
}
