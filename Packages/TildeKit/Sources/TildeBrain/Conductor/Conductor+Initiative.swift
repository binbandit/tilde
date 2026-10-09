import CoreGraphics
import Foundation
import TildeSupport

/// tilde speaking up without being asked: what the watchers notice, and a word
/// when the owner comes back.
extension Conductor {
    /// Every minute: look around, and hand the manager whatever is worth a word right now.
    func watch() async {
        while !Task.isCancelled {
            let focused = perception?.currentContext().repo
            let found = await initiative.look(jobs: jobs, focusedRepo: focused)
            let typing = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 8
            let due = await initiative.due(found, typing: typing, looking: looking)
            if !due.isEmpty { report(due) }
            try? await Task.sleep(for: .seconds(60))
        }
    }

    /// Hands observations to the manager, which decides whether and how to say them.
    func report(_ observations: [Notice]) {
        Log.info("initiative", observations.map(\.summary).joined(separator: " | "))
        let body = observations.map { o in
            var line = "- [\(o.urgency.rawValue)] \(o.summary)"
            if let url = o.url { line += " \(url)" }
            if let project = o.project { line += " (local checkout: \(project))" }
            if let suggestion = o.suggestion { line += " Could: \(suggestion)." }
            return line
        }.joined(separator: "\n")
        Task { await manager.post(.init("<observations>\n\(body)\n</observations>", paths: observations.compactMap(\.project))) }
    }

    /// Brayden is back after a while: tilde briefs him if anything happened.
    public func welcomeBack(after away: TimeInterval) {
        guard away >= 15 * 60, replying == nil else { return }
        let id = IDs.make("t")
        quietTaps.insert(id)
        replying = id
        let minutes = Int(away / 60)
        Task {
            await manager.post(.init(
                "<return away=\"\(minutes)m\">\(Owner.firstName) is back at the Mac. If something happened while they were away "
                    + "that they should know (work that finished, questions waiting on them), greet them with a one or two sentence "
                    + "briefing in your voice. If nothing did, reply with an empty message.</return>",
                tap: id))
        }
    }
}
