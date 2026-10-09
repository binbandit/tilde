import CoreGraphics
import Foundation

/// Notices when you come back to the Mac after a while away from it.
@MainActor
final class Presence {
    /// Called with how long you were gone.
    var onReturn: (@MainActor (TimeInterval) -> Void)?
    private var timer: Timer?
    private var awayFor: TimeInterval = 0

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle > 60 {
            awayFor = idle
        } else if awayFor > 0 {
            onReturn?(awayFor)
            awayFor = 0
        }
    }
}
