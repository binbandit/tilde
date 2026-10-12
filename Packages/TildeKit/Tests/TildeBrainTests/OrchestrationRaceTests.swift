import Foundation
import Harnesses
import Testing
import TildeSupport
import TildeWork
import WorkerKit
@testable import TildeBrain

private actor GatedWorker: Worker {
    nonisolated let events: AsyncStream<WorkerEvent>
    private let emit: AsyncStream<WorkerEvent>.Continuation
    private let gateSteer: Bool
    private let gateStop: Bool
    private var steering: CheckedContinuation<Void, Never>?
    private var stopping: CheckedContinuation<Void, Never>?
    private(set) var didSteer = false
    private(set) var didStop = false

    init(steer: Bool = false, stop: Bool = false) {
        gateSteer = steer
        gateStop = stop
        (events, emit) = AsyncStream.makeStream()
    }
    func start(brief: String) async throws {}
    func steer(_ text: String) async throws {
        didSteer = true
        if gateSteer { await withCheckedContinuation { steering = $0 } }
    }
    func resolve(_ requestID: String, _ answer: WorkerAnswer) {}
    func stop() async {
        didStop = true
        if gateStop { await withCheckedContinuation { stopping = $0 } }
    }
    func releaseSteer() { steering?.resume(); steering = nil }
    func releaseStop() { stopping?.resume(); stopping = nil }
    func end() { emit.yield(.turnEnded(ok: true, text: "Finished")) }
}

private actor ExitAfterApprovalWorker: Worker {
    nonisolated let events: AsyncStream<WorkerEvent>
    private let emit: AsyncStream<WorkerEvent>.Continuation
    nonisolated let release = DispatchSemaphore(value: 0)
    private(set) var answers = 0
    init() { (events, emit) = AsyncStream.makeStream() }
    func start(brief: String) async throws {}
    func steer(_ text: String) async throws {}
    func resolve(_ requestID: String, _ answer: WorkerAnswer) {
        answers += 1
        emit.yield(.exited(nil))
        // Force the conductor to observe exit before the actor call returns.
        _ = release.wait(timeout: .now() + 5)
    }
    func stop() async {}
}

@MainActor @Suite(.serialized) struct OrchestrationRaceTests {
    private func eventually(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition())
    }

    private func harness(_ worker: any Worker, resumes: Bool = false) -> Harness {
        let id = Harness(rawValue: "race-\(UUID().uuidString)")
        var resumeCommand: (@Sendable (String) -> String)?
        if resumes { resumeCommand = { @Sendable _ in "/usr/bin/false" } }
        HarnessCatalog.register(HarnessSpec(
            id: id, label: "Race fixture", executable: "/usr/bin/false", strengths: "Tests",
            resumeCommand: resumeCommand
        ) { _ in worker })
        return id
    }

    @Test func deliveredApprovalSurvivesWorkerExitInAudit() async throws {
        let fixture = ConductorTests()
        let conductor = try await fixture.makeConductor()
        let worker = ExitAfterApprovalWorker()
        defer { worker.release.signal() }
        let id = harness(worker)
        let delegated = await fixture.call(conductor, "delegate", ["title": "Audit", "brief": "Fixture", "harness": .string(id.rawValue)])
        #expect(!delegated.isError)
        let job = try #require(conductor.jobs.first)
        let request = WorkerRequest(id: "exit-race", kind: .permission(tool: "Bash", action: "git push", rail: "Pushes to a remote"))
        conductor.requests[request.id] = (job.id, request)
        #expect(conductor.resolve(request.id, .allow, by: .you))
        try await eventually { conductor.workers[job.id] == nil }
        worker.release.signal()
        try await eventually { conductor.transcriptStore.load(job.id).contains { $0.kind == .decision } }
        #expect(await worker.answers == 1)
        let decision = try #require(conductor.transcriptStore.load(job.id).first { $0.kind == .decision })
        #expect(decision.from == .you && decision.text.contains("exit-race") && decision.text.contains("allowed"))
        #expect(conductor.memory.notebook.read("tasks/\(job.id).md")?.contains("exit-race") == true)
    }

    @Test func completionDuringHandoffCannotSignOffNewFeedback() async throws {
        let fixture = ConductorTests()
        let conductor = try await fixture.makeConductor()
        let worker = GatedWorker(steer: true)
        let id = harness(worker)
        let delegated = await fixture.call(conductor, "delegate", ["project_path": .string(fixture.repo), "title": "Handoff", "brief": "Fixture", "harness": .string(id.rawValue)])
        #expect(!delegated.isError)
        let job = try #require(conductor.jobs.first)
        let delivery = Task { try await conductor.deliver("New feedback", to: job.id, from: .you) }
        try await eventually { await worker.didSteer }
        await worker.end()
        try await eventually { conductor.turnEnded[job.id] != nil }
        #expect(await fixture.call(conductor, "finish", ["job": .string(job.id)]).isError)
        await worker.releaseSteer()
        try await delivery.value
        #expect(conductor.job(job.id)?.phase == .working)
        #expect(await fixture.call(conductor, "finish", ["job": .string(job.id)]).isError)
        await worker.end()
        try await eventually { conductor.successfulTurns.contains(job.id) }
        #expect(!(await fixture.call(conductor, "finish", ["job": .string(job.id)])).isError)
    }

    @Test func stopDuringHandoffDoesNotRestartTheJob() async throws {
        let fixture = ConductorTests()
        let conductor = try await fixture.makeConductor()
        let worker = GatedWorker(steer: true)
        let id = harness(worker)
        _ = await fixture.call(conductor, "delegate", ["title": "Stop", "brief": "Fixture", "harness": .string(id.rawValue)])
        let job = try #require(conductor.jobs.first)
        let delivery = Task { try await conductor.deliver("New feedback", to: job.id, from: .you) }
        try await eventually { await worker.didSteer }
        await conductor.stop(job.id)
        await worker.releaseSteer()
        await #expect(throws: (any Error).self) { try await delivery.value }
        #expect(conductor.job(job.id)?.phase == .stopped)
        #expect(conductor.deliveriesInFlight[job.id] == nil)
        #expect(await fixture.call(conductor, "finish", ["job": .string(job.id)]).isError)
    }

    @Test(arguments: [false, true])
    func shutdownCannotPublishStaleCompletion(cancel: Bool) async throws {
        let fixture = ConductorTests()
        let (conductor, job) = try await CompletionTests().readyToFinish(fixture)
        let old = GatedWorker(stop: true)
        let fresh = GatedWorker()
        let id = harness(fresh, resumes: true)
        conductor.update(job.id) { $0.harness = id }
        conductor.workers[job.id] = old
        let finish = Task { await fixture.call(conductor, "finish", ["job": .string(job.id), "summary": "Old result"]) }
        try await eventually { await old.didStop }
        if cancel {
            finish.cancel()
        } else {
            try await conductor.deliver("New work", to: job.id, from: .you)
        }
        await old.releaseStop()
        #expect(await finish.value.isError)
        #expect(conductor.job(job.id)?.phase == (cancel ? .stopped : .working))
        #expect(!conductor.thread.contains { $0.text.contains("is complete") })
        #expect(!conductor.transcriptStore.load(job.id).contains { $0.kind == .event && $0.text.contains("Complete:") })
        #expect(conductor.memory.notebook.read("tasks/\(job.id).md")?.contains("## Outcome") != true)
        await conductor.stopWorker(job.id)
    }
}
