import SwiftUI

extension View {
    /// Light passing over the view, now and then, while what it says is still happening.
    func shimmering(_ active: Bool = true) -> some View { modifier(Shimmer(active: active)) }
}

private struct Shimmer: ViewModifier {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active, !reduceMotion {
            content.overlay {
                content
                    .foregroundStyle(Theme.text)
                    .keyframeAnimator(initialValue: -0.4, repeating: true) { view, x in
                        view.mask {
                            LinearGradient(
                                colors: [.clear, .white, .clear],
                                startPoint: UnitPoint(x: x - 0.35, y: 0.5), endPoint: UnitPoint(x: x + 0.35, y: 0.5))
                        }
                    } keyframes: { _ in
                        LinearKeyframe(1.4, duration: 1.7, timingCurve: .easeInOut)
                        // A breath between passes, so it reads as alive rather than busy.
                        LinearKeyframe(1.4, duration: 0.7)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        } else {
            content
        }
    }
}
