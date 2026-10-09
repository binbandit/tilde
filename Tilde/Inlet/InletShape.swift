import SwiftUI

/// A rounded tab whose base is the bezel, with concave "ears" where it meets
/// the bezel so it reads as part of the display.
nonisolated struct InletShape: Shape {
    var edge: InletEdge
    var radius: CGFloat
    var ear: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(radius, ear) }
        set { (radius, ear) = (newValue.first, newValue.second) }
    }

    /// Drawn once in bezel terms (depth in from the edge, distance along it)
    /// and mapped onto whichever edge it's on.
    func path(in rect: CGRect) -> Path {
        let k: CGFloat = 0.5523  // cubic approximation of a quarter circle
        let depth = edge == .top ? rect.height : rect.width
        let length = edge == .top ? rect.width : rect.height
        let r = min(radius, depth / 2, length / 2)
        let e = ear
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
