import Foundation
import Harnesses
import Testing
import TildeMemory
import TildeSupport
import TildeWork
import WorkerKit
@testable import TildeBrain

private actor GuardAuditWorker: Worker {
    enum StartFailure: Error { case expected }
    nonisolated let events: AsyncStream<WorkerEvent>
    private let emit: AsyncStream<WorkerEvent>.Continuation
    let config: URL
    let failStart: Bool
    private(set) var stopped = false
    private(set) var starts = 0
    private(set) var configurationAtStart: String?
    private var stopGate: CheckedContinuation<Void, Never>?
    let gateStop: Bool

    init(config: URL, failStart: Bool, gateStop: Bool = false) {
        self.gateStop = gateStop
        self.config = config
        self.failStart = failStart
        (events, emit) = AsyncStream.makeStream()
    }
    func start(brief: String, submission: UUID?) async throws {
        starts += 1
        configurationAtStart = try String(contentsOf: config, encoding: .utf8)
        if let submission { emit.yield(.submitted(submission)) }
        // Inert text only. The tests never run status, hooks, or other code-producing git operations.
        try "[core]\n\tfsmonitor = changed-inert-value\n".write(to: config, atomically: true, encoding: .utf8)
        if failStart { throw StartFailure.expected }
        emit.yield(.activity("Waiting"))
    }
    func steer(_ text: String, submission: UUID?) async throws {
        if let submission { emit.yield(.submitted(submission)) }
    }
    func resolve(_ requestID: String, _ answer: WorkerAnswer) {}
    func stop() async {
        stopped = true
        if gateStop { await withCheckedContinuation { stopGate = $0 } }
        emit.finish()
    }
    func releaseStop() { stopGate?.resume(); stopGate = nil }
    func exit() { emit.yield(.exited("Expected fixture exit")); emit.finish() }
    func endTurn() { emit.yield(.turnEnded(ok: true, text: "Fixture completed")) }
}

@MainActor
@Suite(.serialized) struct GitGuardLifecycleTests {
    @MainActor private struct Fixture {
        let root: URL
        let config: URL
        let conductor: Conductor
        let worker: GuardAuditWorker
        let job: Job
        let original = "[core]\n\tfsmonitor = original-inert-value\n"

        init(failStart: Bool = false, gateStop: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "tilde-guard-lifecycle-\(UUID().uuidString)")
            let repo = root.appending(path: "repo")
            let git = repo.appending(path: ".git")
            let workdir = root.appending(path: "workdir")
            // Just enough for git to see a repository.
            for folder in ["hooks", "objects", "refs"] {
                try FileManager.default.createDirectory(at: git.appending(path: folder), withIntermediateDirectories: true)
            }
            try "ref: refs/heads/main\n".write(to: git.appending(path: "HEAD"), atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
            config = git.appending(path: "config")
            try original.write(to: config, atomically: true, encoding: .utf8)
            worker = GuardAuditWorker(config: config, failStart: failStart, gateStop: gateStop)
            let harness = Harness(rawValue: "guard-audit-\(UUID().uuidString)")
            let worker = worker
            HarnessCatalog.register(HarnessSpec(id: harness, label: "Guard audit", executable: "/usr/bin/false", strengths: "Fixture", resumeCommand: { _ in "/usr/bin/false" }) { _ in worker })
            var options = Conductor.Config()
            options.initiative = false
            options.projectRoots = []
            options.manager.executable = "/usr/bin/false"
            options.scribe.executable = "/usr/bin/false"
            options.dream.executable = "/usr/bin/false"
            conductor = try Conductor(home: TildeHome(root: root.appending(path: "home")), config: options)
            job = Job(id: "j-audit", title: "Fixture", brief: "", projectName: "fixture", repoPath: repo.path,
                      workdir: workdir.path, harness: harness, isolation: .worktree)
            conductor.addJob(job)
        }

        func configText() throws -> String { try String(contentsOf: config, encoding: .utf8) }

