import SwiftUI

extension View {
    /// Keeps a scroll view of a conversation at its newest line: as lines arrive and as the view
    /// resizes (opening, the Inlet animates its height), unless the owner has scrolled up to read.
    func followingBottom() -> some View { modifier(FollowBottom()) }
}

private struct FollowBottom: ViewModifier {
    @State private var position = ScrollPosition(edge: .bottom)
    /// Scrolled up to read older lines, so new ones don't pull the view away.
    @State private var reading = false

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollPhaseChange { _, phase, context in
                guard phase == .idle else { return }
                reading = context.geometry.visibleRect.maxY < context.geometry.contentSize.height - 4
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height - $0.containerSize.height } action: { _, _ in
                if !reading { position.scrollTo(edge: .bottom) }
            }
    }
}
