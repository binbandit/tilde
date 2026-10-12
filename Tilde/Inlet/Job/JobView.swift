import SwiftUI
import TildeKit

/// A job opened wide: the conversation with its agent (what it was told, said, did and
/// asked), the changes it made, somewhere to talk to it directly, and only the actions
/// that make sense for where it's at.
struct JobView: View {
    @Environment(AppModel.self) private var model
    var job: Job
    var width: CGFloat = 820
    /// Includes the header, transcript and footer.
    var height: CGFloat
    var onClose: () -> Void
    @State private var tab: Tab?
    /// Each tab's content height, kept apart so one on its way out can't size the other.
    @State private var contentHeights: [Tab: CGFloat] = [:]
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    @State private var chromeHeight: CGFloat = 0

    /// The body hugs what it shows, up to what the edge leaves room for.
    private var bodyHeight: CGFloat { max(96, min(contentHeights[shown] ?? 0, height - chromeHeight)) }

    enum Tab { case conversation, changes }

    /// Work waiting for review opens on its changes; anything in progress, on the conversation.
    private var shown: Tab {
        guard job.hasChanges else { return .conversation }
        return tab ?? (job.phase == .ready ? .changes : .conversation)
    }

    var body: some View {
        ScrollView {
            content.fixedSize(horizontal: false, vertical: true)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: width, height: min(height, bodyHeight + chromeHeight))
        .task(id: job.id) { model.loadTranscript(job.id) }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                JobHeader(job: job, tab: Binding { shown } set: { tab = $0 }, compact: width < 620, onClose: onClose)
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chrome(header: $0) }
            Group {
                switch shown {
                case .conversation: JobConversation(job: job, contentHeight: contentHeight(.conversation))
                case .changes: JobChanges(job: job, contentHeight: contentHeight(.changes))
                }
            }
            .frame(height: bodyHeight)
            VStack(spacing: 0) {
                Rectangle().fill(Theme.line).frame(height: 1)
                ScrollView(.horizontal) {
                    JobFooter(job: job, onClose: onClose).frame(width: max(width, 620))
                }
                .scrollBounceBehavior(.basedOnSize)
                .fixedSize(horizontal: false, vertical: true)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chrome(footer: $0) }
        }
        .frame(width: width)
    }
}

extension JobView {
    private func contentHeight(_ tab: Tab) -> Binding<CGFloat> {
        Binding { contentHeights[tab] ?? 0 } set: { contentHeights[tab] = $0 }
    }

    /// The header's and footer's heights, which the body leaves room for.
    private func chrome(header: CGFloat? = nil, footer: CGFloat? = nil) {
        if let header { headerHeight = header }
        if let footer { footerHeight = footer }
        chromeHeight = (headerHeight + footerHeight).rounded(.up)
    }
}

extension Job {
    /// Whether there's a diff to look at: work in a repo that has changed something.
    var hasChanges: Bool { isolation != .scratch && diff?.isEmpty == false }
}

private struct JobHeader: View {
    var job: Job
    @Binding var tab: JobView.Tab
    var compact: Bool
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row
            if compact, job.hasChanges { Tabs(job: job, tab: $tab) }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var row: some View {
        HStack(alignment: .center, spacing: 13) {
            StatusDot(phase: job.phase, size: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 10)) { _ in
                    Meta(text: [job.projectName, job.branch, job.harness.label, job.elapsed].compactMap { $0 }.joined(separator: " · "))
                }
            }
            Spacer(minLength: 16)
            if !compact, job.hasChanges { Tabs(job: job, tab: $tab) }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.text2)
                    .frame(width: 26, height: 26)
                    .background(Theme.raised, in: .circle)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Conversation or changes, ⌘1 and ⌘2.
private struct Tabs: View {
    var job: Job
    @Binding var tab: JobView.Tab
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            item(.conversation, key: "1") { Text("Conversation") }
            item(.changes, key: "2") {
                HStack(spacing: 7) {
                    Text("Changes")
                    if let diff = job.diff { DiffBadge(diff: diff, compact: true) }
                }
            }
        }
        .padding(3)
        .background(Theme.raised, in: .capsule)
        .animation(Theme.quick, value: tab)
    }

    private func item(_ value: JobView.Tab, key: KeyEquivalent, @ViewBuilder label: () -> some View) -> some View {
        Button { tab = value } label: {
            label()
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tab == value ? Theme.text : Theme.text3)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background {
                    if tab == value { Capsule().fill(Color.white.opacity(0.12)).matchedGeometryEffect(id: "tab", in: selection) }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: .command)
    }
}

/// The diff, a click away from your editor.
private struct JobChanges: View {
    @Environment(AppModel.self) private var model
    var job: Job
    @Binding var contentHeight: CGFloat
    @State private var patch = ""

    var body: some View {
        ScrollView {
            DiffView(patch: patch) { file, line in model.open(job, file: file, line: line) }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0.rounded(.up) }
        }
        .scrollIndicators(.never)
        // Starts at the top, and stays there as the diff loads in under it.
        .defaultScrollAnchor(.top)
        // Fresh whenever the agent changes something.
        .task(id: job.diff) {
            patch = await model.diff(job.id)
            await model.refreshPullRequest(job.id)
        }
    }
}

struct DiffBadge: View {
    var diff: DiffStat
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            if !compact { Text("\(diff.files) file\(diff.files == 1 ? "" : "s")").foregroundStyle(Theme.text2) }
            if diff.insertions > 0 || diff.deletions == 0 { Text("+\(diff.insertions)").foregroundStyle(Theme.ready) }
            if diff.deletions > 0 { Text("−\(diff.deletions)").foregroundStyle(Theme.failed) }
        }
        .font(.system(size: compact ? 11 : 12, weight: .semibold, design: .rounded))
        .monospacedDigit()
    }
}
