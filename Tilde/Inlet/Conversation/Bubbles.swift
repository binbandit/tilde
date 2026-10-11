import SwiftUI
import TildeKit

/// A message bubble: rounded all round, with a tighter corner on the last of a run, on the
/// speaker's side, like a tail.
nonisolated struct BubbleShape: Shape {
    var mine: Bool
    var tail: Bool

    func path(in rect: CGRect) -> Path {
        let tight: CGFloat = tail ? 5 : 18
        return UnevenRoundedRectangle(
            topLeadingRadius: 18, bottomLeadingRadius: mine ? 18 : tight, bottomTrailingRadius: mine ? tight : 18,
            topTrailingRadius: 18, style: .continuous
        ).path(in: rect)
    }
}

/// tilde writing back: three dots that rise and brighten in turn.
struct TypingBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { dot in
                    let lift = reduceMotion ? 0.4 : Self.lift(t, dot)
                    Circle()
                        .fill(Theme.text)
                        .frame(width: 7, height: 7)
                        .opacity(0.3 + 0.5 * lift)
                        .offset(y: -2.5 * lift)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.bubble, in: BubbleShape(mine: false, tail: true))
        }
        .accessibilityLabel("tilde is replying")
    }

    /// Each dot's rise, 0 to 1, a beat behind the one before.
    private static func lift(_ t: TimeInterval, _ dot: Int) -> Double {
        let phase = (t / 1.2 - Double(dot) * 0.16).truncatingRemainder(dividingBy: 1)
        return phase < 0.5 ? sin(phase * 2 * .pi) : 0
    }
}

/// Under the last thing you said: whether tilde has it yet.
struct Receipt: View {
    @Environment(AppModel.self) private var model
    var message: Message

    var body: some View {
        switch message.delivery {
        case .sent:
            Text("Delivered").receipt()
        case .read(let at):
            Text("Read \(at.formatted(date: .omitted, time: .shortened))").receipt()
        case .failed(let reason):
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10))
                Text("Not delivered").font(.system(size: 11, weight: .medium))
                Text("·").font(.system(size: 11))
                Button("Try again") { model.retry(message) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            .foregroundStyle(Theme.failed)
            .help(reason)
        case nil:
            EmptyView()
        }
    }
}

private extension Text {
    func receipt() -> some View {
        font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3).contentTransition(.opacity)
    }
}
