import Foundation
import Testing
import TildeSupport
import TildeWork
import WorkerKit
@testable import TildeBrain

/// A job's work takes turns: messages to it, the ends of its turns, sign-off and stops don't trip over
/// each other, however their timing falls.
@MainActor @Suite(.serialized) struct OrchestrationRaceTests {
    let fixture = ConductorFixture()

    @Test func messagesToABusyJobWaitTheirTurn() async throws {
        let conductor = try await fixture.makeConductor()
        let worker = FakeWorker()
        let job = try await fixture.delegate(conductor, to: worker, inRepo: false)
        await worker.hold(.afterMarker)
        let first = Task { try await conductor.message(job.id, "First") }
        try await fixture.waitFor { await worker.received.count == 2 }
        let second = Task { try await conductor.message(job.id, "Second") }
        await worker.release()
        try await first.value
        try await second.value
        #expect(await worker.received == ["Fixture only", "First", "Second"])
    }

    @Test func aMessageStillWaitingWhenTheJobIsStoppedIsNotDelivered() async throws {
        let conductor = try await fixture.makeConductor()
        let worker = FakeWorker()
        let job = try await fixture.delegate(conductor, to: worker, inRepo: false)
        await worker.hold(.afterMarker)
        let first = Task { try await conductor.message(job.id, "First") }
        let second = Task { try await conductor.message(job.id, "Second") }
        try await fixture.waitFor { await worker.received.count == 2 }
        await conductor.stop(job.id)
        await #expect(throws: FakeWorker.Failure.self) { try await first.value }
        await #expect(throws: DeliveryInterrupted.self) { try await second.value }
        #expect(await worker.received == ["Fixture only", "First"])
        #expect(conductor.job(job.id)?.phase == .stopped)
    }

    @Test func anEarlierTurnEndingAsNewWorkArrivesDoesNotFinishIt() async throws {
        let conductor = try await fixture.makeConductor()
        let worker = FakeWorker()
        let job = try await fixture.finishedJob(conductor, worker: worker)
        await worker.hold(.beforeMarker)
        let delivery = Task { try await conductor.deliver("New feedback", to: job.id, from: .you) }
        try await fixture.waitFor { await worker.received.count == 2 }
        // The end of the turn before it, still on its way when the feedback went over.
        await worker.end()
        await worker.notice("Drained")
        try await fixture.waitFor { conductor.job(job.id)?.ticker == "Drained" }
        #expect(conductor.job(job.id)?.lastTurn == nil)

        await worker.release()
        try await delivery.value
        #expect(await fixture.call(conductor, "finish", ["job": .string(job.id)]).isError)
        await worker.end()
        try await fixture.waitFor { conductor.job(job.id)?.lastTurn == .succeeded }
        #expect(!(await fixture.call(conductor, "finish", ["job": .string(job.id)])).isError)
    }

    @Test(arguments: [false, true])
    func aTurnThatEndsBeforeItsSendReturnsCountsOnlyOnceItDoes(sendFails: Bool) async throws {
        let conductor = try await fixture.makeConductor()
        let worker = FakeWorker()
        let job = try await fixture.finishedJob(conductor, worker: worker)
        await worker.hold(.afterMarker)
        if sendFails { await worker.fail() }
        let delivery = Task { try await conductor.deliver("Quick work", to: job.id, from: .you) }
        try await fixture.waitFor { await worker.received.count == 2 }
        await worker.end()
        await worker.notice("Drained")
        try await fixture.waitFor { conductor.job(job.id)?.ticker == "Drained" }
        #expect(conductor.job(job.id)?.lastTurn == nil)

        await worker.release()
        if sendFails {
            await #expect(throws: FakeWorker.Failure.self) { try await delivery.value }
            #expect(conductor.job(job.id)?.phase == .failed)
            #expect(await fixture.call(conductor, "finish", ["job": .string(job.id)]).isError)
        } else {
            try await delivery.value
            try await fixture.waitFor { conductor.job(job.id)?.lastTurn == .succeeded }
            #expect(!(await fixture.call(conductor, "finish", ["job": .string(job.id)])).isError)
        }
    }

    @Test func aStopWhileAMessageIsOnItsWayWins() async throws {
        let conductor = try await fixture.makeConductor()
        let worker = FakeWorker()
        let job = try await fixture.finishedJob(conductor, worker: worker)
        await worker.hold(.afterMarker)
        let delivery = Task { try await conductor.deliver("New feedback", to: job.id, from: .you) }
        try await fixture.waitFor { await worker.received.count == 2 }
        await conductor.stop(job.id)
        await #expect(throws: (any Error).self) { try await delivery.value }
        #expect(await worker.stopped)
        #expect(conductor.job(job.id)?.phase == .stopped)
        #expect(await fixture.call(conductor, "finish", ["job": .string(job.id)]).isError)
    }

