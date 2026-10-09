import SwiftUI

/// Holds the Inlet flush against its bezel and centred along it, on whole
/// points: centring at a half point would blur every line of text at 1x.
struct BezelLayout: Layout {
    var edge: InletEdge

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let shape = subviews.first else { return }
        let ideal = shape.sizeThatFits(.unspecified)
        let size = CGSize(width: ideal.width.rounded(.up), height: ideal.height.rounded(.up))
        let origin =
            switch edge {
            case .right: CGPoint(x: bounds.maxX - size.width, y: (bounds.midY - size.height / 2).rounded())
            case .left: CGPoint(x: bounds.minX, y: (bounds.midY - size.height / 2).rounded())
            case .top: CGPoint(x: (bounds.midX - size.width / 2).rounded(), y: bounds.minY)
            }
        shape.place(at: origin, proposal: ProposedViewSize(size))
    }
}
