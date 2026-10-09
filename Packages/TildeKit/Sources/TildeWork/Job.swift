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
        case landed, failed, stopped

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
    /// The pull request for this job's branch, once there is one.
    public var pullRequest: PullRequest?
    public var createdAt: Date
    public var updatedAt: Date

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
}
