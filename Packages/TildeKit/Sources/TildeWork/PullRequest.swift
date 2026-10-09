/// A pull request for a job's branch.
public struct PullRequest: Codable, Sendable, Hashable {
    public var number: Int
    public var url: String
    public var title: String
    /// OPEN, MERGED or CLOSED.
    public var state: String
}
