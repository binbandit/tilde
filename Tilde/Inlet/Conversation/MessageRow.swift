import SwiftUI
import TildeKit

/// One line of the conversation, like a text thread: tilde on the left in grey, you on the right
/// in blue. What hangs off tilde's words (a question's answers, the jobs it's about, what it noted)
/// sits under its bubble.
struct MessageRow: View {
    var message: Message
    /// The jobs to show as chips here (a job's chip lives on its latest mention).
    var chips: [String]
    var actions: InletActions
    /// The last of a run from the same side, whose bubble gets the tail.
    var tail = true
    /// Whether to say if tilde has it yet (under the last thing you said).
    var receipt = false

    var body: some View {
        switch message.from {
        case .you:
            YourWords(text: message.text, pointing: message.pointing, tail: tail, at: message.at, receipt: receipt ? message : nil)
        case .tilde:
            TildeWords(message: message, chips: chips, actions: actions, tail: tail)
        }
    }
}

struct YourWords: View {
    var text: String
    var pointing: String?
    /// Still being said (while you hold the key).
    var pending = false
    var tail = true
    var at: Date?
    /// Said, with whether tilde has it.
    var receipt: Message?

    var body: some View {
        HStack {
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: 5) {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text.opacity(pending ? 0.75 : 1))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(Theme.focus.opacity(pending ? 0.4 : 1), in: BubbleShape(mine: true, tail: tail))
                    .contentTransition(.opacity)
                    .help(at?.formatted(date: .omitted, time: .shortened) ?? "")
                if let pointing { PointingChip(label: pointing) }
                if let receipt { Receipt(message: receipt).padding(.trailing, 6).transition(.opacity) }
            }
        }
    }
}

struct TildeWords: View {
    @Environment(AppModel.self) private var model
    var message: Message
    var chips: [String]
    var actions: InletActions
    var tail = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.streaming, message.text.isEmpty {
                writing
            } else {
                HStack(spacing: 0) {
                    words
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(Theme.bubble.opacity(message.settled == nil ? 1 : 0.55), in: BubbleShape(mine: false, tail: tail))
                        .help(message.at.formatted(date: .omitted, time: .shortened))
                    Spacer(minLength: 40)
                }
            }
            if let id = message.attentionID, let item = model.attention.first(where: { $0.id == id }) {
                QuestionOptions(item: item, acceptsReturn: model.openQuestion?.id == id)
            }
            if let settled = message.settled {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                    Text("No longer needed: \(settled)").font(.system(size: 12)).lineLimit(2)
                }
                .foregroundStyle(Theme.text3)
                .padding(.leading, 6)
                .transition(.opacity)
            }
            ForEach(chips, id: \.self) { jobID in
                if let job = model.job(jobID) { CrewChip(job: job, actions: actions) }
            }
            ForEach(message.noted, id: \.self) { fact in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "bookmark.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.text3)
                    Text("Noted").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text2)
                    Text(fact).font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(2)
                }
                .padding(.leading, 6)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var words: some View {
        Prose(
            text: message.text, size: 14, weight: message.attentionID == nil ? .regular : .medium,
            color: message.trouble ? Theme.failed : message.settled == nil ? Theme.text : Theme.text2)
            .contentTransition(.opacity)
    }

    /// Nothing said yet: the dots, and what tilde is doing meanwhile.
    @ViewBuilder private var writing: some View {
        TypingBubble()
        if let activity = message.activity {
            Text("\(activity)…")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text3)
                .shimmering()
                .padding(.leading, 6)
                .contentTransition(.opacity)
                .animation(Theme.quick, value: message.activity)
        }
    }
}

/// What "this" referred to.
struct PointingChip: View {
    var label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "scope").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.focus)
            Meta(text: label)
        }
    }
}