        /// Swaps the config for a link to `target`: a guard can't rebuild it and must not write through it.
        func linkConfig(to target: URL) throws {
            try FileManager.default.removeItem(at: config)
            try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)
        }
    }

    @Test func publicStopRestoresGuardedConfiguration() async throws {
        let f = try Fixture()
        try await f.conductor.spawn(f.job, brief: "", resume: false)
        #expect(try f.configText().contains("changed-inert-value"))
        await f.conductor.stop(f.job.id)
        #expect(await f.worker.stopped)
        #expect(try f.configText().contains("original-inert-value"), "Public stop returned while worker changes remain in git config")
    }

    @Test func workerExitRestoresGuardedConfiguration() async throws {
        let f = try Fixture()
        try await f.conductor.spawn(f.job, brief: "", resume: false)
        await f.worker.exit()
        for _ in 0..<100 where f.conductor.job(f.job.id)?.phase != .failed { try await Task.sleep(for: .milliseconds(10)) }
        #expect(f.conductor.workers[f.job.id] == nil)
        #expect(f.conductor.job(f.job.id)?.phase == .failed)
        #expect(try f.configText().contains("original-inert-value"), "Exit handler unregisters worker without restoring its git config")
    }

    @Test func failedStartStopsWorkerAndRestoresGuardedConfiguration() async throws {
        let f = try Fixture(failStart: true)
        do {
            try await f.conductor.spawn(f.job, brief: "", resume: false)
            Issue.record("The fixture must throw during start")
        } catch GuardAuditWorker.StartFailure.expected {}
        #expect(await f.worker.stopped, "Start failure must stop the partially started worker")
        #expect(f.conductor.workers[f.job.id] == nil, "Start failure leaves a stale registered worker")
        #expect(try f.configText().contains("original-inert-value"), "Start failure leaves worker changes in git config")
        await f.conductor.stopWorker(f.job.id)
    }
    @Test func refusesUnsupportedSnapshotBeforeStartingWorker() async throws {
        let f = try Fixture()
        let outside = f.root.appending(path: "outside-config")
        try f.original.write(to: outside, atomically: true, encoding: .utf8)
        try f.linkConfig(to: outside)
        await #expect(throws: (any Error).self) { try await f.conductor.spawn(f.job, brief: "", resume: false) }
        #expect(await f.worker.starts == 0)
        #expect(f.conductor.workers[f.job.id] == nil)
        #expect(f.conductor.job(f.job.id)?.phase == .failed)
    }

    @Test(arguments: ["land", "discard", "takeOver"])
    func refusedRestorationBlocksReviewActions(action: String) async throws {
        let f = try Fixture()
        try await f.conductor.spawn(f.job, brief: "", resume: false)
        f.conductor.update(f.job.id) {
            $0.phase = .ready
            $0.diff = DiffStat(files: 1, insertions: 1, deletions: 0)
            $0.baseCommit = "fixture-base"
            $0.branch = "fixture-branch"
            $0.sessionID = "fixture-session"
        }
        let outside = f.root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appending(path: "sentinel.txt")
        try "preserve outside content".write(to: sentinel, atomically: true, encoding: .utf8)
        try f.linkConfig(to: sentinel)
        switch action {
        case "land":
            await #expect(throws: (any Error).self) { try await f.conductor.land(f.job.id) }
        case "discard": await f.conductor.discard(f.job.id)
        default: #expect(await f.conductor.takeOver(f.job.id) == nil)
        }
        #expect(await f.worker.stopped)
        #expect(f.conductor.job(f.job.id)?.phase == .failed)
        #expect(f.conductor.job(f.job.id)?.ticker == "Git setup needs review")
        #expect(FileManager.default.fileExists(atPath: f.job.workdir))
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve outside content")
        #expect(!f.conductor.transcriptStore.load(f.job.id).contains { $0.text.contains("Restored the job's git setup") })
        #expect(await f.conductor.diff(f.job.id).isEmpty)
        #expect(await f.conductor.refreshPullRequest(f.job.id) == nil)
        await #expect(throws: (any Error).self) { try await f.conductor.deliver("Retry", to: f.job.id, from: .you) }
        #expect(await f.worker.starts == 1)
    }

    @Test func followupWaitsForStoppedWorkerAndItsOriginalBaseline() async throws {
        let f = try Fixture(gateStop: true)
        try await f.conductor.spawn(f.job, brief: "", resume: false)
        let stopping = Task { await f.conductor.stop(f.job.id) }
        for _ in 0..<100 where await !f.worker.stopped { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await f.worker.stopped)
        let next = GuardAuditWorker(config: f.config, failStart: false)
        let harness = Harness(rawValue: "guard-next-\(UUID().uuidString)")
        HarnessCatalog.register(HarnessSpec(id: harness, label: "Next fixture", executable: "/usr/bin/false", strengths: "Fixture") { _ in next })
        f.conductor.update(f.job.id) { $0.harness = harness }
        let delivery = Task { try await f.conductor.deliver("Followup", to: f.job.id, from: .you) }
        for _ in 0..<100 where f.conductor.deliveriesInFlight[f.job.id] == nil { await Task.yield() }
        for _ in 0..<10 { await Task.yield() }
        #expect(await next.starts == 0)
        await f.worker.releaseStop()
        await stopping.value
        try await delivery.value
        #expect(await next.starts == 1)
        #expect(await next.configurationAtStart?.contains("original-inert-value") == true)
        await f.conductor.stop(f.job.id)
        #expect(try f.configText().contains("original-inert-value"))
    }

    @Test func refusedTurnEndCleanupStopsWorkerAndCannotSignOff() async throws {
        let f = try Fixture()
        try await f.conductor.spawn(f.job, brief: "", resume: false)
        let replacement = f.root.appending(path: "replacement")
        try f.original.write(to: replacement, atomically: true, encoding: .utf8)
        try f.linkConfig(to: replacement)
        await f.worker.endTurn()
        for _ in 0..<100 where await !f.worker.stopped { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await f.worker.stopped)
        #expect(f.conductor.workers[f.job.id] == nil)
        #expect(f.conductor.job(f.job.id)?.phase == .failed)
        #expect(!f.conductor.successfulTurns.contains(f.job.id))
        #expect(!f.conductor.transcriptStore.load(f.job.id).contains { $0.text.contains("Restored the job's git setup") })
    }

}
