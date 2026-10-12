import SwiftUI
import TildeKit

/// tilde saying one thing out of the edge, like a message arriving: a reply to what you
/// just said (under it), a heads-up, or a question. Rest the pointer on it to open the conversation.
struct PeekView: View {
    @Environment(AppModel.self) private var model
    var messageID: String
    var actions: InletActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                Button(action: actions.minimize) {
                    Image(systemName: "minus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3)
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Minimize chat")
                .accessibilityLabel("Minimize chat")
            }
            message
        }
    }

    @ViewBuilder private var message: some View {
        if let index = model.thread.firstIndex(where: { $0.id == messageID }), model.thread[index].from == .you {
            // Something you said that didn't get through, with its way to try again.
            YourWords(text: model.thread[index].text, at: model.thread[index].at, receipt: model.thread[index])
        } else if let index = model.thread.firstIndex(where: { $0.id == messageID }) {
            let message = model.thread[index]
            VStack(alignment: .leading, spacing: 6) {
                // A reply comes with what it's replying to, and, until it starts, whether tilde has it.
                if index > 0, model.thread[index - 1].from == .you, message.at.timeIntervalSince(model.thread[index - 1].at) < 120 {
                    let said = model.thread[index - 1]
                    YourWords(text: said.text, at: said.at, receipt: message.text.isEmpty ? said : nil)
                }
                HStack(alignment: .top, spacing: 8) {
                    TildeMark(mood: mood(message), size: 18).padding(.top, 12)
                        .contentShape(.rect)
                        .onTapGesture { actions.compose() }
                        .help("Open the conversation")
                    // A long reply shows its start; resting the pointer on it opens the whole conversation.
                    let long = message.text.count > 600 || message.text.split(separator: "\n").count > 12
                    TildeWords(message: message, chips: message.jobs, actions: actions)
                        .frame(maxHeight: long ? 280 : nil, alignment: .top)
                        .mask {
                            LinearGradient(
                                stops: [.init(color: .black, location: 0.75), .init(color: .black.opacity(long ? 0 : 1), location: 1)],
                                startPoint: .top, endPoint: .bottom)
                        }
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
