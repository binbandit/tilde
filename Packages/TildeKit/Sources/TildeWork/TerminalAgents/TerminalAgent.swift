import Foundation
import WorkerKit

/// A coding agent the owner started in a terminal, not one of tilde's workers. tilde sees it and can
/// bring it forward, but never drives it.
public struct TerminalAgent: Sendable, Hashable, Identifiable {
    /// Where it runs.
    public enum Place: Sendable, Hashable {
        /// A herdr pane, by herdr's id for it ("w1:p2").
        case herdr(pane: String)
        /// Any other terminal: the agent's process, and the app it shows in (a bundle path) when that's known.
        case terminal(pid: Int32, app: String?)

        /// Where it is in a word or two: "herdr", "Ghostty", "a terminal".
        public var label: String {
            switch self {
            case .herdr: "herdr"
            case .terminal(_, let app): app.map { ($0 as NSString).lastPathComponent.replacing(/\.app$/, with: "") } ?? "a terminal"
            }
        }
    }

    /// herdr's reading of the agent's screen. Outside herdr it's always `unknown`.
    public enum State: String, Sendable {
        case working
        /// At an approval or a question: waiting on the owner.
        case blocked
        /// Finished a turn nobody has looked at yet.
        case done
        case idle, unknown
    }

    public var harness: Harness
    public var cwd: String
    public var state: State
    public var place: Place
    /// herdr's name for it, when it has one.
    public var name: String?
    /// The agent's own session id, when herdr knows it.
    public var session: String?
    /// How many times herdr has seen its state change, so one stretch in a state can be told from the next.
    public var changes = 0

    public init(
        harness: Harness, cwd: String, state: State, place: Place, name: String? = nil, session: String? = nil, changes: Int = 0
    ) {
        self.harness = harness
        self.cwd = cwd
        self.state = state
        self.place = place
        self.name = name
        self.session = session
        self.changes = changes
    }

    public var id: String {
        switch place {
        case .herdr(let pane): "herdr:\(pane)"
        case .terminal(let pid, _): "pid:\(pid)"
        }
    }
}
