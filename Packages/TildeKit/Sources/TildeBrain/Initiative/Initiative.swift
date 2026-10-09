import Foundation
import TildeSupport
import TildeWork

/// tilde's initiative: cheap, read-only watchers that notice what a good
/// chief of staff would mention, and a delivery policy that decides when.
///
/// Watchers (in Watchers/) only observe. The manager decides whether an observation deserves
/// a word, phrases it, and offers to act; acting still waits for a yes unless
/// rules.md says otherwise.
public actor Initiative {
    public struct Seen: Codable, Sendable {
        /// Last known state per subject, to detect transitions.
        var states: [String: String] = [:]
        /// When each key was raised.
        var raised: [String: Date] = [:]
        /// When anything about a subject was last raised.
        var subjects: [String: Date] = [:]
        var baselined = false
    }

    private let home: TildeHome
    private let projects: ProjectIndex
    var seen: Seen
    /// Observations waiting for the right moment.
    private var held: [Notice] = []
    private var interrupts: [Date] = []
    /// GitHub is asked at most every few minutes; between polls the last answer stands.
    private var pulls: [PullRequestWatch.Pull] = []
    private var polledAt = Date.distantPast

    public init(home: TildeHome, projects: ProjectIndex) {
        self.home = home
        self.projects = projects
        seen = (try? Data(contentsOf: home.state.appending(path: "initiative.json")))
            .flatMap { try? JSONDecoder().decode(Seen.self, from: $0) } ?? Seen()
    }

    // MARK: Policy

    /// What to say now, given what the watchers found and what Brayden is doing.
    /// `typing` means keys were pressed in the last few seconds; `looking` means the
    /// Inlet is open or he just came back.
    public func due(_ found: [Notice], typing: Bool, looking: Bool, now: Date = .now) -> [Notice] {
        for observation in found where !isRepeat(observation, now: now) && !held.contains(where: { $0.key == observation.key }) {
            held.append(observation)
        }
        interrupts.removeAll { now.timeIntervalSince($0) > 3600 }

        let ready = held.filter { observation in
            switch observation.urgency {
            case .now: true
            case .soon: !typing && interrupts.count < 4
            case .fyi: looking
            }
        }
        guard !ready.isEmpty else { return [] }
        held.removeAll { item in ready.contains { $0.key == item.key } }
        if ready.contains(where: { $0.urgency != .fyi }) { interrupts.append(now) }
        for observation in ready {
            seen.raised[observation.key] = now
            seen.subjects[observation.subject] = now
        }
        persist()
        return ready.sorted { $0.urgency < $1.urgency }
    }

    /// Already said, or something about the same subject was said very recently.
    private func isRepeat(_ observation: Notice, now: Date) -> Bool {
        if seen.raised[observation.key] != nil { return true }
        if let last = seen.subjects[observation.subject], now.timeIntervalSince(last) < 30 * 60, observation.urgency != .now { return true }
        return false
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(seen) {
            try? data.write(to: home.state.appending(path: "initiative.json"), options: .atomic)
        }
    }

    // MARK: Watching

    /// Runs every watcher and returns what changed since last time. The first
    /// run only learns the current state, so tilde doesn't open with a backlog.
    public func look(jobs: [Job], focusedRepo: String?) async -> [Notice] {
        var found: [Notice] = []
        if Date.now.timeIntervalSince(polledAt) > 180, let fresh = await PullRequestWatch.fetch() {
            polledAt = .now
            pulls = fresh
            found += transitions(fresh)
        }
        found += nudges(pulls, focusedRepo: focusedRepo)
        found += JobWatch.notices(jobs)
        found += AgentWatch.waiting(since: .now.addingTimeInterval(-3 * 3600)).map(\.notice)
        if !seen.baselined {
            seen.baselined = true
            for observation in found { seen.raised[observation.key] = .now }
            persist()
            return []
        }
        persist()
        return found
    }
}
