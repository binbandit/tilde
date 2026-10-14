import SwiftUI
import TildeKit

/// One of your own agents, running in a terminal. A ring rather than a dot, so it reads as yours
/// rather than tilde's, coloured the same way: amber waiting on you, green finished, white working.
struct TerminalAgentDot: View {
    var agent: TerminalAgent
    var size: CGFloat = 8

    var body: some View {
        Circle().strokeBorder(color, lineWidth: 1.5).frame(width: size, height: size)
    }

    private var color: Color {
        switch agent.state {
        case .blocked: Theme.amber
        case .done: Theme.ready
        case .working: Theme.text
        case .idle, .unknown: Theme.text3
        }
    }

    /// What it's doing, in a word or two. Outside herdr nobody can tell, so it's just running.
    static func words(_ agent: TerminalAgent) -> String {
        switch agent.state {
        case .blocked: "waiting on you"
        case .done: "finished"
        case .working: "working"
        case .idle: "idle"
        case .unknown: "running"
        }
    }
}
