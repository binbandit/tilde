import SwiftUI
import TildeKit

/// The open Inlet: today's conversation with tilde, the crew working for it,
/// and somewhere to say the next thing.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @Environment(Inlet.self) private var inlet
    var referent: Referent?
    var maxThread: CGFloat
    var actions: InletActions
    @State private var threadHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            thread
            if !model.jobs.isEmpty { CrewStrip(actions: actions) }
            // While you're talking, your words are the pending message above.
            if inlet.mode != .listening {
                Composer(referent: referent, focused: inlet.mode == .compose, actions: actions)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TildeMark(mood: mood, size: 20)
            Text("tilde").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            Spacer()
            Meta(text: Date.now.formatted(.dateTime.weekday(.wide)), color: Theme.text3)
        }
    }

    /// The conversation hugs its content until it's tall, then scrolls, newest at the bottom.
    private var thread: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.thread.isEmpty, model.listening == nil {
                    Greeting()
                }
                ForEach(Array(model.thread.enumerated()), id: \.element.id) { index, message in
                    if let gap = Self.gap(before: index, in: model.thread) {
                        Text(gap).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3)
                            .frame(maxWidth: .infinity)
                    }
                    MessageRow(message: message, chips: chips[message.id] ?? [], actions: actions)
                }
                if let listening = model.listening {
                    ListeningRow(listening: listening, referent: referent)
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
        for message in model.thread where message.from == .tilde {
            for job in message.jobs { latest[job] = message.id }
        }
        return Dictionary(grouping: latest.keys, by: { latest[$0]! }).mapValues { ids in
            ids.sorted()
        }
    }

    private var mood: TildeMark.Mood {
        if model.listening != nil { return .listening(level: model.listening?.level ?? 0) }
        if model.thread.last?.streaming == true { return .thinking }
        if !model.attention.isEmpty { return .needsYou }
        if model.openJobs.contains(where: { $0.phase.isActive }) { return .working }
        return .idle
    }

    /// A time between messages more than half an hour apart, with the day for questions
    /// still waiting from an earlier one.
    static func gap(before index: Int, in thread: [Message]) -> String? {
        let at = thread[index].at
        guard index == 0 || at.timeIntervalSince(thread[index - 1].at) > 30 * 60 else { return nil }
        return Calendar.current.isDateInToday(at)
            ? at.formatted(date: .omitted, time: .shortened) : at.formatted(.dateTime.weekday(.wide).hour().minute())
    }
}

/// What tilde says when there's nothing yet today.
private struct Greeting: View {
    @AppStorage("trigger") private var trigger = Trigger.doubleOption.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Hi \(Owner.firstName). What can I take off your plate?")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.text)
            Text("Point at something and \((Trigger(rawValue: trigger) ?? .doubleOption).hint).")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
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
