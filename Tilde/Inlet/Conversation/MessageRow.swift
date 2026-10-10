import SwiftUI
import TildeKit

/// One line of the conversation. tilde speaks plainly on the black; your words
/// sit in a soft well on the other side; workers appear only as chips under
/// what tilde says about them.
struct MessageRow: View {
    var message: Message
    /// The jobs to show as chips here (a job's chip lives on its latest mention).
    var chips: [String]
    var actions: InletActions

    var body: some View {
        switch message.from {
        case .you: YourWords(text: message.text, pointing: message.pointing)
        case .tilde: TildeWords(message: message, chips: chips, actions: actions)
        }
    }
}

struct YourWords: View {
    var text: String
    var pointing: String?
    var pending = false

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 5) {
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(pending ? Theme.text2 : Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.raised, in: .rect(cornerRadius: 14))
                    .contentTransition(.opacity)
                if let pointing { PointingChip(label: pointing) }
            }
        }
    }
}

struct TildeWords: View {
    @Environment(AppModel.self) private var model
    var message: Message
    var chips: [String]
    var actions: InletActions

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // tilde's own mark (in the peek or the header) shows it's thinking; the line just waits.
            if message.streaming, message.text.isEmpty {
                Text("On it…").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text2)
            } else {
                Prose(
                    text: message.text, size: 14, weight: message.attentionID == nil ? .regular : .medium,
                    color: message.trouble ? Theme.failed : Theme.text)
                    .contentTransition(.opacity)
            }
            if let id = message.attentionID, let item = model.attention.first(where: { $0.id == id }) {
                QuestionOptions(item: item)
            }
            ForEach(chips, id: \.self) { jobID in
                if let job = model.job(jobID) { CrewChip(job: job, actions: actions) }
            }
            ForEach(message.noted, id: \.self) { fact in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Noted").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.amber)
                    Text(fact).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(2)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
