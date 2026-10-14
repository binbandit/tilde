import Foundation
import WorkerKit

/// One piece of delegated work: a brief, a worker, and (usually) a worktree.
public struct Job: Identifiable, Codable, Sendable, Hashable {
    public enum Phase: String, Codable, Sendable {
        case starting, working
        /// Blocked on the manager deciding something for the worker.
        case deciding
        /// Blocked on Brayden.
        case needsYou
        /// The manager has signed the work off; it's waiting for review.
        case ready
        /// Brought into the checkout.
        case landed
        /// Acknowledged without landing: no changes, scratch work, or work done in place. A worktree
        /// stays until it's discarded.
        case done
        case failed, stopped

        public var isActive: Bool { [.starting, .working, .deciding, .needsYou].contains(self) }
        public var isOpen: Bool { isActive || self == .ready }
    }

    public enum Isolation: String, Codable, Sendable {
        case worktree
        case inPlace = "in_place"
        /// Not about a repo (GUI work, research): a scratch folder, nothing to land.
        case scratch
    }

    public let id: String
    public var title: String
    public var brief: String
    public var projectName: String
    /// The user's checkout.
    public var repoPath: String
    /// Where the worker runs: a worktree, or the checkout itself for in-place jobs.
    public var workdir: String
    public var harness: Harness
    /// The model the manager picked, in the harness's own naming; nil runs the harness's default.
    public var model: String?
    public var isolation: Isolation
    public var branch: String?
    public var baseBranch: String?
    public var baseCommit: String?
    /// Claude session id or Codex thread id; what "take over" resumes.
    public var sessionID: String?
    public var phase: Phase
    /// What the worker is doing right now, in a few words.
    public var ticker: String
    /// The manager's sign-off, or the worker's last word.
    public var summary: String?
    public var diff: DiffStat?
    /// How the worker's latest turn ended, kept so it can still be signed off after a restart;
    /// nil while a message is on its way to it or being worked on.
    public var lastTurn: TurnOutcome?
    /// The pull request for this job's branch, once there is one.
    public var pullRequest: PullRequest?
    public var createdAt: Date
    public var updatedAt: Date

    public enum TurnOutcome: String, Codable, Sendable {
        case succeeded, failed
    }

    /// The primary review action is based on observed changes, never a model's summary.
    public enum ReviewAction: Sendable {
        case bringIn, acknowledge, unavailable
    }

    public var reviewAction: ReviewAction {
        guard phase == .ready else { return .unavailable }
        guard isolation == .worktree else { return .acknowledge }
        guard let diff else { return .unavailable }
        return diff.isEmpty ? .acknowledge : .bringIn
    }

    /// Its worktree or scratch folder can go. Landed work is in the checkout already, as is work done in
    /// place; work marked done has only a worktree left, kept to look at until it's discarded.
    public var canDiscard: Bool {
        switch phase {
        case .landed: false
        case .done: isolation == .worktree
        default: !phase.isActive && isolation != .inPlace
        }
    }

    public init(
        id: String, title: String, brief: String, projectName: String, repoPath: String, workdir: String,
        harness: Harness, isolation: Isolation
    ) {
        self.id = id
        self.title = title
        self.brief = brief
        self.projectName = projectName
        self.repoPath = repoPath
        self.workdir = workdir
        self.harness = harness
        self.isolation = isolation
        phase = .starting
        ticker = "Getting started"
        createdAt = .now
        updatedAt = .now
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, brief, projectName, repoPath, workdir, harness, model, isolation
        case branch, baseBranch, baseCommit, sessionID, phase, ticker, summary, diff, lastTurn, pullRequest
        case createdAt, updatedAt
    }

    private enum LegacyKeys: String, CodingKey { case acknowledgedAt }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        brief = try values.decode(String.self, forKey: .brief)
        projectName = try values.decode(String.self, forKey: .projectName)
        repoPath = try values.decode(String.self, forKey: .repoPath)
        workdir = try values.decode(String.self, forKey: .workdir)
        harness = try values.decode(Harness.self, forKey: .harness)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        isolation = try values.decode(Isolation.self, forKey: .isolation)
        branch = try values.decodeIfPresent(String.self, forKey: .branch)
        baseBranch = try values.decodeIfPresent(String.self, forKey: .baseBranch)
        baseCommit = try values.decodeIfPresent(String.self, forKey: .baseCommit)
        sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID)
        phase = try values.decode(Phase.self, forKey: .phase)
        ticker = try values.decode(String.self, forKey: .ticker)
        summary = try values.decodeIfPresent(String.self, forKey: .summary)
        diff = try values.decodeIfPresent(DiffStat.self, forKey: .diff)
        lastTurn = try values.decodeIfPresent(TurnOutcome.self, forKey: .lastTurn)
        pullRequest = try values.decodeIfPresent(PullRequest.self, forKey: .pullRequest)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        // Older builds marked acknowledgements as landed, with this timestamp distinguishing them
        // from actual landings. Without the marker the old state is ambiguous, so landed stays landed.
        if phase == .landed,
            try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Date.self, forKey: .acknowledgedAt) != nil
        {
            phase = .done
        }
    }
}
