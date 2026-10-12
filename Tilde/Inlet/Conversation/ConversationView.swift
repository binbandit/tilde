import SwiftUI
import TildeKit

/// The open Inlet: today's conversation with tilde, the crew working for it,
/// and somewhere to say the next thing.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @Environment(Inlet.self) private var inlet
    var referent: Referent?
    var maxHeight: CGFloat
    var actions: InletActions
    @State private var threadHeight: CGFloat = 0
    @State private var chromeHeight: CGFloat = 0
    @State private var confirmClear = false

    private var history: ConversationVisibility { inlet.history }
    private var allMessages: [Message] { model.earlier + model.thread }
    private var questions: Set<String> { Set(model.attention.map(\.id)) }
    private var protected: Set<String> { history.protectedIDs(in: allMessages, questions: questions) }
    private var shownThread: [Message] { history.visible(model.thread, protecting: protected) }
    private var shownEarlier: [Message] { history.visible(model.earlier, protecting: protected) }
    private var maxThread: CGFloat { max(80, maxHeight - chromeHeight - 14) }

    var body: some View {
        // Normally only the transcript scrolls. On a very short display,
        // scroll the whole surface so the composer and every control remain reachable.
        ScrollView {
            conversation.fixedSize(horizontal: false, vertical: true)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(maxHeight, threadHeight + chromeHeight + 14))
        .confirmationDialog("Clear completed chat messages?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear chat") { history.clear(allMessages, questions: questions) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Running work, pending replies and questions stay available. You can restore cleared messages from the chat menu.")
        }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0; measureChrome() }
            thread
            VStack(alignment: .leading, spacing: 14) {
                if !model.crew.isEmpty { CrewStrip(actions: actions) }
                if inlet.mode != .listening {
                    Composer(referent: referent, focused: inlet.mode == .compose, actions: actions)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0; measureChrome() }
        }
    }

    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    private func measureChrome() {
        chromeHeight = (headerHeight + footerHeight + 14).rounded(.up)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TildeMark(mood: mood, size: 20)
            Text("tilde").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            Spacer()
            // Settings, for the times you need them, without hunting for a right-click.
            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3)
            }
            .buttonStyle(.plain)
            .help("Settings")
            Menu {
                Button("Clear chat…") { confirmClear = true }
                    .disabled(!history.canClear(allMessages, questions: questions))
                Button("Restore cleared messages") { history.restore() }
                    .disabled(history.hidden.isEmpty)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Chat history")
            .accessibilityLabel("Chat history")
            Button(action: actions.minimize) {
                Image(systemName: "minus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Minimize chat")
            .accessibilityLabel("Minimize chat")
        }
    }

    /// The conversation hugs its content until it's tall, then scrolls, newest at the bottom.
    private var thread: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The end of the last conversation, a scroll away, so the day picks up where it left off.
                if !shownEarlier.isEmpty {
                    ForEach(Array(shownEarlier.enumerated()), id: \.element.id) { index, message in
                        let gap = Self.gap(before: index, in: shownEarlier)
                        if let gap { Separator(text: gap, first: index == 0) }
                        MessageRow(message: message, chips: [], actions: actions, tail: !joins(index + 1, in: shownEarlier))
                            .padding(.top, gap != nil || index == 0 ? 0 : joins(index, in: shownEarlier) ? 3 : 12)
                    }
                    // A question carried over from an earlier day labels itself; "Today" heads the first of today's.
                    if !(shownThread.first.map { !Calendar.current.isDateInToday($0.at) } ?? false) {
                        Separator(text: shownThread.first.map { "Today \($0.at.formatted(date: .omitted, time: .shortened))" } ?? "Today", first: false)
                    }
                }
                // If tilde couldn't start, it says so where you'd talk to it.
                if let error = model.startupError {
                    MessageRow(message: Message(from: .tilde, text: "I couldn't start: \(error)", trouble: true), chips: [], actions: actions)
                        .padding(.bottom, 12)
                }
                if shownThread.isEmpty, model.listening == nil {
                    Greeting(actions: actions)
                }
                let chips = chips
                let receipts = receipts
                ForEach(Array(shownThread.enumerated()), id: \.element.id) { index, message in
                    // With the last conversation above, "Today" has already said when this one started.
                    let headed = index == 0 && !shownEarlier.isEmpty && Calendar.current.isDateInToday(message.at)
                    let gap = headed ? nil : Self.gap(before: index, in: shownThread).map { label in
                        // The first of today's after a carried-over question still says it's today.
                        index > 0 && !shownEarlier.isEmpty && Calendar.current.isDateInToday(message.at)
                            && !Calendar.current.isDateInToday(shownThread[index - 1].at) ? "Today \(label)" : label
                    }
                    if let gap { Separator(text: gap, first: index == 0) }
                    MessageRow(
                        message: message, chips: chips[message.id] ?? [], actions: actions,
                        tail: !joins(index + 1, in: shownThread, chips: chips, receipts: receipts), receipt: receipts.contains(index))
                        // A run from one side sits close together; a new speaker gets room.
                        .padding(.top, gap != nil || index == 0 ? 0 : joins(index, in: shownThread, chips: chips, receipts: receipts) ? 3 : 12)
                }
                if let listening = model.listening {
                    ListeningRow(listening: listening, referent: referent).padding(.top, shownThread.isEmpty ? 0 : 12)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { threadHeight = $0.rounded(.up) }
        }
        .scrollIndicators(.never)
        .followingBottom()
        .frame(height: min(threadHeight, maxThread))
        // Once it scrolls, older lines fade under the header instead of being sliced.
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: threadHeight > maxThread ? 32 : 0)
                Rectangle()
            }
        }
    }

    /// Each job's chip sits under the latest thing tilde said about it, so its
    /// current state is near the bottom and never repeated.
    private var chips: [String: [String]] {
        var latest: [String: String] = [:]
        for message in shownThread where message.from == .tilde {
            for job in message.jobs { latest[job] = message.id }
        }
        return Dictionary(grouping: latest.keys, by: { latest[$0]! }).mapValues { ids in
            ids.sorted()
        }
    }

    /// Your messages that say whether tilde has them: the last one, until tilde answers, and any that never got through.
    private var receipts: Set<Int> {
        let thread = shownThread
        var shown = Set(thread.indices.filter { if case .failed = thread[$0].delivery { true } else { false } })
        if let last = thread.lastIndex(where: { $0.from == .you }),
            thread[(last + 1)...].allSatisfy({ $0.from == .tilde && $0.text.isEmpty })
        {
            shown.insert(last)
        }
        return shown
    }

    /// Whether the message at `index` carries on a run from the one before: same side, no time
    /// between them, and nothing hanging off the earlier one.
    private func joins(_ index: Int, in thread: [Message], chips: [String: [String]] = [:], receipts: Set<Int> = []) -> Bool {
        guard index > 0, index < thread.count, Self.gap(before: index, in: thread) == nil else { return false }
        let previous = thread[index - 1], message = thread[index]
        guard previous.from == message.from, !(message.streaming && message.text.isEmpty) else { return false }
        switch previous.from {
        case .you: return previous.pointing == nil && !receipts.contains(index - 1)
        case .tilde:
            return previous.attentionID == nil && previous.settled == nil && previous.noted.isEmpty
                && (chips[previous.id] ?? []).isEmpty && !(previous.streaming && previous.text.isEmpty)
        }
    }

    private var mood: TildeMark.Mood {
        if model.listening != nil { return .listening(level: model.listening?.level ?? 0) }
        if model.thread.last?.streaming == true { return .thinking }
        if !model.attention.isEmpty { return .needsYou }
        if model.crew.contains(where: { $0.phase.isActive }) { return .working }
        return .idle
    }

    /// A time between messages more than half an hour apart, with the day for anything
    /// from before today ("Yesterday 6:11 PM").
    static func gap(before index: Int, in thread: [Message]) -> String? {
        let at = thread[index].at
        guard index == 0 || at.timeIntervalSince(thread[index - 1].at) > 30 * 60 else { return nil }
        let time = at.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(at) { return time }
        if Calendar.current.isDateInYesterday(at) { return "Yesterday \(time)" }
        return at.formatted(.dateTime.weekday(.wide).hour().minute())
    }
}

