import Foundation
import TildeMemory
import TildeSupport
import TildeWork

/// tilde's initiative: cheap, read-only watchers that notice what a good chief of staff would
/// mention, the follow-ups, routines and goals that come due, a background review that connects
/// the dots, and a delivery policy that decides when any of it is said.
///
/// Watchers (in Watchers/) only observe. Goals and the agenda (in Agenda/) live in the notebook.
/// The review (in Review/) only reads. The manager decides whether an observation deserves a word,
/// phrases it, and offers to act; acting still waits for a yes unless rules.md says otherwise.
public actor Initiative {
    public struct Seen: Codable, Sendable {
        /// Last known state per subject, to detect transitions.
        var states: [String: String] = [:]
        /// When each key was raised.
        var raised: [String: Date] = [:]
        /// When anything about a subject was last raised.
        var subjects: [String: Date] = [:]
        var baselined = false
        /// Routines: when each last came due (or was first seen), by its agenda line.
        var fired: [String: Date] = [:]
        /// Goals: the check-in last handed to the manager, by path.
        var checkIns: [String: String] = [:]
        /// When the last morning brief was given.
        var briefed: Date?
        /// When the background review last started.
        var reviewed: Date?
        /// Open questions about PRs, by attention id, so they can withdraw when moot.
        var asks: [String: [Concern]] = [:]
        /// When each PR trouble (failing checks, a conflict) was first seen, while it lasts.
        var since: [String: Date] = [:]
    }

    let home: TildeHome
    let notebook: Notebook
    let reviewModel: any MemoryModel
    var seen: Seen
    /// Observations waiting for the right moment.
    var held: [Notice] = []
    private var interrupts: [Date] = []
    /// GitHub is asked at most every few minutes; between polls the last answer stands.
    var pulls: [PullRequestWatch.Pull] = []
    var polledAt = Date.distantPast
    /// The poll the open questions were last checked against.
    var mootCheckedAt = Date.distantPast
    /// Agents that the last look found waiting on the owner.
    var waiting: [AgentWatch.Waiting] = []
    /// Last lifecycle observations from explicitly connected terminal projects.
    var terminalAgents: [TerminalAgentSession] = []
    /// The sessions of tilde's own jobs, which aren't the owner's agents to be reminded of.
    var ownSessions: Set<String> = []
    /// How many PRs the owner has open in all, of which `pulls` holds the most recently updated.
    var openTotal = 0
    /// The owner's checkouts, to find a PR's by its repo.
    let projects: ProjectIndex?
    /// A checkout path by owner/repo, for the PRs watched this poll.
    var checkouts: [String: String] = [:]
    /// One background review at a time.
    var reviewing = false

    public init(home: TildeHome, review: any MemoryModel = CodexReviewModel(), projects: ProjectIndex? = nil) {
        self.home = home
        self.projects = projects
        notebook = Notebook(url: home.notebook)
        reviewModel = review
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

    func persist() {
        if let data = try? JSONEncoder().encode(seen) {
            try? data.write(to: home.state.appending(path: "initiative.json"), options: .atomic)
        }
    }

    // MARK: Watching

    /// Runs every watcher and returns what changed since last time. The first
    /// run only learns the current state, so tilde doesn't open with a backlog.
    public func look(jobs: [Job], focusedRepo: String?) async -> [Notice] {
        var found: [Notice] = []
        if Date.now.timeIntervalSince(polledAt) > 180, let (fresh, open) = await PullRequestWatch.fetch() {
            openTotal = open
            for repo in Set(fresh.map(\.repo)) where checkouts[repo] == nil {
                checkouts[repo] = await projects?.checkout(of: repo)?.path
            }
            found += saw(fresh)
        }
        found += nudges(pulls, focusedRepo: focusedRepo)
        found += JobWatch.notices(jobs)
        ownSessions = Set(jobs.compactMap(\.sessionID))
        refreshTerminalAgents()
        found += waiting.map(\.notice)
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

extension Initiative.Seen {
    /// Lenient, so state written by an older tilde (missing newer fields) still loads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        states = try c.decodeIfPresent([String: String].self, forKey: .states) ?? [:]
        raised = try c.decodeIfPresent([String: Date].self, forKey: .raised) ?? [:]
        subjects = try c.decodeIfPresent([String: Date].self, forKey: .subjects) ?? [:]
        baselined = try c.decodeIfPresent(Bool.self, forKey: .baselined) ?? false
        fired = try c.decodeIfPresent([String: Date].self, forKey: .fired) ?? [:]
        checkIns = try c.decodeIfPresent([String: String].self, forKey: .checkIns) ?? [:]
        briefed = try c.decodeIfPresent(Date.self, forKey: .briefed)
        reviewed = try c.decodeIfPresent(Date.self, forKey: .reviewed)
        asks = (try? c.decodeIfPresent([String: [Initiative.Concern]].self, forKey: .asks)) ?? [:]
        since = (try? c.decodeIfPresent([String: Date].self, forKey: .since)) ?? [:]
    }
}
