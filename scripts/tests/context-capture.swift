import AppKit
import Foundation

/// Fixture-only checks: no capture snapshots, real Accessibility reads, or shell inspection.
@main
struct ContextCaptureChecks {
    @MainActor
    static func main() async throws {
        let fixture = BlockingCollector()
        let capture = ContextCapture(collect: fixture.collect)
        var accepted: [String?] = []

        capture.start(request(1)) { accepted.append($0?.app) }
        try await waitUntil { fixture.started.contains(1) }
        precondition(accepted == [nil], "A new request must invalidate the prior target immediately")

        // The main actor is still available while the first collector is blocked. Queue one
        // request, then supersede it before allowing the reader to make progress.
        capture.start(request(2)) { accepted.append($0?.app) }
        await Task.yield()
        capture.start(request(3)) { accepted.append($0?.app) }
        await Task.yield()
        fixture.release.signal()
        try await waitUntil { accepted.count == 4 }
        precondition(accepted == [nil, nil, nil, "App 3"], "A superseded result was delivered")
        precondition(fixture.started == [1, 3], "A cancelled queued request performed collection")
        precondition(!fixture.ranOnMainThread, "The collector blocked the UI thread")

        // Unpoint, send, dismiss, or a replacement exchange can all invalidate a running read.
        capture.start(request(4)) { accepted.append($0?.app) }
        precondition(accepted.last! == nil, "Sending while a re-aim is pending must not use the previous target")
        try await waitUntil { fixture.started.contains(4) }
        capture.cancel()
        fixture.release.signal()
        capture.start(request(5)) { accepted.append($0?.app) }
        try await waitUntil { accepted.count == 7 }
        precondition(accepted == [nil, nil, nil, "App 3", nil, nil, nil], "Cancel restored context, or nil did not complete")

        var missingCompleted = false
        capture.start(nil) { value in
            precondition(value == nil)
            missingCompleted = true
        }
        precondition(missingCompleted, "A missing snapshot left the request pending")

        let coordinates = Coordinates.Snapshot(primaryHeight: 1000)
        precondition(coordinates.quartz(CGPoint(x: -120, y: 850)) == CGPoint(x: -120, y: 150))
        precondition(coordinates.cocoa(CGRect(x: -120, y: 150, width: 600, height: 400)) == CGRect(x: -120, y: 450, width: 600, height: 400))

        let windows = [window(99, layer: 26), window(6, layer: 10, alpha: 0), window(7, layer: 3), window(8, layer: 0)]
        precondition(ContextCapture.windowOwner(at: CGPoint(x: -100, y: 200), windows: windows, excluding: 99) == 7,
            "The Lens or an invisible window hid a floating application's target")
        precondition(ContextCapture.windowOwner(at: .zero, windows: windows, excluding: 99) == nil)
        print("Context capture checks passed: off-main reads, coalescing, cancellation, nil completion, frozen coordinates, window ownership")
    }

    nonisolated private static func request(_ pid: pid_t) -> Pointing.Request {
        Pointing.Request(
            application: Pointing.Application(name: "App \(pid)", bundleID: "fixture.app.\(pid)", pid: pid),
            point: CGPoint(x: 120, y: 150), fallback: nil,
            coordinates: Coordinates.Snapshot(primaryHeight: 1000), includeSelection: false)
    }

    private static func window(_ pid: pid_t, layer: Int, alpha: Double = 1) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: CGRect(x: -120, y: 150, width: 600, height: 400).dictionaryRepresentation,
        ]
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Fixture collection did not finish")
    }
}

nonisolated private final class BlockingCollector: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var captured: [pid_t] = []
    private var mainThread = false

    var started: [pid_t] { lock.withLock { captured } }
    var ranOnMainThread: Bool { lock.withLock { mainThread } }

    func collect(_ request: Pointing.Request) -> Referent? {
        let pid = request.application.pid
        lock.withLock {
            captured.append(pid)
            mainThread = mainThread || Thread.isMainThread
        }
        if pid == 1 || pid == 4 {
            precondition(release.wait(timeout: .now() + 5) == .success, "The main actor stalled behind collection")
        }
        guard pid != 5 else { return nil }
        return Referent(app: request.application.name, bundleID: request.application.bundleID, pid: pid, frame: .zero, label: "Fixture")
    }
}
