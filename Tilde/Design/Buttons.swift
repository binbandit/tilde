import SwiftUI

/// The one coloured button: amber for "tilde suggests this", green for "bring it in".
struct PillButtonStyle: ButtonStyle {
    var tint: Color
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 13 : 12, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, large ? 16 : 12)
            .padding(.vertical, large ? 7 : 5)
            .background(tint, in: .capsule)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

/// Everything else: white text on a hairline capsule.
struct OutlineButtonStyle: ButtonStyle {
    var large = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 13 : 12, weight: .medium))
            .foregroundStyle(destructive ? Theme.failed : Theme.text)
            .padding(.horizontal, large ? 14 : 11)
            .padding(.vertical, large ? 7 : 5)
            .background(configuration.isPressed ? Color.white.opacity(0.12) : Color.white.opacity(0.06), in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static func pill(_ tint: Color, large: Bool = false) -> PillButtonStyle { PillButtonStyle(tint: tint, large: large) }
}

extension ButtonStyle where Self == OutlineButtonStyle {
    static var outline: OutlineButtonStyle { OutlineButtonStyle() }
    static func outline(large: Bool = false, destructive: Bool = false) -> OutlineButtonStyle {
        OutlineButtonStyle(large: large, destructive: destructive)
    }
}

/// A small round button at the end of a composer: blue, like what you say, to send; quiet to stop.
struct ComposerButton: View {
    var icon: String
    var filled: Bool
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: filled ? 12 : 9, weight: .heavy))
                .foregroundStyle(Theme.text)
                .frame(width: 26, height: 26)
                .background(filled ? Theme.focus : Color.white.opacity(0.14), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
