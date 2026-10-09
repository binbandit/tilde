import SwiftUI
import TildeKit

/// The Inlet's one black shape, morphing between looks: a hairline at rest,
/// the `~` and crew dots while agents work, one message when tilde speaks,
/// the conversation under the pointer, and a job opened wide.
///
/// The shape is drawn from the bezel and animates on its own; content sits in it at its
/// own size, pinned to the bezel and clipped by the shape. Opening, the black grows out
/// of the edge and the content surfaces in it; closing, the content is drawn back into
/// the edge and the black follows it in, landing like a drop.
struct InletView: View {
    @Environment(AppModel.self) private var model
    @Environment(Inlet.self) private var inlet
    var referent: Referent?
    var actions: InletActions
    /// Each look's content size, for the looks whose shape hugs it.
    @State private var measured: [Look: CGSize] = [:]
    /// Bumps each time the Inlet tucks back into the bezel, for the landing.
    @State private var landings = 0
    /// The panel's bounds, which the shape is drawn in.
    @State private var bounds: CGRect = .zero

    /// How far a working top Inlet widens either side of the camera housing.
    static let wing: CGFloat = 44

    private enum Look: Hashable {
        case dormant, compact, peek, conversation, job

        /// Small enough to live in the bezel.
        var isTucked: Bool { self == .dormant || self == .compact }
    }

    private var look: Look {
        switch inlet.mode {
        case .rest: model.openJobs.isEmpty && model.attention.isEmpty ? .dormant : .compact
        case .peek: .peek
        case .job: .job
        case .open, .compose, .listening: .conversation
        }
    }

    private var placement: InletPlacement { inlet.placement }

    var body: some View {
        let outline = outline
        let shape = InletShape(edge: placement.edge, depth: outline.depth, length: outline.length, radius: outline.radius, ear: outline.ear)
        let anchor = placement.edge.anchor
        ZStack {
            shape.fill(Theme.ink)
            BezelLayout(edge: placement.edge) {
                ZStack(alignment: placement.edge.bezel) { content }
            }
        }
        .clipShape(shape)
        .contentShape(shape)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { bounds = $0 }
        // Where the pointer counts as on tilde: the shape it's becoming, as soon as it starts to.
        .onChange(of: outline, initial: true) { inlet.shapeFrame = shape.body(in: bounds) }
        .onChange(of: bounds) { inlet.shapeFrame = shape.body(in: bounds) }
        // Landing back in the bezel, it gives like a drop meeting the surface.
        .keyframeAnimator(initialValue: 1.0, trigger: landings) { view, scale in
            view.scaleEffect(scale, anchor: anchor)
        } keyframes: { _ in
            LinearKeyframe(1.0, duration: 0.26)
            SpringKeyframe(1.08, duration: 0.12, spring: .snappy)
            SpringKeyframe(1.0, duration: 0.4, spring: .bouncy(duration: 0.4, extraBounce: 0.12))
        }
        .environment(\.colorScheme, .dark)
        .environment(\.controlActiveState, .key)
        .animation(look.isTucked ? Theme.tuck : Theme.morph, value: outline)
        .animation(look.isTucked ? Theme.tuck : Theme.morph, value: inlet.mode)
        .onChange(of: look) { old, new in if !old.isTucked && new.isTucked { landings += 1 } }
    }

