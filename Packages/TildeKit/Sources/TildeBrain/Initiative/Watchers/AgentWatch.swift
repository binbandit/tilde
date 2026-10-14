import Foundation
import Harnesses
import TildeWork
import WorkerKit

/// The owner's own coding agents, running in terminals. Only herdr can tell how one is doing, so
/// only its agents are ever worth a word: one stuck at an approval or a question, and one that
/// finished work nobody has looked at.
enum AgentWatch {
    /// Every agent CLI in the catalog by its program, to find them among the terminal's processes.
    static var executables: [String: Harness] {
        Dictionary(HarnessCatalog.all.map { ($0.executable, $0.id) }) { first, _ in first }
    }

    /// What's worth a word, comparing this look with the last. An agent blocked at both, with no change
    /// in between, has waited a minute or more, so the owner isn't busy answering it. One newly `done`
    /// finished unseen (herdr calls it idle once someone has looked). An agent seen for the first time
    /// is only learned.
    static func notices(_ agents: [TerminalAgent], before: [TerminalAgent]) -> [Notice] {
        let last = Dictionary(before.map { ($0.id, $0) }) { $1 }
        return agents.compactMap { agent in
            guard let previous = last[agent.id] else { return nil }
            let unchanged = previous.state == agent.state && previous.changes == agent.changes
            switch agent.state {
            case .blocked where unchanged:
                return notice(agent, .soon, "is waiting on you: an approval or a question")
            case .done where !unchanged:
                return notice(agent, .fyi, "finished and is waiting for you")
            default:
                return nil
            }
        }
    }

    /// A notice about an agent stands while the agent stays as it was when it was noticed.
    static func key(_ agent: TerminalAgent) -> String { "terminal:\(agent.id):\(agent.state.rawValue):\(agent.changes)" }

    static func describe(_ agents: [TerminalAgent]) -> String {
        "Your own coding agents, running in terminals (not tilde's jobs):\n" + agents.prefix(20).map(\.line).joined(separator: "\n")
    }

    private static func notice(_ agent: TerminalAgent, _ urgency: Notice.Urgency, _ what: String) -> Notice {
        Notice(key: key(agent), subject: "terminal:\(agent.id)", urgency: urgency, summary: "\(agent.described) \(what).", project: agent.cwd)
    }
}

extension Initiative {
    /// Takes in a fresh look at the owner's own agents and returns what changed since the last one,
    /// withdrawing anything held about an agent that has moved on.
    func saw(_ agents: [TerminalAgent]) -> [Notice] {
        let found = AgentWatch.notices(agents, before: terminalAgents)
        let standing = Set(agents.map(AgentWatch.key))
        held.removeAll { $0.subject.hasPrefix("terminal:") && !standing.contains($0.key) }
        terminalAgents = agents
        return found
    }
}

extension TerminalAgent {
    /// Which agent, where: "Claude Code in ~/Developer/shop (herdr pane w2:p1)".
    var described: String {
        var at = place.label
        if case .herdr(let pane) = place { at += " pane \(pane)" + (name.map { ", named \($0)" } ?? "") }
        return "\(harness.label) in \((cwd as NSString).abbreviatingWithTildeInPath) (\(at))"
    }

    var line: String {
        let doing = switch state {
        case .working: "working"
        case .blocked: "waiting on an approval or a question"
        case .done: "finished, not looked at yet"
        case .idle: "idle"
        case .unknown: "running"
        }
        return "- \(described): \(doing)"
    }
}
