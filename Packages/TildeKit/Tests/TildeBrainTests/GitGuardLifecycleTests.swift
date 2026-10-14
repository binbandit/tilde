import Foundation
import Harnesses
import Testing
import TildeMemory
import TildeSupport
import TildeWork
import WorkerKit
@testable import TildeBrain

/// Changes the repo's git config as it starts, the way a worker that tampers with its git setup would.
private actor GuardAuditWorker: Worker {
    struct StartFailure: Error {}
    nonisolated let events: AsyncStream<WorkerEvent>
    private let emit: AsyncStream<WorkerEvent>.Continuation
    let config: URL
    let failStart: Bool
    let gateStop: Bool
    private(set) var stopped = false
    private(set) var starts = 0
    private(set) var configurationAtStart: String?
    private var stopGate: CheckedContinuation<Void, Never>?

    init(config: URL, failStart: Bool = false, gateStop: Bool = false) {
        self.config = config
        self.failStart = failStart
        self.gateStop = gateStop
        (events, emit) = AsyncStream.makeStream()
    }
    func start(brief: String, submission: UUID?) async throws {
        starts += 1
        configurationAtStart = try String(contentsOf: config, encoding: .utf8)
        if let submission { emit.yield(.submitted(submission)) }
        // Inert text only. The tests never run status, hooks, or other code-producing git operations.
        try "[core]\n\tfsmonitor = changed-inert-value\n".write(to: config, atomically: true, encoding: .utf8)
        if failStart { throw StartFailure() }
    }
    func steer(_ text: String, submission: UUID?) async throws {
        if let submission { emit.yield(.submitted(submission)) }
    }
    func resolve(_ requestID: String, _ answer: WorkerAnswer) {}
    func stop() async {
        stopped = true
        if gateStop { await withCheckedContinuation { stopGate = $0 } }
    }
    func releaseStop() { stopGate?.resume(); stopGate = nil }
    func exit() { emit.yield(.exited("Expected fixture exit")) }
    func endTurn() { emit.yield(.turnEnded(ok: true, text: "Fixture completed")) }
}

