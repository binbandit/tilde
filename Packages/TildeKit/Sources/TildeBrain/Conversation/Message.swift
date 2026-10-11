import Foundation
import TildeSupport

/// One line of the day's conversation with tilde.
///
/// There's a single thread a day: what you asked, what tilde said back, what it
/// told you on its own, what it needed from you and what you answered. The
/// workers never speak here; tilde speaks for them and points at them (`jobs`).
public struct Message: Identifiable, Codable, Sendable, Hashable {
    public enum From: String, Codable, Sendable { case you, tilde }

    public let id: String
    public var from: From
    public var text: String
    public var at: Date
    /// For your messages: what "this" was when you said it.
    public var pointing: String?
    /// The jobs this message is about, shown as crew chips.
    public var jobs: [String]
    /// A question waiting on you, while it's open.
    public var attentionID: String?
    /// tilde is still writing this.
    public var streaming: Bool
    /// Lasting facts tilde noted from this exchange.
    public var noted: [String]
    /// Something went wrong (shown quietly, in red).
    public var trouble: Bool
    /// A question that stopped needing an answer, and why ("oh-fx#713 merged").
    public var settled: String?
    /// While tilde works on this reply and has nothing to say yet: what it's doing ("Checking GitHub").
    public var activity: String?

    public init(
        id: String? = nil, from: From, text: String, at: Date = .now, pointing: String? = nil, jobs: [String] = [],
        attentionID: String? = nil, streaming: Bool = false, noted: [String] = [], trouble: Bool = false, settled: String? = nil
    ) {
        self.id = id ?? IDs.make("m")
        self.from = from
        self.text = text
        self.at = at
        self.pointing = pointing
        self.jobs = jobs
        self.attentionID = attentionID
        self.streaming = streaming
        self.noted = noted
        self.trouble = trouble
        self.settled = settled
    }
}
