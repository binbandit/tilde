import SwiftUI
import TildeKit

/// Every agent working for you, as a dot: white working, amber needs you,
/// green ready, red failed. It stays readable with a dozen agents going.
/// Hover a dot for what it's doing; click it to open that job.
struct CrewStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(Inlet.self) private var inlet
    var actions: InletActions
    @State private var hovered: String?

    private var crew: [Job] { model.openJobs }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let id = inlet.focusedJob, let job = model.job(id), !mentionedInThread(id) {
                JobDetail(job: job, actions: actions)
                    .transition(.opacity)
            }
            HStack(alignment: .center, spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(crew.prefix(16)) { job in
                        Circle()
                            .fill(Theme.tint(job.phase))
                            .frame(width: 8, height: 8)
                            .padding(3)
                            .background(Circle().fill(hovered == job.id ? Theme.raised : .clear))
                            .contentShape(.circle)
                            .onHover { hovered = $0 ? job.id : (hovered == job.id ? nil : hovered) }
                            .onTapGesture { open(job) }
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
        }
        .animation(Theme.quick, value: hovered)
    }

    /// The crew in a line, or what the hovered agent is doing.
    private var caption: String {
        if let hovered, let job = model.job(hovered) { return "\(job.title): \(job.ticker)" }
        let working = crew.filter(\.phase.isActive).count - crew.filter { $0.phase == .needsYou }.count
        let needs = crew.filter { $0.phase == .needsYou }.count
        let ready = crew.filter { $0.phase == .ready }.count
        return [working > 0 ? "\(working) working" : nil, needs > 0 ? "\(needs) need\(needs == 1 ? "s" : "") you" : nil,
                ready > 0 ? "\(ready) ready" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    private func open(_ job: Job) {
        if job.phase == .ready { return actions.review(job) }
        withAnimation(Theme.spring) { inlet.focusedJob = inlet.focusedJob == job.id ? nil : job.id }
    }

    /// A job already has a chip in the conversation, which expands in place instead.
    private func mentionedInThread(_ id: String) -> Bool {
        model.thread.contains { $0.jobs.contains(id) }
    }
}
