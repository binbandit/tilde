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
            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(3)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.raised, in: .rect(cornerRadius: 8))
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
