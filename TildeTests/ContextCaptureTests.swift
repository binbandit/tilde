import CoreGraphics
import Foundation
import Testing

/// A fixture collector stands in for the Accessibility reads, so nothing on this Mac is inspected.
@Suite struct ContextCaptureTests {
    @Test func theLatestRequestWins() async throws {
        let collector = Collector(holding: 1)
        let capture = ContextCapture(collect: collector.collect)
        let delivered = Deliveries()

        capture.start(request(1), update: delivered.record)
        try await waitUntil { collector.started.contains(1) }
        // Both of these queue behind the read that's holding; only the last should count.
        capture.start(request(2), update: delivered.record)
        await Task.yield()
        capture.start(request(3), update: delivered.record)
        collector.release()

        try await waitUntil { !delivered.apps.isEmpty }
        #expect(delivered.apps == ["App 3"])
        #expect(!collector.ranOnMainThread)
    }

    @Test func aCancelledRequestNeverDelivers() async throws {
        let collector = Collector(holding: 1)
        let capture = ContextCapture(collect: collector.collect)
        let delivered = Deliveries()

        capture.start(request(1), update: delivered.record)
        try await waitUntil { collector.started.contains(1) }
        capture.cancel()
        collector.release()
        // Reads are serial, so once the next request delivers, the cancelled one has finished.
        capture.start(request(2), update: delivered.record)

        try await waitUntil { !delivered.apps.isEmpty }
        #expect(delivered.apps == ["App 2"])
    }

    private func request(_ pid: pid_t) -> Pointing.Request {
        Pointing.Request(
            application: Pointing.Application(name: "App \(pid)", bundleID: "fixture.app.\(pid)", pid: pid),
            point: CGPoint(x: 120, y: 150), fallback: nil,
            coordinates: Coordinates.Snapshot(primaryHeight: 1000), includeSelection: false)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class Deliveries {
    var apps: [String] = []

    func record(_ referent: Referent?) {
        if let referent { apps.append(referent.app) }
    }
}

/// Answers every read with a referent named after its app, holding the read for one pid
/// until released.
nonisolated private final class Collector: @unchecked Sendable {
    private let held: pid_t
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var pids: [pid_t] = []
    private var mainThread = false

    init(holding pid: pid_t) { held = pid }

    var started: [pid_t] { lock.withLock { pids } }
    var ranOnMainThread: Bool { lock.withLock { mainThread } }

    func release() { gate.signal() }

    func collect(_ request: Pointing.Request) -> Referent? {
        let pid = request.application.pid
        lock.withLock {
            pids.append(pid)
            mainThread = mainThread || Thread.isMainThread
        }
        if pid == held { _ = gate.wait(timeout: .now() + 5) }
        return Referent(app: request.application.name, bundleID: request.application.bundleID, pid: pid, frame: .zero, label: "Fixture")
    }
}
