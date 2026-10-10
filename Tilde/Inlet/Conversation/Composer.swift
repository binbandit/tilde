import SwiftUI
import TildeKit

/// Where you talk to tilde when you're typing. When tilde has asked something,
/// what you type answers it, unless you say otherwise.
struct Composer: View {
    @Environment(AppModel.self) private var model
    var referent: Referent?
    /// True after a tap of the tilde key: start typing straight away.
    var focused: Bool
    var actions: InletActions
    @FocusState private var hasFocus: Bool
    /// You've chosen to say something new rather than answer the open question.
    @State private var newMessage = false

    private var answering: Attention? { newMessage ? nil : model.openQuestion }
    private var typed: Bool { !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 7) {
            if let answering {
                HStack(spacing: 6) {
                    Text("Answering").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.amber)
                    Text(answering.question).font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(1)
                    Spacer(minLength: 6)
                    Button("New message") { newMessage = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.text3)
                }
                .padding(.top, 3)
                .padding(.trailing, 5)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("", text: $model.draft, prompt: Text(answering == nil ? "Tell tilde…" : "Your answer…").foregroundStyle(Theme.text3), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1...6)
                    .focused($hasFocus)
                    .onSubmit(submit)
                    .onKeyPress(.escape) {
                        actions.dismiss()
                        return .handled
                    }
                    .padding(.vertical, 3)
                if typed {
                    ComposerButton(icon: "arrow.up", filled: true, help: answering == nil ? "Send to tilde" : "Answer", action: submit)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(minHeight: 26)
            .animation(Theme.quick, value: typed)
            if let referent { PointingChip(label: referent.label) }
        }
        .padding(.leading, 13)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Theme.raised, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(hasFocus ? Theme.line : .clear, lineWidth: 1))
        .contentShape(.rect)
        // The open Inlet doesn't hold the keyboard until you reach for the composer.
        .onTapGesture {
            actions.compose()
            hasFocus = true
        }
        .onAppear { if focused { hasFocus = true } }
        .onChange(of: focused) { _, now in if now { hasFocus = true } }
        .onChange(of: model.openQuestion?.id) { newMessage = false }
    }

    private func submit() {
        let text = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.draft = ""
        if let answering {
            model.answer(answering, with: text)
        } else {
            actions.send(text)
        }
    }
}
