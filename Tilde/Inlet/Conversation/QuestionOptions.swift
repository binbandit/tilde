import SwiftUI
import TildeKit

/// The answers to a question tilde asked, under its words. Its pick is the
/// amber one; for an agent's request, "Always" turns your answer into a standing
/// rule. Anything else, you say in the composer.
struct QuestionOptions: View {
    @Environment(AppModel.self) private var model
    var item: Attention
    /// ⌘↩ answers with tilde's pick (for the question you're looking at).
    var acceptsReturn = false
    var submitted: () -> Void = {}
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
            // Short answers sit in a row; longer ones stack, so no answer ever wraps inside its button.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(item.options.enumerated()), id: \.offset) { index, option in
                        Button(option) { answer(option) }
                            .buttonStyle(OptionStyle(picked: index == item.recommended, stacked: false))
                            .keyboardShortcut(acceptsReturn && index == item.recommended ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    }
                }
                .fixedSize()
                VStack(spacing: 6) {
                    ForEach(Array(item.options.enumerated()), id: \.offset) { index, option in
                        Button(option) { answer(option) }
                            .buttonStyle(OptionStyle(picked: index == item.recommended, stacked: true))
                            .keyboardShortcut(acceptsReturn && index == item.recommended ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    }
                }
            }
            // A worker's request can become a standing rule; tilde's own questions are one-offs.
            if item.requestID != nil {
                Button { always.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: always ? "checkmark.square.fill" : "square")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(always ? Theme.amber : Theme.text3)
                        Text("Always answer this way").font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.top, 1)
            }
        }
    }

    private func answer(_ reply: String) {
        model.answer(item, with: reply, always: always)
        submitted()
    }
}

/// One answer: a pill in a row, or a full-width row of its own when they stack. tilde's pick is filled amber.
private struct OptionStyle: ButtonStyle {
    var picked: Bool
    var stacked: Bool

    func makeBody(configuration: Configuration) -> some View {
        OptionLabel(label: configuration.label, pressed: configuration.isPressed, picked: picked, stacked: stacked)
    }
}

private struct OptionLabel<Label: View>: View {
    var label: Label
    var pressed: Bool
    var picked: Bool
    var stacked: Bool
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: stacked ? 11 : 15, style: .continuous)
        label
            .font(.system(size: 12.5, weight: picked ? .semibold : .medium))
            .foregroundStyle(picked ? .black : Theme.text)
            .lineLimit(stacked ? 2 : 1)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: stacked ? .infinity : nil, alignment: .leading)
            .padding(.horizontal, stacked ? 13 : 12)
            .padding(.vertical, stacked ? 8 : 6)
            .background(picked ? Theme.amber : Color.white.opacity(hovered || pressed ? 0.12 : 0.06), in: shape)
            .overlay(shape.strokeBorder(picked ? .clear : Theme.line, lineWidth: 1))
            .opacity(picked && pressed ? 0.85 : 1)
            .scaleEffect(pressed ? 0.98 : 1)
            .contentShape(shape)
            .onHover { hovered = $0 }
            .animation(Theme.quick, value: pressed)
            .animation(Theme.quick, value: hovered)
    }
}
