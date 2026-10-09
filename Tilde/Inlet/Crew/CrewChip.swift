import SwiftUI
import TildeKit

/// A worker, as tilde mentions it: a small chip under what tilde said about
/// the job. Click it to see what it's doing and what you can do about it.
struct CrewChip: View {
    @Environment(Inlet.self) private var inlet
    var job: Job
    var actions: InletActions

    private var expanded: Bool { inlet.focusedJob == job.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Theme.spring) { inlet.focusedJob = expanded ? nil : job.id }
            } label: {
                HStack(spacing: 7) {
                    StatusDot(phase: job.phase, size: 7)
                    Text(job.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(job.harness.label).font(.system(size: 11)).foregroundStyle(Theme.text3).lineLimit(1)
                    JobStatus(job: job)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.raised, in: .capsule)
                .overlay(Capsule().strokeBorder(job.phase == .needsYou ? Theme.amber.opacity(0.5) : .clear, lineWidth: 1))
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)

            if expanded {
                JobDetail(job: job, actions: actions)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
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

    private var label: String {
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
