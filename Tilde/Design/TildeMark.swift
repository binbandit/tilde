import SwiftUI

/// The living `~`. It's tilde's face everywhere: it breathes when idle,
/// travels while agents work, follows your voice while you talk, glows amber
/// when something needs you, and settles green when work is ready.
struct TildeMark: View {
    enum Mood: Equatable {
        case idle, working, thinking, needsYou, done, failed
        case listening(level: Double)
    }

    var mood: Mood
    var size: CGFloat = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Wave(phase: phase(t), amplitude: amplitude(t))
                .stroke(color, style: StrokeStyle(lineWidth: max(1.6, size * 0.13), lineCap: .round, lineJoin: .round))
                .shadow(color: glow, radius: size * 0.4)
        }
        .frame(width: size, height: size * 0.62)
        .animation(Theme.spring, value: mood)
        .accessibilityLabel("tilde")
    }

    private var color: Color {
        switch mood {
        case .needsYou: Theme.amber
        case .done: Theme.ready
        case .failed: Theme.failed
        default: Theme.text
        }
    }

    private var glow: Color {
        switch mood {
        case .needsYou: Theme.amber.opacity(0.75)
        case .done: Theme.ready.opacity(0.5)
        default: .clear
        }
    }

    /// How far along its cycle the wave is; it travels while work happens.
    private func phase(_ t: Double) -> Double {
        switch mood {
        case .working: t * 2.6
        case .thinking: t * 5.2
        case .listening: t * 3.4
        default: 0
        }
    }

    private func amplitude(_ t: Double) -> Double {
        switch mood {
        case .idle: 0.78 + 0.12 * sin(t * 1.4)
        case .working, .thinking: 0.85
        case .listening(let level): 0.35 + 0.65 * min(1, level * 1.6) + 0.06 * sin(t * 9)
        case .needsYou: 0.9 + 0.1 * sin(t * 4)
        case .done: 0.55
        case .failed: 0.4
        }
    }
}

/// One period of a sine wave across the rect: the shape of `~`.
nonisolated struct Wave: Shape {
    var phase: Double
    var amplitude: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(phase, amplitude) }
        set { (phase, amplitude) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 48
        let inset = rect.height * 0.12
        let mid = rect.midY, reach = (rect.height / 2 - inset) * amplitude
        for i in 0...steps {
            let x = Double(i) / Double(steps)
            // A pure "~": up first, then down, then back up at the end.
            let y = mid - reach * sin(2 * .pi * x - phase)
            let point = CGPoint(x: rect.minX + rect.width * x, y: y)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
