import Foundation
import Harnesses
import Testing
import TildeSupport
import TildeWork
import WorkerKit
@testable import TildeBrain

@MainActor @Suite(.serialized) struct CompletionTests {
    func readyToFinish(_ fixture: ConductorTests) async throws -> (Conductor, Job) {
        let conductor = try await fixture.makeConductor()
        let workdir = fixture.root.appending(path: "result").path
        let (branch, base) = try await Git.addWorktree(repo: fixture.repo, path: workdir, branch: "tilde/result")
        var job = Job(id: "result", title: "Repository review", brief: "Review only", projectName: "app", repoPath: fixture.repo,
                      workdir: workdir, harness: .claude, isolation: .worktree)
        job.baseBranch = branch
        job.baseCommit = base
        job.branch = "tilde/result"
        job.phase = .deciding
        conductor.addJob(job)
        conductor.log.open(job)
        conductor.turnEnded[job.id] = .now
        conductor.successfulTurns.insert(job.id)
        return (conductor, job)
    }

    @Test func noChangeResultIsAnnouncedAndAcknowledgedWithoutLanding() async throws {
        let fixture = ConductorTests()
        let (conductor, job) = try await readyToFinish(fixture)
        let original = try await Git.head(fixture.repo)
        let finished = await fixture.call(conductor, "finish", ["job": .string(job.id), "summary": "No issues found."])
        #expect(!finished.isError, "\(finished.text)")
        #expect(conductor.job(job.id)?.reviewAction == .acknowledge)
        #expect(conductor.job(job.id)?.ticker == "Complete")
        #expect(conductor.thread.last?.text.contains("No issues found.") == true)
        #expect(conductor.job(job.id)?.digest.contains("awaiting acknowledgement") == true)
        await #expect(throws: Git.LandFailure.self) { try await conductor.land(job.id) }
        await conductor.dismiss(job.id)
        #expect(conductor.job(job.id)?.phase == .landed)
        #expect(conductor.job(job.id)?.ticker == "Done")
        #expect(try await Git.head(fixture.repo) == original)
        #expect(FileManager.default.fileExists(atPath: job.workdir))
        let restored = try Conductor(home: conductor.home, config: fixture.config)
        #expect(restored.job(job.id)?.ticker == "Done")
        #expect(restored.job(job.id)?.canDiscard == true)
        await conductor.discard(job.id)
        #expect(!FileManager.default.fileExists(atPath: job.workdir))
        #expect(conductor.job(job.id)?.ticker == "Discarded")
    }

    @Test func untrackedAndStagedChangesRequireDeliveryReview() async throws {
        let fixture = ConductorTests()
        let (conductor, job) = try await readyToFinish(fixture)
        try "new\n".write(toFile: job.workdir + "/new.txt", atomically: true, encoding: .utf8)
        let finished = await fixture.call(conductor, "finish", ["job": .string(job.id), "summary": "Changed a file."])
        #expect(!finished.isError)
        #expect(conductor.job(job.id)?.reviewAction == .bringIn)
        await conductor.dismiss(job.id)
        #expect(conductor.job(job.id)?.phase == .ready)
        #expect(FileManager.default.fileExists(atPath: job.workdir + "/new.txt"))
    }

    @Test func missingBaselineAndUnreadableWorktreeAreNotNoChangeResults() async throws {
        let fixture = ConductorTests()
        let (conductor, job) = try await readyToFinish(fixture)
        conductor.update(job.id) { $0.baseCommit = "not-a-valid-commit" }
        let result = await fixture.call(conductor, "finish", ["job": .string(job.id), "summary": "Done."])
        #expect(result.isError)
        #expect(conductor.job(job.id)?.phase == .deciding)
        #expect(conductor.job(job.id)?.reviewAction == .unavailable)
        conductor.update(job.id) { $0.baseCommit = nil }
        #expect(await fixture.call(conductor, "finish", ["job": .string(job.id)]).isError)
    }