@MainActor
@Suite(.serialized) struct GitGuardLifecycleTests {
    /// A worktree job on a repo that's only a git directory, with just enough in it for git to see one.
    @MainActor private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "tilde-guard-lifecycle-\(UUID().uuidString)")
        let config: URL
        let original = "[core]\n\tfsmonitor = original-inert-value\n"
        let conductor: Conductor
        let worker: GuardAuditWorker
        let job: Job
        let options: Conductor.Config

        init(failStart: Bool = false, gateStop: Bool = false) throws {
            let git = root.appending(path: "repo/.git")
            let workdir = root.appending(path: "workdir")
            for folder in ["hooks", "objects", "refs"] {
                try FileManager.default.createDirectory(at: git.appending(path: folder), withIntermediateDirectories: true)
            }
            try "ref: refs/heads/main\n".write(to: git.appending(path: "HEAD"), atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
            config = git.appending(path: "config")
            try original.write(to: config, atomically: true, encoding: .utf8)
            let worker = GuardAuditWorker(config: config, failStart: failStart, gateStop: gateStop)
            self.worker = worker
            let harness = Harness(rawValue: "guard-audit-\(UUID().uuidString)")
            HarnessCatalog.register(HarnessSpec(id: harness, label: "Guard audit", executable: "/usr/bin/false", strengths: "Fixture", resumeCommand: { _ in "/usr/bin/false" }) { _ in worker })
            var options = Conductor.Config()
            options.initiative = false
            options.projectRoots = []
            options.manager.executable = "/usr/bin/false"
            options.scribe.executable = "/usr/bin/false"
            options.dream.executable = "/usr/bin/false"
            self.options = options
            conductor = try Conductor(home: TildeHome(root: root.appending(path: "home")), config: options)
            job = Job(id: "j-audit", title: "Fixture", brief: "", projectName: "fixture", repoPath: root.appending(path: "repo").path,
                      workdir: workdir.path, harness: harness, isolation: .worktree)
            conductor.addJob(job)
        }

        func start() async throws { try await conductor.deliver("Fixture", to: job.id, from: .tilde) }
        func configText() throws -> String { try String(contentsOf: config, encoding: .utf8) }

        /// Swaps the config for a link to `target`: a guard can't rebuild it, and mustn't write through it.
        func linkConfig(to target: URL) throws {
            try FileManager.default.removeItem(at: config)
            try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)
        }

        func fixConfig() throws {
            try FileManager.default.removeItem(at: config)
            try original.write(to: config, atomically: true, encoding: .utf8)
        }
    }

    @Test func stopPutsBackWhatTheWorkerChanged() async throws {
        let f = try Fixture()
        try await f.start()
        #expect(try f.configText().contains("changed-inert-value"))
        await f.conductor.stop(f.job.id)
        #expect(await f.worker.stopped)
        #expect(try f.configText().contains("original-inert-value"))
    }

    @Test func anExitPutsBackWhatTheWorkerChanged() async throws {
        let f = try Fixture()
        try await f.start()
        await f.worker.exit()
        for _ in 0..<100 where (try? f.configText().contains("original-inert-value")) != true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try f.configText().contains("original-inert-value"))
        #expect(f.conductor.job(f.job.id)?.phase == .failed)
    }

    @Test func aFailedStartStopsItsWorkerAndPutsBackWhatItChanged() async throws {
        let f = try Fixture(failStart: true)
        await #expect(throws: GuardAuditWorker.StartFailure.self) { try await f.start() }
        #expect(await f.worker.stopped)
        #expect(try f.configText().contains("original-inert-value"))
        #expect(f.conductor.job(f.job.id)?.phase == .failed)
    }

    @Test func aSetupThatCantBeGuardedStartsNoWorker() async throws {
        let f = try Fixture()
        let outside = f.root.appending(path: "outside-config")
        try f.original.write(to: outside, atomically: true, encoding: .utf8)
        try f.linkConfig(to: outside)
        await #expect(throws: GitSetupNeedsReview.self) { try await f.start() }
        #expect(await f.worker.starts == 0)
        #expect(f.conductor.job(f.job.id)?.phase == .failed)
        #expect(f.conductor.job(f.job.id)?.ticker == "Git setup needs review")
    }

    @Test func reviewActionsWaitForASafeSetupThenGoAhead() async throws {
        let f = try Fixture()
        try await f.start()
        f.conductor.update(f.job.id) {
            $0.phase = .ready
            $0.diff = DiffStat(files: 1, insertions: 1, deletions: 0)
            $0.baseCommit = "fixture-base"
        }
        let sentinel = f.root.appending(path: "sentinel.txt")
        try "preserve outside content".write(to: sentinel, atomically: true, encoding: .utf8)
        try f.linkConfig(to: sentinel)

        await #expect(throws: GitSetupNeedsReview.self) { try await f.conductor.land(f.job.id) }
        #expect(await f.worker.stopped)
        await #expect(throws: GitSetupNeedsReview.self) { try await f.conductor.discard(f.job.id) }
        // Checked on disk each time, so a restart doesn't forget it...
        let restarted = try Conductor(home: f.conductor.home, config: f.options)
        await #expect(throws: GitSetupNeedsReview.self) { try await restarted.discard(f.job.id) }
        #expect(FileManager.default.fileExists(atPath: f.job.workdir))
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve outside content")

        // ...and once it's sorted out, nothing is stuck.
        try f.fixConfig()
        try await f.conductor.discard(f.job.id)
        #expect(f.conductor.job(f.job.id)?.ticker == "Discarded")
    }

    @Test func aFollowUpWaitsForTheStoppedWorkersSetupToBePutBack() async throws {
        let f = try Fixture(gateStop: true)
        try await f.start()
        let stopping = Task { await f.conductor.stop(f.job.id) }
        for _ in 0..<100 where await !f.worker.stopped { try await Task.sleep(for: .milliseconds(10)) }
        let next = GuardAuditWorker(config: f.config)
        let harness = Harness(rawValue: "guard-next-\(UUID().uuidString)")
        HarnessCatalog.register(HarnessSpec(id: harness, label: "Next fixture", executable: "/usr/bin/false", strengths: "Fixture") { _ in next })
        f.conductor.update(f.job.id) { $0.harness = harness }
        let delivery = Task { try await f.conductor.deliver("Follow-up", to: f.job.id, from: .you) }
        for _ in 0..<10 { await Task.yield() }
        #expect(await next.starts == 0)

        await f.worker.releaseStop()
        await stopping.value
        try await delivery.value
        #expect(await next.configurationAtStart?.contains("original-inert-value") == true)
        await f.conductor.stop(f.job.id)
        #expect(try f.configText().contains("original-inert-value"))
    }

    @Test func aSetupThatCantBePutBackIsntTakenForTheOwnersOwn() async throws {
        let f = try Fixture()
        try await f.start()
        // git's lock left held: the worker's change can't be put back for now.
        let lock = f.config.appendingPathExtension("lock")
        try Data().write(to: lock)
        await f.conductor.stop(f.job.id)
        #expect(try f.configText().contains("changed-inert-value"))
        #expect(f.conductor.job(f.job.id)?.ticker == "Git setup needs review")

        // Once it's free, the next turn first puts back the setup from before the worker, not the one it left.
        try FileManager.default.removeItem(at: lock)
        let next = GuardAuditWorker(config: f.config)
        let harness = Harness(rawValue: "guard-next-\(UUID().uuidString)")
        HarnessCatalog.register(HarnessSpec(id: harness, label: "Next fixture", executable: "/usr/bin/false", strengths: "Fixture") { _ in next })
        f.conductor.update(f.job.id) { $0.harness = harness }
        try await f.conductor.deliver("Carry on", to: f.job.id, from: .you)
        #expect(await next.configurationAtStart?.contains("original-inert-value") == true)
        await f.conductor.stop(f.job.id)
    }

    @Test func aTurnThatLeavesAnUnsafeSetupFailsAndCantBeSignedOff() async throws {
        let f = try Fixture()
        try await f.start()
        let replacement = f.root.appending(path: "replacement")
        try f.original.write(to: replacement, atomically: true, encoding: .utf8)
        try f.linkConfig(to: replacement)
        await f.worker.endTurn()
        for _ in 0..<100 where f.conductor.job(f.job.id)?.phase != .failed { try await Task.sleep(for: .milliseconds(10)) }
        #expect(f.conductor.job(f.job.id)?.phase == .failed)
        #expect(f.conductor.job(f.job.id)?.ticker == "Git setup needs review")
        #expect(await f.worker.stopped)
        #expect(f.conductor.job(f.job.id)?.lastTurn == .failed)
        #expect(await f.conductor.makeTools().call("finish", ["job": .string(f.job.id), "summary": "Done"]).isError)
    }
}
