import CoreGraphics
import Foundation
import TildeSupport

/// tilde speaking up without being asked: what the watchers notice, what comes due, what the
/// background review finds, and a word when the owner sits down or comes back.
extension Conductor {
    /// Every minute: look around and hand the manager whatever is worth a word now and whatever
    /// came due, then keep the day's rhythm (the morning brief, the background review).
    func watch() async {
        while !Task.isCancelled {
            let focused = perception?.currentContext().repo
            let found = await initiative.look(jobs: jobs, focusedRepo: focused)
            let due = await initiative.due(found, typing: Self.typing, looking: looking)
            if !due.isEmpty { report(due) }
            let coming = await initiative.comingDue()
            if !coming.isEmpty { remind(coming) }
            await keepRhythm()
            try? await Task.sleep(for: .seconds(60))
        }
    }

    /// Keys pressed in the last few seconds.
    static var typing: Bool { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 8 }

    /// Any input at all in the last two minutes.
    static var active: Bool {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) < 120
    }

    /// The first activity of the day gets the morning brief; after that, a background review
    /// every 90 minutes or so while the owner is around but not typing.
    private func keepRhythm() async {
        guard Self.active else { return }
        if await initiative.claimBrief() {
            brief(since: .now.addingTimeInterval(-12 * 3600))
        } else if !Self.typing, await initiative.reviewDue() {
            reviewInBackground(looking: false)
        }
    }

    /// Hands observations to the manager, which decides whether and how to say them.
    func report(_ observations: [Notice]) {
        Log.info("initiative", observations.map(\.summary).joined(separator: " | "))
        Task {
            await manager.post(.init(
                "<observations>\n\(Self.describe(observations))\n</observations>", paths: observations.compactMap(\.project)))
        }
    }

    static func describe(_ observations: [Notice]) -> String {
        observations.map { o in
            var line = "- [\(o.urgency.rawValue)] \(o.summary)"
            if let url = o.url { line += " \(url)" }
            if let project = o.project { line += " (local checkout: \(project))" }
            if let suggestion = o.suggestion { line += " Could: \(suggestion)." }
            return line
        }.joined(separator: "\n")
    }

    /// Hands what came due to the manager, which acts on it.
    func remind(_ items: [Due]) {
        Log.info("initiative", "due: " + items.map(\.text).joined(separator: " | "))
        Task {
            await manager.post(.init(Due.message(items), paths: items.compactMap(\.project), jobs: items.compactMap(\.job)))
        }
    }

    /// Runs the background review and passes what it finds through the delivery policy.
    func reviewInBackground(looking: Bool) {
        Task {
            guard let found = await initiative.review(await reviewInputs()), !found.isEmpty else { return }
            let due = await initiative.due(found, typing: Self.typing, looking: looking || self.looking)
            if !due.isEmpty { report(due) }
        }
    }

    /// Brayden is back at the Mac. The first time today that's the morning brief; after a while
    /// away, tilde briefs him on anything that happened and takes a fresh look around.
    public func welcomeBack(after away: TimeInterval) {
        Task {
            if await initiative.claimBrief() {
                brief(since: .now.addingTimeInterval(-away))
                return
            }
            guard away >= 15 * 60, replying == nil, !(await initiative.briefedRecently()) else { return }
            let id = IDs.make("t")
            quietTaps.insert(id)
            replying = id
            let minutes = Int(away / 60)
            await manager.post(.init(
                "<return away=\"\(minutes)m\">\(Owner.firstName) is back at the Mac. If something happened while they were away "
                    + "that they should know (work that finished, questions waiting on them), greet them with a one or two sentence "
                    + "briefing in your voice. If nothing did, reply with an empty message.</return>",
                tap: id))
            reviewInBackground(looking: true)
        }
    }
}
