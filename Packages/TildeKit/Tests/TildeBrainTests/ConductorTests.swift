import Foundation
import Harnesses
import Synchronization
import Testing
import TildeMemory
import TildeSupport
import TildeWork
import WorkerKit
@testable import TildeBrain

/// A scripted worker: writes a file, commits, and finishes. A brief mentioning
/// "push" makes it ask permission to push first.
actor ScriptedWorker: Worker {
    nonisolated let events: AsyncStream<WorkerEvent>
    private let emit: AsyncStream<WorkerEvent>.Continuation
    private let workdir: String
    private var waiting: [String: CheckedContinuation<WorkerAnswer, Never>] = [:]
    private(set) var answers: [WorkerAnswer] = []

    init(workdir: String) {
        self.workdir = workdir
        (events, emit) = AsyncStream.makeStream()
    }

    /// Like a real worker, returns as soon as the work is underway.
    func start(brief: String) async throws {
        Task { try? await self.work(brief) }
    }

    private func work(_ brief: String) async throws {
        emit.yield(.session(id: "scripted-1"))
        emit.yield(.activity("Writing Nav.swift"))
        try "struct Nav {}\n".write(toFile: "\(workdir)/Nav.swift", atomically: true, encoding: .utf8)
        try await Shell.check(["git", "add", "."], cwd: workdir)
        try await Shell.check(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "Add nav"], cwd: workdir)
        if brief.contains("push") {
            let answer = await withCheckedContinuation { continuation in
                waiting["r-push"] = continuation
                emit.yield(.request(WorkerRequest(id: "r-push", kind: .permission(tool: "Bash", action: "git push", rail: "Pushes to a remote"))))
            }
            answers.append(answer)
        }
        emit.yield(.turnEnded(ok: true, text: "Added Nav.swift."))
    }

    func steer(_ text: String) async throws { emit.yield(.message(text)) }
    func resolve(_ requestID: String, _ answer: WorkerAnswer) { waiting.removeValue(forKey: requestID)?.resume(returning: answer) }
    func stop() async { emit.finish() }
}

/// Every launch a test harness was asked for.
final class LaunchLog: Sendable {
    private let launches = Mutex<[WorkerLaunch]>([])
    var all: [WorkerLaunch] { launches.withLock { $0 } }
    func record(_ launch: WorkerLaunch) { launches.withLock { $0.append(launch) } }
}

