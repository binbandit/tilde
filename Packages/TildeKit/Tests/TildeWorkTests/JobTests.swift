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
}