    /// Content surfaces out of the bezel as the black opens around it (no blur on the way
    /// in: it can leave text rasterised and soft once it lands), and is drawn back into the
    /// edge on the way out, a little ahead of the black.
    private var appear: AnyTransition {
        .asymmetric(
            // A beat behind the black, so it blooms into open space instead of being wiped across.
            insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: placement.edge.anchor))
                .animation(.smooth(duration: 0.34).delay(0.13)),
            removal: .absorbed(into: placement.edge.anchor))
    }

    /// The shape's size and corners for the current look, in bezel terms.
    private struct Outline: Equatable {
        /// How far in from the edge.
        var depth: CGFloat
        /// How far along it.
        var length: CGFloat
        var radius: CGFloat
        var ear: CGFloat
    }

    /// A look's size; a nil dimension hugs its content.
    private var outline: Outline {
        let (width, height, radius, ear): (CGFloat?, CGFloat?, CGFloat, CGFloat) =
            switch (look, placement.edge, placement.notch) {
            case (.peek, _, _): (380, nil, 28, 12)
            case (.conversation, _, _): (400, nil, 28, 12)
            case (.job, _, _): (820, nil, 28, 12)
            // At rest it is the notch; working, the notch widens just enough for a wing either side.
            case (.dormant, .top, let notch?): (notch.width, notch.height, 10, 5)
            case (.compact, .top, let notch?): (notch.width + 2 * Self.wing, notch.height, 12, 7)
            // Without one it's a lip hanging from the menu bar, never deeper than the bar itself.
            case (.dormant, .top, nil): (46, 5, 2.5, 5)
            case (.compact, .top, nil): (nil, placement.menuBar, placement.menuBar / 2, 8)
            case (.dormant, _, _): (5, 46, 2.5, 5)
            case (.compact, _, _): (38, 72, 16, 12)
            }
        // Until a look has been measured, something plausible to grow toward.
        let size = measured[look] ?? CGSize(width: 120, height: 120)
        let w = (width ?? size.width).rounded(.up), h = (height ?? size.height).rounded(.up)
        return placement.edge == .top
            ? Outline(depth: h, length: w, radius: radius, ear: ear)
            : Outline(depth: w, length: h, radius: radius, ear: ear)
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
            EmptyView()
        case .compact:
            CompactInlet(placement: placement)
                .measured { measured[.compact] = $0 }
                .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: placement.edge.anchor)))
        case .peek:
            if case .peek(let id) = inlet.mode {
                PeekView(messageID: id, actions: actions)
                    .padding(insets)
                    .frame(width: 380)
                    .fixedSize(horizontal: false, vertical: true)
                    .measured { measured[.peek] = $0 }
                    // One message goes back in as the next comes out, never the two on top of each other.
                    .id(id)
                    .transition(appear)
            }
        case .conversation:
            ConversationView(referent: referent, maxThread: maxThread, actions: actions)
                .padding(insets)
                .frame(width: 400)
                .fixedSize(horizontal: false, vertical: true)
                .measured { measured[.conversation] = $0 }
                .transition(appear)
                // tilde has no menu bar item or Dock icon; the open Inlet is the way in.
                .contextMenu { SettingsLink { Text("Settings…") } }
        case .job:
            if case .job(let id) = inlet.mode, let job = model.job(id) {
                JobView(job: job, height: min(860, placement.frame.height * 0.84), onClose: actions.dismiss)
                    .padding(.top, placement.notch?.height ?? 0)
                    .fixedSize(horizontal: false, vertical: true)
                    .measured { measured[.job] = $0 }
                    .transition(appear)
            }
        }
    }
}

private extension View {
    /// Reports the view's size as it changes. Each look keeps its own, so content on its
    /// way out never sizes the shape that's replacing it.
    func measured(_ report: @escaping (CGSize) -> Void) -> some View {
        onGeometryChange(for: CGSize.self) { $0.size } action: { report($0) }
    }
}

/// What the Inlet's views can ask its controller to do.
struct InletActions {
    var send: (String) -> Void
    /// Opens a job wide: its agent's conversation and its changes.
    var openJob: (Job) -> Void
    /// Make the composer usable (the panel takes the keyboard).
    var compose: () -> Void
    var dismiss: () -> Void
}

/// Leaving, content is drawn into the point it collapses to: it shrinks toward it, softens
/// and fades, a little ahead of the shape closing around it.
private struct Absorbed: ViewModifier {
    var amount: Double
    var anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - 0.55 * amount, anchor: anchor)
            .blur(radius: 10 * amount)
            .opacity(1 - amount)
    }
}

extension AnyTransition {
    static func absorbed(into anchor: UnitPoint) -> AnyTransition {
        .modifier(active: Absorbed(amount: 1, anchor: anchor), identity: Absorbed(amount: 0, anchor: anchor))
            .animation(.easeIn(duration: 0.18))
    }
}
