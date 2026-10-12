import Foundation
import TildeSupport
import TildeWork

/// The background review's rhythm (one at a time, every ~90 minutes of activity, the morning
/// brief once a day) and what the watchers hand it.
extension Initiative {
    /// Runs the background review unless one is already running. Nil when it didn't run or failed.
    func review(_ inputs: Review.Inputs) async -> [Notice]? {
        guard !reviewing else { return nil }
        reviewing = true
        defer { reviewing = false }
        seen.reviewed = inputs.now
        persist()
        let started = Date.now
        guard let reply = try? await reviewModel.run(Review.pass(inputs, workdir: notebook.path)), reply.ok else {
            Log.info("review", "no review this time")
            return nil
        }
        let notices = Review.notices(from: reply.text)
        Log.info("review", "\(notices.count) in \(Int(Date.now.timeIntervalSince(started)))s: \(notices.map(\.summary).joined(separator: " | "))")
        return notices
    }

    /// Time for another review: none running, and the last started at least `interval` ago.
    func reviewDue(now: Date = .now, interval: TimeInterval = 90 * 60) -> Bool {
        !reviewing && (seen.reviewed.map { now.timeIntervalSince($0) >= interval } ?? true)
    }

    /// True once a day, the first time it's asked after 6am: the moment for the morning brief.
    func claimBrief(now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard calendar.component(.hour, from: now) >= 6, !(seen.briefed.map { calendar.isDate($0, inSameDayAs: now) } ?? false)
        else { return false }
        seen.briefed = now
        persist()
        return true
    }

    /// A brief went out in the last 20 minutes, so a welcome-back would only repeat it.
    func briefedRecently(now: Date = .now) -> Bool {
        seen.briefed.map { now.timeIntervalSince($0) < 20 * 60 } ?? false
    }

    /// The latest of what the watchers saw: PRs, agents waiting, and what's held back for later.
    func watching() -> String {
        refreshTerminalAgents()
        var sections: [String] = []
        let open = pulls.filter { $0.isMine && !$0.merged }
        // Only the most recently updated are here; a count says how many there are in all.
        let groups = [
            (openTotal > open.count ? "Your open pull requests (the \(open.count) most recently updated of \(openTotal))" : "Your open pull requests", open),
            ("Merged in the last day", pulls.filter(\.merged)),
            ("Waiting on your review", pulls.filter(\.reviewRequested)),
        ]
        for (title, pulls) in groups where !pulls.isEmpty {
            sections.append("\(title):\n" + pulls.map(\.line).joined(separator: "\n"))
        }
        if !waiting.isEmpty {
            sections.append("Coding agents waiting on you:\n" + waiting.map(\.line).joined(separator: "\n"))
        }
        if !terminalAgents.isEmpty { sections.append(terminalDescription) }
        if !held.isEmpty {
            sections.append("Noticed, not yet said:\n" + held.map { "- [\($0.urgency.rawValue)] \($0.summary)" }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    /// What `watching` says, after a first look at GitHub if tilde hasn't had one yet. The PRs
    /// are only remembered here; the next scheduled look still compares against the last one it saw.
    func watchingNow() async -> String {
        if polledAt == .distantPast, let (fresh, open) = await PullRequestWatch.fetch() {
            pulls = fresh
            openTotal = open
            polledAt = .now
        }
        return watching()
    }

    /// Pull requests and agent sessions that changed since `date`, for the morning brief.
    func changes(since date: Date) -> [String] {
        pulls.filter { ($0.updatedAt ?? .distantPast) > date }.map(\.line)
            + AgentWatch.waiting(since: date, own: ownSessions, home: home).map(\.line)
    }

    /// Read only the local opted-in event store, including when a tap arrives
    /// before the next background poll. Never connect to or resume these agents.
    func refreshTerminalAgents(now: Date = .now) {
        terminalAgents = ((try? TerminalAgentRegistry(home: home).sessions(now: now)) ?? [])
            .filter { !ownSessions.contains($0.session) }
        waiting = Array(AgentWatch.waiting(since: now.addingTimeInterval(-3 * 3600), own: ownSessions, home: home, now: now).prefix(20))
        let currentNotices = Set(waiting.map { $0.notice.key })
        held.removeAll { $0.subject.hasPrefix("agent:") && !currentNotices.contains($0.key) }
    }

    func terminalAgentContext(own: Set<String>) -> String {
        ownSessions = own
        refreshTerminalAgents()
        return terminalAgents.isEmpty ? "" : terminalDescription
    }

    private var terminalDescription: String {
        "Connected terminal agents (last observed events, not managed jobs; no control or permission to take over):\n"
            + terminalAgents.prefix(20).map { session in
                "- \(session.adapter.name) in \(session.cwd.clipped(to: 400)): \(session.state.rawValue), observed "
                    + session.updatedAt.formatted(.relative(presentation: .named))
                    + (session.isStale() ? "; stale, current state unknown" : "")
            }.joined(separator: "\n")
            + (terminalAgents.count > 20 ? "\n(Showing the 20 most recent of \(terminalAgents.count) observations.)" : "")
    }
}

extension AgentWatch.Waiting {
    var line: String {
        "- \(harness) in \((cwd as NSString).abbreviatingWithTildeInPath) finished \(finishedAt.formatted(.relative(presentation: .named))): \(lastWords)"
    }
}
