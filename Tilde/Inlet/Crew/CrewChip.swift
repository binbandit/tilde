import SwiftUI
import TildeKit

/// A worker, as tilde mentions it: a small chip under what tilde said about
/// the job. Click it to open the job: its agent's conversation and its changes.
struct CrewChip: View {
    var job: Job
    var actions: InletActions
    @State private var hovered = false

    var body: some View {
        Button { actions.openJob(job) } label: {
            HStack(spacing: 7) {
                StatusDot(phase: job.phase, size: 7)
                Text(job.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(job.harness.label).font(.system(size: 11)).foregroundStyle(Theme.text3).lineLimit(1)
                JobStatus(job: job)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .heavy)).foregroundStyle(Theme.text3)
                    .opacity(hovered ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(hovered ? Color.white.opacity(0.12) : Theme.raised, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Theme.quick, value: hovered)
    }
}

/// A job's state in a word or two, coloured only when it means something.
struct JobStatus: View {
    var job: Job

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { _ in
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(color).lineLimit(1)
        }
    }

    private var label: String { Self.words(job) }

    /// A job's state in a word or two.
    static func words(_ job: Job) -> String {
        switch job.phase {
        case .needsYou: "needs you"
        case .ready: "ready"
        case .failed: "failed"
        case .landed: "landed"
        case .stopped: "stopped"
        case .deciding: "deciding"
        case .starting, .working: job.elapsed
        }
    }

    private var color: Color {
        switch job.phase {
        case .needsYou: Theme.amber
        case .ready, .landed: Theme.ready
        case .failed: Theme.failed
        default: Theme.text3
        }
    }
}
