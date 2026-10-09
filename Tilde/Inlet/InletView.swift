import SwiftUI
import TildeKit

/// The Inlet's one black shape, morphing between looks: a hairline at rest,
/// the `~` and crew dots while agents work, one message when tilde speaks,
/// the conversation under the pointer, and the review opened wide.
struct InletView: View {
    @Environment(AppModel.self) private var model
    @Environment(Inlet.self) private var inlet
    var referent: Referent?
    var actions: InletActions

    /// How far a working top Inlet widens either side of the camera housing.
    static let wing: CGFloat = 44

    private enum Look { case dormant, compact, peek, conversation, review }

    private var look: Look {
        switch inlet.mode {
        case .rest: model.openJobs.isEmpty && model.attention.isEmpty ? .dormant : .compact
        case .peek: .peek
        case .review: .review
        case .open, .compose, .listening: .conversation
        }
    }

    private var placement: InletPlacement { inlet.placement }

    var body: some View {
        let outline = outline
        let shape = InletShape(edge: placement.edge, radius: outline.radius, ear: outline.ear)
        BezelLayout(edge: placement.edge) {
            content
                .frame(width: outline.width, height: outline.height, alignment: placement.edge.inward)
                .background(shape.fill(Theme.ink))
                .contentShape(shape)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { inlet.shapeFrame = $0 }
        }
        .environment(\.colorScheme, .dark)
        .environment(\.controlActiveState, .key)
        .animation(Theme.morph, value: inlet.mode)
        .animation(Theme.morph, value: look)
    }

    /// Content fades in growing out of the bezel. No blur: a blur transition
    /// can leave text rasterised and soft once it lands.
    private var appear: AnyTransition { .opacity.combined(with: .scale(scale: 0.96, anchor: placement.edge.anchor)) }

    /// The shape's size and corners for the current look. A nil dimension hugs the content.
    private struct Outline {
        var width: CGFloat?
        var height: CGFloat?
        var radius: CGFloat
        var ear: CGFloat
    }

    private var outline: Outline {
        switch (look, placement.edge, placement.notch) {
        case (.peek, _, _): Outline(width: 380, height: nil, radius: 28, ear: 12)
        case (.conversation, _, _): Outline(width: 400, height: nil, radius: 28, ear: 12)
        case (.review, _, _): Outline(width: 820, height: nil, radius: 28, ear: 12)
        // At rest it is the notch; working, the notch widens just enough for a wing either side.
        case (.dormant, .top, let notch?): Outline(width: notch.width, height: notch.height, radius: 10, ear: 5)
        case (.compact, .top, let notch?): Outline(width: notch.width + 2 * Self.wing, height: notch.height, radius: 12, ear: 7)
        // Without one it's a lip hanging from the menu bar, never deeper than the bar itself.
        case (.dormant, .top, nil): Outline(width: 46, height: 5, radius: 2.5, ear: 5)
        case (.compact, .top, nil): Outline(width: nil, height: placement.menuBar, radius: placement.menuBar / 2, ear: 8)
        case (.dormant, _, _): Outline(width: 5, height: 46, radius: 2.5, ear: 5)
        case (.compact, _, _): Outline(width: 38, height: 72, radius: 16, ear: 12)
        }
    }

    /// Room around open content: a little extra on the bezel side, where the
    /// ears make the edge feel closer, and on top, clear of the camera housing.
    private var insets: EdgeInsets {
        switch placement.edge {
        case .right: EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 22)
        case .left: EdgeInsets(top: 18, leading: 22, bottom: 18, trailing: 20)
        case .top: EdgeInsets(top: placement.notch.map { $0.height + 12 } ?? 18, leading: 21, bottom: 20, trailing: 21)
        }
    }

    /// The tallest the conversation gets before it scrolls.
    private var maxThread: CGFloat { (placement.frame.height * 0.62).rounded() }

    @ViewBuilder private var content: some View {
        switch look {
        case .dormant:
            Color.clear
        case .compact:
            CompactInlet(placement: placement)
                .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: placement.edge.anchor)))
        case .peek:
            if case .peek(let id) = inlet.mode {
                PeekView(messageID: id, actions: actions)
                    .padding(insets)
                    .transition(appear)
            }
        case .conversation:
            ConversationView(referent: referent, maxThread: maxThread, actions: actions)
                .padding(insets)
                .transition(appear)
                // tilde has no menu bar item or Dock icon; the open Inlet is the way in.
                .contextMenu { SettingsLink { Text("Settings…") } }
        case .review:
            if case .review(let id) = inlet.mode, let job = model.job(id) {
                ReviewView(job: job, height: min(860, placement.frame.height * 0.84), onClose: actions.dismiss)
                    .padding(.top, placement.notch?.height ?? 0)
                    .transition(appear)
            }
        }
    }
}

/// What the Inlet's views can ask its controller to do.
struct InletActions {
    var send: (String) -> Void
    var review: (Job) -> Void
    /// Make the composer usable (the panel takes the keyboard).
    var compose: () -> Void
    var dismiss: () -> Void
}
