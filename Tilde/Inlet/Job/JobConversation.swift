import SwiftUI
import TildeKit

/// The conversation with a job's agent. The agent speaks on the left; the brief and every
/// follow-up (tilde's or yours) sit in wells on the right. Its steps fold into one line,
/// and what it asked, who answered, and where each turn ended are marked in between.
struct JobConversation: View {
    @Environment(AppModel.self) private var model
    var job: Job
    /// Reported up so the view can hug a short conversation.
    @Binding var contentHeight: CGFloat

    var body: some View {
        let rows = Row.group(model.transcript(job.id))
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    view(for: row, after: index > 0 ? rows[index - 1] : nil, isLast: index == rows.count - 1,
                         isOpen: isOpen(rows[index...]))
                }
                if let live = liveLine(after: rows.last) { Working(text: live) }
            }
            .padding(22)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0.rounded(.up) }
        }
        .scrollIndicators(.never)
        .followingBottom()
        // Scrolled, lines fade at the edges instead of being sliced; at rest the padding is clear of it.
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 18)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 12)
            }
        }
    }

    /// While nothing new is on screen, what's happening anyway. A run of steps
    /// at the end already shows what the agent is doing.
    private func liveLine(after last: Row?) -> String? {
        switch job.phase {
        case .starting: "\(job.harness.label) is getting started"
        case .deciding: "tilde is looking at it"
        case .working:
            if case .steps? = last { nil } else { "\(job.harness.label) is working" }
        default: nil
        }
    }

    /// A request is open until someone answers it, while the job is still waiting on one.
    private func isOpen(_ rows: ArraySlice<Row>) -> Bool {
        guard [.needsYou, .deciding].contains(job.phase) else { return false }
        return !rows.dropFirst().contains { if case .entry(let entry) = $0 { entry.kind == .decision } else { false } }
    }

    @ViewBuilder private func view(for row: Row, after previous: Row?, isLast: Bool, isOpen: Bool) -> some View {
        switch row {
        case .entry(let entry):
            switch entry.kind {
            case .message where entry.from == .agent:
                AgentWords(name: previous?.isAgentWords == true ? nil : job.harness.label, text: entry.text)
            case .message:
                Direction(entry: entry, agent: job.harness.label, isBrief: previous == nil)
            case .request where entry.from == .agent:
                Marker(icon: "questionmark.circle.fill", tint: isOpen ? Theme.amber : Theme.text3, text: Self.asked(entry.text))
            case .request:
                // tilde passing the agent's question on as it was needs no repeating.
                Marker(
                    icon: "arrow.turn.down.right", tint: isOpen ? Theme.amber : Theme.text3,
                    text: previous?.text == entry.text ? "tilde asked you" : "tilde asked you: \(entry.text)")
            case .decision:
                Marker(
                    icon: entry.text.hasPrefix("denied") ? "xmark.circle.fill" : "checkmark.circle.fill",
                    tint: Theme.text3, text: AttributedString(Self.decided(entry)))
            case .turnEnded:
                TurnEnded(changes: entry.text, at: entry.at)
            case .event, .step:
                Marker(icon: "circle.fill", tint: Theme.text3, text: entry.text, small: true)
            }
        case .steps(let steps):
            Steps(steps: steps, live: job.phase == .working && isLast)
        }
    }
}

extension JobConversation {
    /// What the agent asked, as a sentence: "Asked to run `npm install`". Requests are
    /// recorded as "Tool: what", and a question as itself.
    static func asked(_ request: String) -> AttributedString {
        let parts = request.split(separator: ": ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let verb = verbs[parts[0]] else { return AttributedString("Asked: \(request)") }
        var what = AttributedString((parts[1] as NSString).abbreviatingWithTildeInPath)
        what.font = .system(size: 11.5, weight: .medium, design: .monospaced)
        return AttributedString("Asked to \(verb) ") + what
    }

    private static let verbs = [
        "Bash": "run", "Shell": "run", "Write": "write", "Edit": "edit", "MultiEdit": "edit", "NotebookEdit": "edit",
        "WebFetch": "fetch", "Sandbox": "step outside its sandbox:",
    ]

    /// Who decided a request, and how: "tilde allowed it", "You denied it: not now".
    static func decided(_ entry: JobEntry) -> String {
        let who = entry.from == .you ? "You" : "tilde"
        let text = entry.text
        if text == "allowed" || text == "denied" { return "\(who) \(text) it" }
        // "denied (the reason)"
        if text.hasPrefix("denied ("), text.hasSuffix(")") {
            let reason = text.dropFirst(8).dropLast()
            return reason.isEmpty ? "\(who) denied it" : "\(who) denied it: \(reason)"
        }
        return "\(who) \(text)"
    }
}

/// Transcript entries as shown: runs of steps fold together.
private enum Row: Identifiable {
    case entry(JobEntry)
    case steps([JobEntry])

