import SwiftUI
import TildeKit

/// The answers to a question tilde asked, under its words. Its pick is the
/// amber one; "Always" turns your answer into a standing rule. Anything else,
/// you say in the composer.
struct QuestionOptions: View {
    @Environment(AppModel.self) private var model
    var item: Attention
    @State private var always = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Why tilde picked what it picked, marked in its amber.
            if let detail = item.detail, !detail.isEmpty {
                HStack(spacing: 9) {
                    Capsule().fill(Theme.amber.opacity(0.55)).frame(width: 2)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 1)
            }
            HStack(spacing: 6) {
                ForEach(Array(item.options.enumerated()), id: \.offset) { index, option in
                    if index == item.recommended {
                        Button(option) { answer(option) }.buttonStyle(.pill(Theme.amber))
                    } else {
                        Button(option) { answer(option) }.buttonStyle(.outline)
                    }
                }
                Spacer(minLength: 8)
                Toggle(isOn: $always) { Text("Always").font(.system(size: 11)).foregroundStyle(Theme.text2) }
                    .toggleStyle(.checkbox)
            }
        }
    }

    private func answer(_ reply: String) { model.answer(item, with: reply, always: always) }
}
