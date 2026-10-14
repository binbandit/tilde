import AppKit
import SwiftUI
import TildeKit

/// The bottom of a job: what's waiting on you, somewhere to talk to the agent, and the
/// actions that fit where the job is at. Nothing to land while it's still working;
/// nothing to stop once it's done.
struct JobFooter: View {
    @Environment(AppModel.self) private var model
    var job: Job
    var onClose: () -> Void
    @State private var busy = false
    @State private var problem: String?
    /// Discard was clicked once: the next click deletes the branch and the worktree.
    @State private var discarding = false

    /// The worktree (or scratch folder) is still there to open, take over or discard.
    private var hasWorkdir: Bool { FileManager.default.fileExists(atPath: job.workdir) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let question = model.question(for: job.id) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.question).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    QuestionOptions(item: question)
                }
            }
            if !job.phase.isSettled {
                AgentComposer(job: job, answering: model.question(for: job.id), problem: $problem) {
                    act(closing: false) { await model.stop(job) }
                }
            }
            if hasActions {
                HStack(spacing: 8) {
                    secondary.disabled(busy)
                    if let problem {
                        Text(problem).font(.system(size: 12)).foregroundStyle(Theme.failed).lineLimit(2)
                    }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    primary.disabled(busy)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    /// Anything for the row under the composer: the work's own actions, or how one went.
    private var hasActions: Bool { hasWorkdir || job.phase == .ready || job.phase.isSettled || busy || problem != nil }

    @ViewBuilder private var secondary: some View {
        if hasWorkdir, job.canDiscard {
            // Nothing brings a discarded branch back, so it takes a second click.
            Button(discarding ? "Delete \(job.branch ?? "the work")?" : "Discard") {
                guard discarding else {
                    discarding = true
                    Task {
                        try? await Task.sleep(for: .seconds(4))
                        discarding = false
                    }
                    return
                }
                act { try await model.discard(job.id) }
            }
            .buttonStyle(.outline(large: true, destructive: true))
            .animation(Theme.quick, value: discarding)
        }
        if job.takeOverCommand != nil, hasWorkdir, !job.phase.isSettled {
            Button("Take over") { act { await model.takeOver(job) } }.buttonStyle(.outline(large: true))
        }
        if hasWorkdir { OpenInEditor(job: job) }
    }

    @ViewBuilder private var primary: some View {
        switch job.phase {
        case .ready where job.reviewAction == .acknowledge:
            // A verified no-change result needs acknowledgement, as do scratch and in-place jobs.
            Button("Done") { act { try await model.dismiss(job.id) } }
                .buttonStyle(.pill(Theme.ready, large: true))
                .keyboardShortcut(.return, modifiers: .command)
        case .ready:
            if let pr = job.pullRequest { PullRequestLink(pr: pr) }
            if job.reviewAction == .bringIn {
                Button { act { try await model.land(job.id) } } label: {
                    HStack(spacing: 6) {
                        Text("Bring it in")
                        Text("⌘↩").font(.system(size: 11, weight: .semibold)).opacity(0.55)
                    }
                }
                .buttonStyle(.pill(Theme.ready, large: true))
                .keyboardShortcut(.return, modifiers: .command)
            }
        case .landed, .done:
            if let pr = job.pullRequest { PullRequestLink(pr: pr) }
            Meta(text: job.ticker, color: Theme.ready)
        default:
            EmptyView()
        }
    }

    private func act(closing: Bool = true, _ work: @escaping () async throws -> Void) {
        busy = true
        problem = nil
        Task {
            do {
                try await work()
                if closing { onClose() }
            } catch {
                problem = "\(error)"
            }
            busy = false
        }
    }
}

/// Talking to the agent directly. tilde hears it too. When the agent's waiting on an
/// answer from you, what you type answers it, unless you say otherwise. While it works,
/// the button at the end stops it; once you've typed something, it sends.
private struct AgentComposer: View {
    @Environment(AppModel.self) private var model
    var job: Job
    var answering: Attention?
    @Binding var problem: String?
    var stop: () -> Void
    @State private var text = ""
    @State private var newMessage = false
    @FocusState private var focused: Bool

    private var question: Attention? { newMessage ? nil : answering }
    private var typed: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var prompt: String {
        if question != nil { return "Your answer…" }
        return switch job.phase {
        case .stopped, .failed: "Tell \(job.harness.label) how to carry on…"
        case .ready: "Ask \(job.harness.label) for changes…"
        default: "Message \(job.harness.label)…"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if question != nil {
                HStack(spacing: 6) {
                    Text("Answering").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.amber)
                    Spacer(minLength: 6)
                    Button("Message \(job.harness.label) instead") { newMessage = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.text2)
                    // Stop stays in reach while you answer, named, so it can't be mistaken for sending.
                    if job.phase.isActive {
                        Button("Stop", action: stop)
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.failed)
                    }
                }
                .padding(.top, 3)
                .padding(.trailing, 5)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.text3), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.vertical, 3)
                trailing
            }
            .frame(minHeight: 26)
            .animation(Theme.quick, value: typed)
        }
        .padding(.leading, 13)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Theme.raised, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(focused ? Theme.line : .clear, lineWidth: 1))
        .contentShape(.rect)
        .onTapGesture { focused = true }
        .onAppear { focused = true }
        .onChange(of: answering?.id) { newMessage = false }
    }

    @ViewBuilder private var trailing: some View {
        if typed {
            ComposerButton(icon: "arrow.up", filled: true, help: question == nil ? "Send to \(job.harness.label)" : "Answer", action: send)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        } else if job.phase.isActive, question == nil {
            // Not while you're answering, where a round button at the end would read as Send.
            ComposerButton(icon: "stop.fill", filled: false, help: "Stop \(job.harness.label)", action: stop)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    private func send() {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        text = ""
        if let question {
            model.answer(question, with: words)
            return
        }
        Task {
            do {
                try await model.message(job, words)
            } catch {
                problem = "Couldn't reach \(job.harness.label): \(error)"
                text = words
            }
        }
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

/// The job's pull request, once there is one. Asking for one is just something you say.
private struct PullRequestLink: View {
    var pr: PullRequest

    var body: some View {
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
    }
}