    var id: String {
        switch self {
        case .entry(let entry): entry.id
        case .steps(let steps): steps[0].id
        }
    }

    /// An entry's words; nil for a run of steps.
    var text: String? {
        if case .entry(let entry) = self { return entry.text }
        return nil
    }

    var isAgentWords: Bool {
        if case .entry(let entry) = self { return entry.from == .agent && entry.kind == .message }
        return false
    }

    static func group(_ entries: [JobEntry]) -> [Row] {
        var rows: [Row] = []
        for entry in entries {
            if entry.kind == .step, case .steps(let run)? = rows.last {
                rows[rows.count - 1] = .steps(run + [entry])
            } else {
                rows.append(entry.kind == .step ? .steps([entry]) : .entry(entry))
            }
        }
        return rows
    }
}

/// The agent talking.
private struct AgentWords: View {
    /// Shown when the agent starts speaking after someone else.
    var name: String?
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let name { Meta(text: name, color: Theme.text3) }
            Prose(text: text)
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}

/// What the agent was told, by tilde or by you. A long brief stays folded until asked for.
private struct Direction: View {
    var entry: JobEntry
    var agent: String
    var isBrief: Bool
    @State private var expanded = false

    private var long: Bool { entry.text.count > 360 || entry.text.split(separator: "\n").count > 6 }

    var body: some View {
        HStack {
            Spacer(minLength: 120)
            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 5) {
                    if entry.from == .tilde { TildeMark(mood: .idle, size: 11) }
                    Meta(text: "\(entry.from == .you ? "You" : "tilde") to \(agent)\(isBrief ? ", the brief" : "")", color: Theme.text3)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Prose(text: entry.text, weight: .medium)
                        .frame(maxHeight: long && !expanded ? 88 : nil, alignment: .top)
                        .mask {
                            LinearGradient(
                                stops: [.init(color: .black, location: 0.6), .init(color: .black.opacity(long && !expanded ? 0 : 1), location: 1)],
                                startPoint: .top, endPoint: .bottom)
                        }
                        .clipped()
                    if long {
                        Button(expanded ? "Show less" : "Show all") { withAnimation(Theme.quick) { expanded.toggle() } }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.text2)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                // Yours in your blue, as in tilde's conversation; tilde's in a quiet well.
                .background(entry.from == .you ? Theme.focus : Theme.raised, in: BubbleShape(mine: true, tail: true))
            }
        }
    }
}

/// A run of steps: the latest, and the rest a click away.
private struct Steps: View {
    var steps: [JobEntry]
    /// The agent is in the middle of the latest one.
    var live: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(Theme.quick) { expanded.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .heavy))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(steps.count == 1 ? "1 step" : "\(steps.count) steps").fontWeight(.semibold)
                    if !expanded, let last = steps.last {
                        Text(last.text).foregroundStyle(live ? Theme.text2 : Theme.text3).lineLimit(1).shimmering(live)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(steps) { step in
                        Text(step.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.text2)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 15)
                .transition(.opacity)
            }
        }
    }
}

/// A small line between the words: a question, a decision, something that happened.
private struct Marker: View {
    var icon: String
    var tint: Color
    var text: AttributedString
    var small = false

    init(icon: String, tint: Color, text: AttributedString, small: Bool = false) {
        (self.icon, self.tint, self.text, self.small) = (icon, tint, text, small)
    }

    init(icon: String, tint: Color, text: String, small: Bool = false) {
        self.init(icon: icon, tint: tint, text: AttributedString(text), small: small)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon).font(.system(size: small ? 5 : 11, weight: .bold)).foregroundStyle(tint)
                .frame(width: 12)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// Where the agent handed back, and what it had changed by then.
private struct TurnEnded: View {
    var changes: String
    var at: Date

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Theme.line).frame(height: 1)
            Meta(
                text: "Turn ended \(at.formatted(date: .omitted, time: .shortened))\(changes.isEmpty ? "" : " · \(changes)")",
                color: Theme.text3)
                .fixedSize()
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

/// Something is happening that the conversation doesn't show yet.
private struct Working: View {
    var text: String

    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.text3).shimmering()
    }
}
