import SwiftUI
import TildeKit

/// What a worker is doing right now, and the obvious things you can do about it.
struct JobDetail: View {
    @Environment(AppModel.self) private var model
    var job: Job
    var actions: InletActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Meta(text: "\(job.projectName) · \(job.branch ?? job.isolation.rawValue)", color: Theme.text3)
            if job.phase == .ready, let summary = job.summary {
                Text(summary).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(job.ticker).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(2)
                    .contentTransition(.opacity)
                    .animation(Theme.quick, value: job.ticker)
            }
            HStack(spacing: 6) {
                if let diff = job.diff, !diff.isEmpty { DiffBadge(diff: diff) }
                Spacer(minLength: 6)
                if job.takeOverCommand != nil, job.phase.isOpen {
                    Button("Take over") { Task { await model.takeOver(job) } }.buttonStyle(.outline)
                }
                if job.phase == .ready || job.phase == .needsYou || job.diff?.isEmpty == false {
                    Button("Review") { actions.review(job) }.buttonStyle(.pill(job.phase == .ready ? Theme.ready : Theme.text2))
                }
            }
        }
        .padding(12)
        .background(Theme.raised.opacity(0.6), in: .rect(cornerRadius: 14))
    }
}

struct DiffBadge: View {
    var diff: DiffStat

    var body: some View {
        HStack(spacing: 6) {
            Text("\(diff.files) file\(diff.files == 1 ? "" : "s")").foregroundStyle(Theme.text2)
            Text("+\(diff.insertions)").foregroundStyle(Theme.ready)
            Text("−\(diff.deletions)").foregroundStyle(Theme.failed)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .monospacedDigit()
    }
}
