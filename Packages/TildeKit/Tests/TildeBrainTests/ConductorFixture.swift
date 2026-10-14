import Foundation
import Harnesses
import Synchronization
import Testing
import TildeSupport
import TildeWork
import WorkerKit
@testable import TildeBrain

/// A conductor over a scratch home and a one-commit repo, with no model behind it.
@MainActor
struct ConductorFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "tilde-conductor-\(UUID().uuidString)")
    var repo: String { root.appending(path: "code/app").path }

    var config: Conductor.Config {
        var config = Conductor.Config()
        config.projectRoots = [root.appending(path: "code").path]
        config.manager.executable = "/usr/bin/false"  // no model in these tests
        config.scribe.executable = "/usr/bin/false"
        config.dream.executable = "/usr/bin/false"
        return config
    }

    /// The repo, and a conductor whose "scripted" harness runs `ScriptedWorker`.
    func makeConductor() async throws -> Conductor {
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let git = ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        try await Shell.check(["git", "init", "-q", "-b", "main"], cwd: repo)
        try "app\n".write(toFile: "\(repo)/README.md", atomically: true, encoding: .utf8)
        try await Shell.check(git + ["add", "."], cwd: repo)
        try await Shell.check(git + ["commit", "-qm", "init"], cwd: repo)

        HarnessCatalog.register(HarnessSpec(id: Harness(rawValue: "scripted"), label: "Scripted", executable: "/bin/sh", strengths: "Tests.") {
            ScriptedWorker(workdir: $0.workdir)
        })
        let conductor = try Conductor(home: TildeHome(root: root.appending(path: "home")), config: config)
        try await conductor.memory.prepare()
        return conductor
    }

    /// The same home, as the next launch of tilde finds it.
    func restart(_ conductor: Conductor) throws -> Conductor { try Conductor(home: conductor.home, config: config) }

    func call(_ conductor: Conductor, _ tool: String, _ args: JSON) async -> ToolResult {
        await conductor.makeTools().call(tool, args)
    }

    func waitFor(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<200 where !(await condition()) { try await Task.sleep(for: .milliseconds(25)) }
        #expect(await condition())
    }

    /// A harness of its own, whose workers `make` makes, recording each launch. Its sessions can be picked
    /// back up, so a worker rests once its work is signed off.
    func harness(_ make: @escaping @Sendable (WorkerLaunch) -> any Worker) -> (Harness, LaunchLog) {
        let id = Harness(rawValue: "fixture-\(UUID().uuidString)")
        let launches = LaunchLog()
        HarnessCatalog.register(HarnessSpec(
            id: id, label: "Fixture", executable: "/bin/sh", strengths: "Tests.", resumeCommand: { _ in "/usr/bin/false" }
        ) { launch in
            launches.record(launch)
            return make(launch)
        })
        return (id, launches)
    }

    /// Delegates work to `worker`: in a worktree of the repo, or else in a scratch folder.
    func delegate(_ conductor: Conductor, to worker: FakeWorker, inRepo: Bool = true) async throws -> Job {
        let (harness, _) = self.harness { _ in worker }
        let started = await call(conductor, "delegate", [
            "title": "Fixture work", "brief": "Fixture only", "harness": .string(harness.rawValue),
            "project_path": inRepo ? .string(repo) : nil,
        ])
        #expect(!started.isError, "\(started.text)")
        return try #require(conductor.jobs.last)
    }

    /// A worktree job whose worker's first turn has just ended well, changing nothing.
    func finishedJob(_ conductor: Conductor, worker: FakeWorker = FakeWorker()) async throws -> Job {
        let job = try await delegate(conductor, to: worker)
        await worker.end()
        try await waitFor { conductor.job(job.id)?.lastTurn == .succeeded }
        return try #require(conductor.job(job.id))
    }
}

