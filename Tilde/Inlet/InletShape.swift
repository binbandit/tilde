import SwiftUI

/// The Inlet's outline, drawn from the bezel: a rounded tab `depth` in from the edge and
/// `length` along it, centred along the edge of whatever rect it's given (the whole panel),
/// with concave "ears" where it meets the bezel so it reads as part of the display.
///
/// Because its base is the bezel itself, it can grow, shrink and bounce however it likes
/// and never come away from the screen's edge.
nonisolated struct InletShape: Shape, Equatable {
    var edge: InletEdge
    var depth: CGFloat
    var length: CGFloat
    var radius: CGFloat
    var ear: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(depth, length), AnimatablePair(radius, ear)) }
        set { (depth, length, radius, ear) = (newValue.first.first, newValue.first.second, newValue.second.first, newValue.second.second) }
    }

    /// The tab's body in `rect`, placed as `BezelLayout` places content: flush with the bezel,
    /// centred along it on a whole point. The ears flare beyond it, along the bezel.
    func body(in rect: CGRect) -> CGRect {
        let depth = max(0, depth), length = max(0, length)
        return switch edge {
        case .right: CGRect(x: rect.maxX - depth, y: (rect.midY - length / 2).rounded(), width: depth, height: length)
        case .left: CGRect(x: rect.minX, y: (rect.midY - length / 2).rounded(), width: depth, height: length)
        case .top: CGRect(x: (rect.midX - length / 2).rounded(), y: rect.minY, width: length, height: depth)
        }
    }

    /// Drawn once in bezel terms (depth in from the edge, distance along it)
    /// and mapped onto whichever edge it's on.
    func path(in rect: CGRect) -> Path {
        let rect = body(in: rect)
        guard depth > 0, length > 0 else { return Path() }
        let k: CGFloat = 0.5523  // cubic approximation of a quarter circle
        let depth = edge == .top ? rect.height : rect.width
        let length = edge == .top ? rect.width : rect.height
        let r = min(radius, depth / 2, length / 2)
        let e = min(ear, depth)
        func p(_ d: CGFloat, _ a: CGFloat) -> CGPoint { edge.point(depth: d, along: a, in: rect) }
        var path = Path()
        path.move(to: p(0, -e))
        path.addCurve(to: p(e, 0), control1: p(0, -e + k * e), control2: p(e - k * e, 0))
        path.addLine(to: p(depth - r, 0))
        path.addCurve(to: p(depth, r), control1: p(depth - r + k * r, 0), control2: p(depth, r - k * r))
        path.addLine(to: p(depth, length - r))
        path.addCurve(to: p(depth - r, length), control1: p(depth, length - r + k * r), control2: p(depth - r + k * r, length))
        path.addLine(to: p(e, length))
        path.addCurve(to: p(0, length + e), control1: p(e - k * e, length), control2: p(0, length + e - k * e))
        path.closeSubpath()
        return path
    }
}