    @Test func failedStoppedPendingAndSupersededTurnsCannotFinish() async throws {
        let fixture = ConductorTests()
        let (conductor, job) = try await readyToFinish(fixture)
        for phase in [Job.Phase.failed, .stopped, .working] {
            conductor.update(job.id) { $0.phase = phase }
            #expect(await fixture.call(conductor, "finish", ["job": .string(job.id)]).isError)
            #expect(conductor.job(job.id)?.phase == phase)
        }
        conductor.update(job.id) { $0.phase = .deciding }
        conductor.successfulTurns.remove(job.id)
        #expect(await fixture.call(conductor, "finish", ["job": .string(job.id)]).isError)
        conductor.successfulTurns.insert(job.id)
        conductor.handed[job.id] = Date.now.addingTimeInterval(1)
        #expect(await fixture.call(conductor, "finish", ["job": .string(job.id)]).isError)
        conductor.handed[job.id] = nil
        conductor.requests["pending"] = (job.id, WorkerRequest(id: "pending", kind: .permission(tool: "unknown", action: "unknown", rail: nil)))
        #expect(await fixture.call(conductor, "finish", ["job": .string(job.id)]).isError)
    }

    @Test func cancellationDoesNotMarkAJobReady() async throws {
        let fixture = ConductorTests()
        let (conductor, job) = try await readyToFinish(fixture)
        let task = Task { @MainActor in await fixture.call(conductor, "finish", ["job": .string(job.id)]) }
        task.cancel()
        #expect(await task.value.isError)
        #expect(conductor.job(job.id)?.phase == .deciding)
    }

    @Test func changesAfterSignOffPreventAcknowledgement() async throws {
        let fixture = ConductorTests()
        let (conductor, job) = try await readyToFinish(fixture)
        _ = await fixture.call(conductor, "finish", ["job": .string(job.id)])
        try "late change\n".write(toFile: job.workdir + "/late.txt", atomically: true, encoding: .utf8)
        await conductor.dismiss(job.id)
        #expect(conductor.job(job.id)?.phase == .ready)
        #expect(conductor.job(job.id)?.reviewAction == .bringIn)
    }

    @Test func legacyUnknownDiffNeverOffersLandingOrAcknowledgement() {
        var job = Job(id: "old", title: "Old", brief: "", projectName: "app", repoPath: "/repo", workdir: "/tree",
                      harness: .claude, isolation: .worktree)
        job.phase = .ready
        #expect(job.reviewAction == .unavailable)
        job.isolation = .scratch
        #expect(job.reviewAction == .acknowledge)
    }
}

private actor CompletionWorker: Worker {
    nonisolated let events: AsyncStream<WorkerEvent>
    private let emit: AsyncStream<WorkerEvent>.Continuation
    init() { (events, emit) = AsyncStream.makeStream() }
    func start(brief: String) async throws {}
    func steer(_ text: String) async throws {}
    func resolve(_ requestID: String, _ answer: WorkerAnswer) {}
    func stop() async {}
    func end(ok: Bool) { emit.yield(.turnEnded(ok: ok, text: ok ? "Research complete" : "Failed")) }
}

@MainActor @Suite(.serialized) struct CompletionEventTests {
    @Test func failedTurnAndLateCancelledCompletionStayClosed() async throws {
        let fixture = ConductorTests()
        let conductor = try await fixture.makeConductor()
        let worker = CompletionWorker()
        let harness = Harness(rawValue: "completion-events-\(UUID().uuidString)")
        HarnessCatalog.register(HarnessSpec(id: harness, label: "Completion fixture", executable: "/usr/bin/false", strengths: "Tests") { _ in worker })
        let result = await fixture.call(conductor, "delegate", ["title": "Research", "brief": "Fixture only", "harness": .string(harness.rawValue)])
        #expect(!result.isError)
        let job = try #require(conductor.jobs.first)
        await worker.end(ok: false)
        try await fixture.waitFor(conductor) { conductor.job(job.id)?.phase == .failed }
        #expect(await fixture.call(conductor, "finish", ["job": .string(job.id)]).isError)
        await conductor.stop(job.id)
        await worker.end(ok: true)
        for _ in 0..<10 { await Task.yield() }
        #expect(conductor.job(job.id)?.phase == .stopped)
        #expect(conductor.job(job.id)?.reviewAction == .unavailable)
    }
}