/// A worker the test drives: it takes messages (holding them until released, or failing them, when told
/// to), and ends turns or asks on cue.
actor FakeWorker: Worker {
    enum Hold { case beforeMarker, afterMarker }
    struct Failure: Error {}

    nonisolated let events: AsyncStream<WorkerEvent>
    private let emit: AsyncStream<WorkerEvent>.Continuation
    private var failing = false
    /// Everything it was handed: its brief, then each message.
    private(set) var received: [String] = []
    private(set) var answers: [String: WorkerAnswer] = [:]
    private(set) var stopped = false
    private var hold: Hold?
    private var held: [CheckedContinuation<Void, Never>] = []

    init() { (events, emit) = AsyncStream.makeStream() }

    func start(brief: String, submission: UUID?) async throws { try await take(brief, submission) }

    func steer(_ text: String, submission: UUID?) async throws { try await take(text, submission) }

    /// Like a real one, a stop also fails a send still on its way.
    private func take(_ text: String, _ submission: UUID?) async throws {
        received.append(text)
        if hold == .beforeMarker { await withCheckedContinuation { held.append($0) } }
        if let submission { emit.yield(.submitted(submission)) }
        if hold == .afterMarker { await withCheckedContinuation { held.append($0) } }
        if stopped || failing { throw Failure() }
    }

    /// Fails sends from now on, once their marker is out.
    func fail() { failing = true }

    /// Holds the next sends until `release()`, before or after their marker reaches the event stream.
    func hold(_ when: Hold) { hold = when }

    func release() {
        hold = nil
        held.forEach { $0.resume() }
        held = []
    }

    func resolve(_ requestID: String, _ answer: WorkerAnswer) { answers[requestID] = answer }

    func stop() async {
        stopped = true
        release()
    }

    func end(ok: Bool = true) { emit.yield(.turnEnded(ok: ok, text: ok ? "Done" : "Failed")) }
    func ask(_ request: WorkerRequest) { emit.yield(.request(request)) }
    /// Shows on the job's ticker once the conductor has seen everything the worker said before it.
    func notice(_ text: String) { emit.yield(.notice(text)) }
}

/// A scripted worker: writes a file, commits, and finishes. A brief mentioning
/// "push" makes it ask permission to push first.
actor ScriptedWorker: Worker {
    nonisolated let events: AsyncStream<WorkerEvent>
    private let emit: AsyncStream<WorkerEvent>.Continuation
    private let workdir: String
    private var waiting: [String: CheckedContinuation<WorkerAnswer, Never>] = [:]

    init(workdir: String) {
        self.workdir = workdir
        (events, emit) = AsyncStream.makeStream()
    }

    /// Like a real worker, returns as soon as the work is underway.
    func start(brief: String, submission: UUID?) async throws {
        if let submission { emit.yield(.submitted(submission)) }
        Task { try? await self.work(brief) }
    }

    private func work(_ brief: String) async throws {
        emit.yield(.session(id: "scripted-1"))
        emit.yield(.activity("Writing Nav.swift"))
        try "struct Nav {}\n".write(toFile: "\(workdir)/Nav.swift", atomically: true, encoding: .utf8)
        try await Shell.check(["git", "add", "."], cwd: workdir)
        try await Shell.check(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "Add nav"], cwd: workdir)
        if brief.contains("push") {
            _ = await withCheckedContinuation { continuation in
                waiting["r-push"] = continuation
                emit.yield(.request(WorkerRequest(id: "r-push", kind: .permission(tool: "Bash", action: "git push", rail: "Pushes to a remote"))))
            }
        }
        emit.yield(.turnEnded(ok: true, text: "Added Nav.swift."))
    }

    func steer(_ text: String, submission: UUID?) async throws {
        if let submission { emit.yield(.submitted(submission)) }
        emit.yield(.message(text))
    }
    func resolve(_ requestID: String, _ answer: WorkerAnswer) { waiting.removeValue(forKey: requestID)?.resume(returning: answer) }
    func stop() async { emit.finish() }
}

/// Every launch a test harness was asked for.
final class LaunchLog: Sendable {
    private let launches = Mutex<[WorkerLaunch]>([])
    var all: [WorkerLaunch] { launches.withLock { $0 } }
    func record(_ launch: WorkerLaunch) { launches.withLock { $0.append(launch) } }
}
