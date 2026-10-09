/// Something tilde noticed on its own that might be worth a word.
public struct Notice: Sendable, Hashable, Codable {
    public enum Urgency: String, Sendable, Codable, Comparable {
        /// Worth interrupting: something is broken or blocked because of you.
        case now
        /// Worth a word at the next natural break.
        case soon
        /// Worth knowing when you next look.
        case fyi

        private var rank: Int { self == .now ? 0 : self == .soon ? 1 : 2 }
        public static func < (a: Urgency, b: Urgency) -> Bool { a.rank < b.rank }
    }

    /// Stable identity, so the same thing is never raised twice.
    public var key: String
    /// What it's about (a PR, a job, a repo), for per-subject cooldowns.
    public var subject: String
    public var urgency: Urgency
    /// The facts, plainly: what changed.
    public var summary: String
    public var url: String?
    /// The local checkout it concerns, when known, so tilde can act on it.
    public var project: String?
    /// What tilde could do about it, if anything.
    public var suggestion: String?
}