    @Test func aStopWhileAWorkerStartsLeavesTheJobStopped() async throws {
        let conductor = try await fixture.makeConductor()
        let job = try await fixture.delegate(conductor, to: FakeWorker(), inRepo: false)
        await conductor.stop(job.id)
        let next = FakeWorker()
        let (harness, launches) = fixture.harness { _ in next }
        conductor.update(job.id) { $0.harness = harness }
        await next.hold(.afterMarker)
        let delivery = Task { try await conductor.deliver("Carry on", to: job.id, from: .you) }
        try await fixture.waitFor { await next.received.count == 1 }
        await conductor.stop(job.id)
        await #expect(throws: (any Error).self) { try await delivery.value }
        #expect(launches.all.count == 1)
        #expect(await next.stopped)
        #expect(conductor.job(job.id)?.phase == .stopped)
    }

    @Test func aStopAfterTheGitSnapshotDoesNotLaunchAWorker() async throws {
        let conductor = try await fixture.makeConductor()
        let job = try await fixture.delegate(conductor, to: FakeWorker())
        await conductor.stop(job.id)
        let next = FakeWorker()
        let (harness, launches) = fixture.harness { _ in next }
        conductor.update(job.id) { $0.harness = harness }

        // Snapshotting ends before the final git-directory lookup. Stop while that asynchronous
        // preparation is under way, before there is a worker to retire.
        let stopping = Task {
            let deadline = ContinuousClock.now + .seconds(5)
            while conductor.runs[job.id]?.gitGuard == nil, ContinuousClock.now < deadline { await Task.yield() }
            #expect(conductor.runs[job.id]?.gitGuard != nil)
            #expect(conductor.runs[job.id]?.worker == nil)
            await conductor.stop(job.id)
        }
        let delivery = Task { try await conductor.deliver("Carry on", to: job.id, from: .you) }
        await stopping.value
        await #expect(throws: DeliveryInterrupted.self) { try await delivery.value }
        #expect(launches.all.isEmpty)
        #expect(conductor.runs[job.id]?.worker == nil)
        #expect(conductor.job(job.id)?.phase == .stopped)
    }

    @Test(arguments: [Job.Isolation.inPlace, .scratch])
    func aReplacementWaitsForTheOldWorkerToStop(_ isolation: Job.Isolation) async throws {
        let conductor = try await fixture.makeConductor()
        let old = FakeWorker()
        let (firstHarness, _) = fixture.harness { _ in old }
        let workdir = isolation == .inPlace ? fixture.repo : conductor.home.scratch.appending(path: "fixture").path
        try FileManager.default.createDirectory(atPath: workdir, withIntermediateDirectories: true)
        var job = Job(id: "j-held-stop", title: "Fixture", brief: "Fixture", projectName: "app",
                      repoPath: workdir, workdir: workdir, harness: firstHarness, isolation: isolation)
        job.sessionID = "fixture-session"
        conductor.addJob(job)
        try await conductor.deliver("First", to: job.id, from: .you)
        await old.holdStop()
        let stopping = Task { await conductor.stop(job.id) }
        try await fixture.waitFor { await old.stopped }

        let next = FakeWorker()
        let (nextHarness, launches) = fixture.harness { _ in next }
        conductor.update(job.id) { $0.harness = nextHarness }
        let delivery = Task { try await conductor.deliver("Second", to: job.id, from: .you) }
        try await fixture.waitFor { conductor.job(job.id)?.phase == .working }
        for _ in 0..<100 { await Task.yield() }
        #expect(await !old.finishedStopping)
        #expect(launches.all.isEmpty)

        await old.releaseStop()
        await stopping.value
        try await delivery.value
        #expect(await old.finishedStopping)
        #expect(await next.received == ["Second"])
        await conductor.stop(job.id)
    }

    @Test(arguments: [false, true])
    func newerWorkSupersedesAPendingTakeOver(inRepo: Bool) async throws {
        let conductor = try await fixture.makeConductor()
        let old = FakeWorker()
        let job = try await fixture.delegate(conductor, to: old, inRepo: inRepo)
        conductor.update(job.id) { $0.sessionID = "fixture-session" }
        await old.holdStop()
        let takeover = Task { await conductor.takeOver(job.id) }
        try await fixture.waitFor { await old.stopped }

        let next = FakeWorker()
        let (harness, launches) = fixture.harness { _ in next }
        conductor.update(job.id) { $0.harness = harness }
        let latest = conductor.handOver("Latest follow-up", to: job.id, ticker: "Working on your message")
        await old.releaseStop()

        #expect(await takeover.value == nil)
        try await latest.value
        #expect(launches.all.count == 1)
        #expect(await next.received == ["Latest follow-up"])
        #expect(conductor.job(job.id)?.phase == .working)
        await conductor.stop(job.id)
    }

    @Test func aNewerStopSupersedesAPendingTakeOver() async throws {
        let conductor = try await fixture.makeConductor()
        let old = FakeWorker()
        let job = try await fixture.delegate(conductor, to: old, inRepo: false)
        conductor.update(job.id) { $0.sessionID = "fixture-session" }
        await old.holdStop()
        let takeover = Task { await conductor.takeOver(job.id) }
        try await fixture.waitFor { await old.stopped }
        let stopping = Task { await conductor.stop(job.id) }
        try await fixture.waitFor { conductor.job(job.id)?.ticker == "Stopped" }
        await old.releaseStop()
        await stopping.value
        #expect(await takeover.value == nil)
        #expect(conductor.job(job.id)?.ticker == "Stopped")
    }
}