@MainActor
@Suite(.serialized) struct ConductorTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "tilde-conductor-\(UUID().uuidString)")
    var repo: String { root.appending(path: "code/app").path }

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

    var config: Conductor.Config {
        var config = Conductor.Config()
        config.projectRoots = [root.appending(path: "code").path]
        config.manager.executable = "/usr/bin/false"  // no model in these tests
        config.scribe.executable = "/usr/bin/false"
        config.dream.executable = "/usr/bin/false"
        return config
    }

    func call(_ conductor: Conductor, _ tool: String, _ args: JSON) async -> ToolResult {
        await conductor.makeTools().call(tool, args)
    }

    func waitFor(_ conductor: Conductor, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition())
    }

    @Test func delegateFinishAndLand() async throws {
        let conductor = try await makeConductor()
        let started = await call(conductor, "delegate", ["project_path": .string(repo), "title": "Nav bar", "brief": "Add a nav", "harness": "scripted"])
        #expect(!started.isError, "\(started.text)")
        let job = try #require(conductor.jobs.first)
        #expect(job.branch == "tilde/nav-bar")
        #expect(job.workdir.hasPrefix(root.appending(path: "home/worktrees/app").path))

        try await waitFor(conductor) { conductor.jobs.first?.phase == .deciding }
        #expect(conductor.jobs.first?.diff?.files == 1)
        #expect(conductor.jobs.first?.sessionID == "scripted-1")

        let finished = await call(conductor, "finish", ["job": .string(job.id), "summary": "Added the nav."])
        #expect(!finished.isError)
        #expect(conductor.jobs.first?.phase == .ready)

        try await conductor.land(job.id)
        #expect(FileManager.default.fileExists(atPath: "\(repo)/Nav.swift"))
        #expect(conductor.jobs.first?.phase == .landed)

        let note = try #require(conductor.memory.notebook.read("tasks/\(job.id).md"))
        #expect(note.contains("## Brief") && note.contains("Add a nav") && note.contains("Added the nav.") && note.contains("Landed"))
        #expect(conductor.memory.notebook.read(Notebook.journalName())?.contains("Nav bar") == true)
    }

    @Test func escalationsReachTheWorkerDirectly() async throws {
        let conductor = try await makeConductor()
        _ = await call(conductor, "delegate", ["project_path": .string(repo), "title": "Ship it", "brief": "Add a nav and push", "harness": "scripted"])
        let job = try #require(conductor.jobs.first)
        try await waitFor(conductor) { conductor.jobs.first?.phase == .deciding }

        // The manager escalates the worker's push request to Brayden...
        let asked = await call(conductor, "ask", ["question": "Push the nav?", "options": ["Allow", "Don't allow"], "recommended": 1, "request": "r-push"])
        #expect(!asked.isError)
        let item = try #require(conductor.attention.first)
        #expect(item.isApproval && item.jobID == job.id)
        #expect(conductor.jobs.first?.phase == .needsYou)

        // ...and his answer goes straight to the worker.
        conductor.answer(item.id, with: "Don't allow")
        try await waitFor(conductor) { conductor.jobs.first?.phase == .deciding && conductor.attention.isEmpty }
        let note = try #require(conductor.memory.notebook.read("tasks/\(job.id).md"))
        #expect(note.contains("git push: denied"))
    }

    @Test func tildesOwnQuestionsOutliveARestartAndTheDay() async throws {
        let first = try await makeConductor()
        _ = await call(first, "ask", ["question": "Merge app#7?", "options": ["Merge", "Not now"]])
        let asked = try #require(first.attention.first)

        // The next launch, on a new day's empty thread: still open, and still there to answer.
        let next = try Conductor(home: first.home, config: config)
        next.restore()
        next.reconcileQuestions()
        #expect(next.attention.map(\.id) == [asked.id])
        #expect(next.thread.map(\.attentionID) == [asked.id])
        #expect(next.thread.first?.at == asked.createdAt)
    }

    @Test func scratchJobsNeedNoRepo() async throws {
        let conductor = try await makeConductor()
        let started = await call(conductor, "delegate", ["title": "Check the app", "brief": "Look at it", "harness": "scripted"])
        #expect(!started.isError, "\(started.text)")
        let job = try #require(conductor.jobs.first)
        #expect(job.isolation == .scratch && job.branch == nil)
        #expect(job.workdir.hasPrefix(root.appending(path: "home/scratch").path))
    }

    /// Registers a scripted harness that records every launch it's asked for.
    func recordingHarness(_ id: String) -> LaunchLog {
        let log = LaunchLog()
        HarnessCatalog.register(HarnessSpec(id: Harness(rawValue: id), label: "Recording", executable: "/bin/sh", strengths: "Tests.") { launch in
            log.record(launch)
            return ScriptedWorker(workdir: launch.workdir)
        })
        return log
    }

    @Test func delegatePassesTheModelToTheWorker() async throws {
        let conductor = try await makeConductor()
        let launches = recordingHarness("recording-model")
        let started = await call(conductor, "delegate", [
            "project_path": .string(repo), "title": "Nav bar", "brief": "Add a nav", "harness": "recording-model", "model": "opus",
        ])
        #expect(!started.isError, "\(started.text)")
        #expect(conductor.jobs.first?.model == "opus")
        #expect(launches.all.map(\.model) == ["opus"])
    }

    @Test func steeringAStoppedWorkerResumesItsSession() async throws {
        let conductor = try await makeConductor()
        let launches = recordingHarness("recording-resume")
        _ = await call(conductor, "delegate", ["project_path": .string(repo), "title": "Nav bar", "brief": "Add a nav", "harness": "recording-resume"])
        let job = try #require(conductor.jobs.first)
        try await waitFor(conductor) { conductor.jobs.first?.sessionID == "scripted-1" }

        _ = await call(conductor, "stop", ["job": .string(job.id)])
        let steered = await call(conductor, "steer", ["job": .string(job.id), "message": "Make it sticky"])
        #expect(!steered.isError, "\(steered.text)")
        #expect(launches.all.count == 2)
        let resumed = try #require(launches.all.last)
        #expect(resumed.resume && resumed.sessionID == "scripted-1")
    }

    @Test func unknownHarnessesAreRefused() async throws {
        let conductor = try await makeConductor()
        let result = await call(conductor, "delegate", ["project_path": .string(repo), "title": "X", "brief": "Y", "harness": "nonexistent"])
        #expect(result.isError && result.text.contains("Installed:"))
    }
}
