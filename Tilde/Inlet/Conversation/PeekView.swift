import SwiftUI
import TildeKit

/// tilde saying one thing out of the edge: a reply to what you just said, a
/// heads-up, or a question. Rest the pointer on it to open the conversation.
struct PeekView: View {
    @Environment(AppModel.self) private var model
    var messageID: String
    var actions: InletActions

    var body: some View {
        if let index = model.thread.firstIndex(where: { $0.id == messageID }) {
            let message = model.thread[index]
            HStack(alignment: .top, spacing: 12) {
                TildeMark(mood: mood(message), size: 20).padding(.top, 2)
                VStack(alignment: .leading, spacing: 8) {
                    // A reply carries what it's replying to.
                    if index > 0, model.thread[index - 1].from == .you,
                        message.at.timeIntervalSince(model.thread[index - 1].at) < 120
                    {
                        Text(model.thread[index - 1].text)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(2)
                    }
                    TildeWords(message: message, chips: message.jobs, actions: actions, bubbled: false)
                }
            }
        }
    }

    private func mood(_ message: Message) -> TildeMark.Mood {
        if message.streaming { return .thinking }
        if message.attentionID != nil { return .needsYou }
        if message.trouble { return .failed }
        return .idle
    }
}
