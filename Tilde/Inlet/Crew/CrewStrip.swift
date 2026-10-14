import SwiftUI
import TildeKit

/// Every agent working for you, as a dot: white working, amber needs you,
/// green ready, red failed. It stays readable with a dozen agents going.
/// Your own agents in terminals follow as rings. Hover one for what it's doing;
/// click a dot to open that job, or a ring to bring that agent forward.
struct CrewStrip: View {
    @Environment(AppModel.self) private var model
    var actions: InletActions
    @State private var hovered: String?

    private var crew: [Job] { model.crew }
    private var yours: [TerminalAgent] { model.terminalAgents }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 6) {
                ForEach(crew.prefix(16)) { job in
                    dot(job.id, label: "\(job.title), \(JobStatus.words(job))") { actions.openJob(job) } content: {
                        StatusDot(phase: job.phase)
                    }
                }
                if crew.count > 16 { Meta(text: "+\(crew.count - 16)", color: Theme.text3) }
                ForEach(yours.prefix(8)) { agent in
                    dot(agent.id, label: "\(describe(agent)), \(TerminalAgentDot.words(agent))") {
                        model.focus(agent)
                        actions.dismiss()
                    } content: {
                        TerminalAgentDot(agent: agent)
                    }
                }
                if yours.count > 8 { Meta(text: "+\(yours.count - 8)", color: Theme.text3) }
            }
            Text(caption)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovered == nil ? Theme.text3 : Theme.text2)
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .animation(Theme.quick, value: hovered)
    }

    private func dot(_ id: String, label: String, action: @escaping () -> Void, @ViewBuilder content: () -> some View) -> some View {
        Button(action: action) {
            content()
                .padding(3)
                .background(Circle().fill(hovered == id ? Theme.raised : .clear))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
        .accessibilityLabel(label)
    }

    /// "Claude Code in shop".
    private func describe(_ agent: TerminalAgent) -> String {
        "\(agent.harness.label) in \((agent.cwd as NSString).lastPathComponent)"
    }

    /// The crew in a line, or what the hovered agent is doing.
    private var caption: String {
        if let hovered, let job = model.job(hovered) { return "\(job.title): \(job.ticker)" }
        if let hovered, let agent = yours.first(where: { $0.id == hovered }) {
            return "\(describe(agent)): \(TerminalAgentDot.words(agent)) · \(agent.place.label)"
        }
        let working = crew.filter(\.phase.isActive).count - crew.filter { $0.phase == .needsYou }.count
        let needs = crew.filter { $0.phase == .needsYou }.count
        let ready = crew.filter { $0.phase == .ready }.count
        let failed = crew.filter { $0.phase == .failed }.count
        return [working > 0 ? "\(working) working" : nil, needs > 0 ? "\(needs) need\(needs == 1 ? "s" : "") you" : nil,
                ready > 0 ? "\(ready) ready" : nil, failed > 0 ? "\(failed) failed" : nil,
                yours.isEmpty ? nil : "\(yours.count) in your terminals"].compactMap { $0 }.joined(separator: " · ")
    }
}