/// When the conversation picks up again: centred, small, out of the way.
private struct Separator: View {
    var text: String
    var first: Bool

    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3)
            .frame(maxWidth: .infinity)
            .padding(.top, first ? 0 : 18)
            .padding(.bottom, 10)
    }
}

/// What tilde says when there's nothing yet today, with a few things to ask it, one click away.
private struct Greeting: View {
    @AppStorage("trigger") private var trigger = Trigger.doubleOption.rawValue
    var actions: InletActions

    private let suggestions = ["What's waiting on me?", "How are my PRs?", "What did I get done yesterday?"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                Text("Hi \(Owner.firstName). What can I take off your plate?")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(Theme.bubble, in: BubbleShape(mine: false, tail: true))
                Spacer(minLength: 40)
            }
            Text("Point at something and \((Trigger(rawValue: trigger) ?? .doubleOption).hint).")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text3)
                .padding(.leading, 6)
            FlowLayout {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) { actions.send(suggestion) }.buttonStyle(.outline)
                }
            }
            .padding(.top, 2)
        }
    }
}

/// Your words, appearing as you say them.
private struct ListeningRow: View {
    var listening: AppModel.Listening
    var referent: Referent?

    var body: some View {
        YourWords(
            text: listening.transcript.isEmpty ? "Listening…" : listening.transcript, pointing: referent?.label,
            pending: true)
    }
}
