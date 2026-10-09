import AppKit
import SwiftUI
import TildeKit

/// Quick Look for agent work: what tilde says it did, the diff, and the
/// decisions that bring it home.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    var job: Job
    /// Nearly as tall as the Inlet's edge allows.
    var height: CGFloat
    var onClose: () -> Void
    @State private var diff = ""
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ReviewHeader(job: job, onClose: onClose)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let summary = job.summary {
                        Text(.init(summary))
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    DiffView(patch: diff) { file, line in model.open(job, file: file, line: line) }
                }
                .padding(22)
            }
            .scrollIndicators(.never)
            Rectangle().fill(Theme.line).frame(height: 1)
            footer
        }
        .frame(width: 820, height: height)
        .task {
            diff = await model.diff(job.id)
            await model.refreshPullRequest(job.id)
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Discard") { act { await model.discard(job.id) } }.buttonStyle(.outline(large: true, destructive: true))
            if job.takeOverCommand != nil {
                Button("Take over") { act { await model.takeOver(job) } }.buttonStyle(.outline(large: true))
            }
            OpenInEditor(job: job)
            if let problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.failed).lineLimit(2)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if job.isolation == .scratch {
                Button("Done") { act { await model.dismiss(job.id) } }
                    .buttonStyle(.pill(Theme.ready, large: true))
                    .keyboardShortcut(.defaultAction)
            } else {
                PullRequestButton(job: job, onAsk: onClose)
                Button("Bring it in") { act { try await model.land(job.id) } }
                    .buttonStyle(.pill(Theme.ready, large: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(job.isolation == .inPlace)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private func act(_ work: @escaping () async throws -> Void) {
        busy = true
        problem = nil
        Task {
            do {
                try await work()
                onClose()
            } catch {
                problem = "\(error)"
            }
            busy = false
        }
    }
}

private struct ReviewHeader: View {
    var job: Job
    var onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            StatusDot(phase: job.phase, size: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
                Meta(text: [job.projectName, job.branch, job.harness.label, job.elapsed].compactMap { $0 }.joined(separator: " · "))
            }
            Spacer()
            if let stat = job.diff { DiffBadge(diff: stat) }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.text2)
                    .frame(width: 26, height: 26)
                    .background(Theme.raised, in: .circle)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }
}

/// Opens the job in your editor of choice: the first installed is the default,
/// the rest are a click away.
private struct OpenInEditor: View {
    @Environment(AppModel.self) private var model
    var job: Job

    var body: some View {
        let editors = model.editors(for: job)
        if let first = editors.first {
            Menu {
                ForEach(editors) { editor in
                    Button("Open in \(editor.name)") { model.open(job, in: editor) }
                }
                Divider()
                Button("Show in Finder") { model.reveal(job) }
            } label: {
                Text("Open in \(first.name)")
            } primaryAction: {
                model.open(job, in: first)
            }
            .menuStyle(.button)
            .buttonStyle(.outline(large: true))
            .fixedSize()
        }
    }
}

/// The job's pull request when there is one; otherwise, ask tilde for one.
private struct PullRequestButton: View {
    @Environment(AppModel.self) private var model
    var job: Job
    var onAsk: () -> Void

    var body: some View {
        if let pr = job.pullRequest {
            Button {
                if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: 6) {
                    Text("PR #\(pr.number)")
                    Text(pr.state.lowercased()).foregroundStyle(pr.state == "MERGED" ? Theme.ready : Theme.text3)
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold))
                }
            }
            .buttonStyle(.outline(large: true))
        } else {
            Button("Ask for a PR") {
                model.send("Open a pull request for \(job.id) (\(job.title)) following my conventions.", about: nil)
                onAsk()
            }
            .buttonStyle(.outline(large: true))
        }
    }
}
