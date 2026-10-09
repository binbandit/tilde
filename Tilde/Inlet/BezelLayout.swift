import SwiftUI

/// Holds the Inlet's content flush against its bezel and centred along it, on whole
/// points (centring at a half point would blur every line of text at 1x), where
/// `InletShape` draws the black around it.
struct BezelLayout: Layout {
    var edge: InletEdge

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let size = content.sizeThatFits(.unspecified)
        // Rounded the way `InletShape` rounds its body, so the two line up.
        let length = (edge == .top ? size.width : size.height).rounded(.up)
        let origin =
            switch edge {
            case .right: CGPoint(x: (bounds.maxX - size.width).rounded(.down), y: (bounds.midY - length / 2).rounded())
            case .left: CGPoint(x: bounds.minX, y: (bounds.midY - length / 2).rounded())
            case .top: CGPoint(x: (bounds.midX - length / 2).rounded(), y: bounds.minY)
            }
        content.place(at: origin, proposal: ProposedViewSize(size))
    }
}
