import Foundation
import TildeSupport
import TildeWork

/// Only explicitly registered terminal sessions. Lifecycle metadata is enough
/// to notice a waiting turn; this watcher never opens agent transcripts.
enum AgentWatch {
    struct Waiting: Sendable {
        var identity: String
        var harness: String
        var session: String
        var cwd: String
        var finishedAt: Date
        var lastWords: String
    }

    static func waiting(since: Date, quiet: TimeInterval = 5 * 60, own: Set<String> = [],
                        home: TildeHome = .default, now: Date = .now) -> [Waiting] {
        let sessions = (try? TerminalAgentRegistry(home: home).sessions(now: now)) ?? []
        return sessions.filter {
            $0.state == .waiting && $0.updatedAt > since && now.timeIntervalSince($0.updatedAt) > quiet
                && !own.contains($0.session) && !$0.isStale(now: now)
        }.map {
            Waiting(identity: $0.adapter.rawValue + ":" + $0.id, harness: $0.adapter.name, session: $0.session, cwd: $0.cwd,
                    finishedAt: $0.updatedAt, lastWords: "Turn completed (reported by the project's opt-in hook).")
        }
    }
}

extension AgentWatch.Waiting {
    var notice: Notice {
        Notice(
            key: "agent:\(identity):\(Int(finishedAt.timeIntervalSince1970))", subject: "agent:\(identity)",
            urgency: .fyi,
            summary: "\(harness) in \((cwd as NSString).abbreviatingWithTildeInPath) reported a completed turn and is waiting for you.",
            project: cwd, suggestion: nil)
    }
}
