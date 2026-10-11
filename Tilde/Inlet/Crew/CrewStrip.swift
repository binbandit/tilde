import SwiftUI
import TildeKit

/// Every agent working for you, as a dot: white working, amber needs you,
/// green ready, red failed. It stays readable with a dozen agents going.
/// Hover a dot for what it's doing; click it to open that job.
struct CrewStrip: View {
    @Environment(AppModel.self) private var model
    var actions: InletActions
    @State private var hovered: String?

    private var crew: [Job] { model.crew }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(crew.prefix(16)) { job in
                    Button { actions.openJob(job) } label: {
                        StatusDot(phase: job.phase)
                            .padding(3)
                            .background(Circle().fill(hovered == job.id ? Theme.raised : .clear))
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? job.id : (hovered == job.id ? nil : hovered) }
                    .accessibilityLabel("\(job.title), \(JobStatus.words(job))")
                }
                if crew.count > 16 { Meta(text: "+\(crew.count - 16)", color: Theme.text3) }
            }
            Text(caption)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovered == nil ? Theme.text3 : Theme.text2)
                .lineLimit(1)
                .contentTransition(.opacity)
            Spacer(minLength: 0)
        }
        .animation(Theme.quick, value: hovered)
    }

    /// The crew in a line, or what the hovered agent is doing.
    private var caption: String {
        if let hovered, let job = model.job(hovered) { return "\(job.title): \(job.ticker)" }
        let working = crew.filter(\.phase.isActive).count - crew.filter { $0.phase == .needsYou }.count
        let needs = crew.filter { $0.phase == .needsYou }.count
        let ready = crew.filter { $0.phase == .ready }.count
        let failed = crew.filter { $0.phase == .failed }.count
        return [working > 0 ? "\(working) working" : nil, needs > 0 ? "\(needs) need\(needs == 1 ? "s" : "") you" : nil,
                ready > 0 ? "\(ready) ready" : nil, failed > 0 ? "\(failed) failed" : nil].compactMap { $0 }.joined(separator: " · ")
    }

}
