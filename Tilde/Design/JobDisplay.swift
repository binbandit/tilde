import SwiftUI
import TildeKit

/// How jobs read on screen.
extension Job.Phase {
    var mood: TildeMark.Mood {
        switch self {
        case .starting, .working: .working
        case .deciding: .thinking
        case .needsYou: .needsYou
        case .ready, .landed, .done: .done
        case .failed: .failed
        case .stopped: .idle
        }
    }

    /// The owner has closed it out: brought in, or acknowledged with nothing to bring in.
    var isSettled: Bool { self == .landed || self == .done }
}

extension Job {
    var elapsed: String {
        let seconds = Int((phase.isActive ? Date.now : updatedAt).timeIntervalSince(createdAt))
        return seconds < 60 ? "\(seconds)s" : seconds < 3600 ? "\(seconds / 60)m" : "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }
}
