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
}
