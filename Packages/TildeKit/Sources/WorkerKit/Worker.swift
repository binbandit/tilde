/// A coding agent working on one job, whatever harness runs it.
public protocol Worker: Actor {
    nonisolated var events: AsyncStream<WorkerEvent> { get }
    /// Launches the agent with its first instruction.
    func start(brief: String) async throws
    /// A follow-up instruction, delivered at the next opportunity.
    func steer(_ text: String) async throws
    /// Unblocks a pending `WorkerEvent.request`.
    func resolve(_ requestID: String, _ answer: WorkerAnswer)
    func stop() async
}

public enum WorkerEvent: Sendable {
    case session(id: String)
    /// Short present-tense status for tickers ("Running swift build").
    case activity(String)
    case message(String)
    /// The worker is blocked until `Worker.resolve` answers this.
    case request(WorkerRequest)
    case turnEnded(ok: Bool, text: String)
    case notice(String)
    case exited(String?)
}

public struct WorkerRequest: Sendable, Identifiable {
    public enum Kind: Sendable {
        case permission(tool: String, action: String, rail: String?)
        case question([WorkerQuestion])
    }

    public let id: String
    public var kind: Kind
    /// Original harness permission data. Nil means the request cannot be automatically approved.
    public let permissionContext: PermissionContext?

    public init(id: String, kind: Kind, permissionContext: PermissionContext? = nil) {
        self.id = id
        self.kind = kind
        self.permissionContext = permissionContext
    }

    /// One line naming what is being asked, for logs and prompts.
    public var headline: String {
        switch kind {
        case .permission(let tool, let action, _): "\(tool): \(action)"
        case .question(let questions): questions.map(\.question).joined(separator: " / ")
        }
    }
}

public struct WorkerQuestion: Sendable, Codable, Hashable {
    public var question: String
    public var options: [String]
    public var multiSelect: Bool

    public init(question: String, options: [String], multiSelect: Bool) {
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
    }
}

public enum WorkerAnswer: Sendable {
    case allow
    case deny(String)
    /// Free text, or an option label for questions.
    case reply(String)

    public var isAllow: Bool { if case .allow = self { true } else { false } }

    /// Whether a free-text reply is a plain yes ("Allow", "yes please"), for yes-or-no questions. The
    /// whole reply has to be one: "ok but not to main" and "do not push" are not.
    public static func isYes(_ reply: String) -> Bool {
        let words = reply.lowercased().split { !$0.isLetter }.joined(separator: " ")
        return [
            "allow", "allow it", "allow once", "yes", "yes please", "yep", "yeah", "y", "approve", "approved", "approve it",
            "ok", "okay", "sure", "fine", "go ahead", "go for it", "do it", "yes go ahead", "yes do it", "yep go ahead",
            "sure go ahead", "ok go ahead", "okay go ahead", "ok do it", "yes allow it",
        ].contains(words)
    }
}
