import SwiftUI

/// What the Inlet is showing, and where it lives.
///
/// The Inlet is tilde: a black shape sunk into an edge of the display (or the
/// notch). At rest it's a hairline, or the `~` with a dot per agent while the
/// crew works. When tilde says something it peeks out with that one message.
/// Under the pointer it opens into the day's conversation with tilde.
@MainActor @Observable
final class Inlet {
    enum Mode: Equatable {
        /// The hairline, or the `~` and the crew's dots.
        case rest
        /// One message out of the edge: a reply, a heads-up, a question.
        case peek(String)
        /// Open under the pointer: the conversation, the crew, the composer.
        case open
        /// Open with the composer focused, after a tap of the tilde key.
        case compose
        /// The tilde key is held: your words appear in the conversation as you say them.
        case listening
        /// A job opened wide: its agent's conversation, its changes, and what you can do.
        case job(String)
    }

    var mode: Mode = .rest
    var placement = InletPlacement()
    var preferences = InletPreferences(defaults: .standard)
    var history = ConversationVisibility()
    /// Each look's content size, for the looks whose shape hugs it.
    var measured: [Look: CGSize] = [:]

    /// How far a working top Inlet widens either side of the camera housing.
    static let wing: CGFloat = 44
    /// A working Inlet on the side: the `~` with its dots below, room to breathe between.
    static let pill = CGSize(width: 38, height: 80)

    /// How the shape looks: the views draw it and the controller hit-tests it from the same
    /// `shape(for:)`, so where the pointer counts as on tilde is always where tilde is going.
    enum Look: Hashable {
        case dormant, compact, peek, conversation, job

        /// Small enough to live in the bezel.
        var isTucked: Bool { self == .dormant || self == .compact }
    }

    /// The look for the current mode. `busy`: agents are working or something waits on you.
    func look(busy: Bool) -> Look {
        switch mode {
        case .rest: busy ? .compact : .dormant
        case .peek: .peek
        case .job: .job
        case .open, .compose, .listening: .conversation
        }
    }

    /// The shape a look takes, in bezel terms.
    func shape(for look: Look) -> InletShape {
        let confined = preferences.confinesRestingInlet(edge: placement.edge, notch: placement.notch)
        // A nil dimension hugs the content.
        let (width, height, radius, ear): (CGFloat?, CGFloat?, CGFloat, CGFloat) =
            switch (look, placement.edge, placement.notch) {
            case (.peek, _, _): (380, nil, 28, 12)
            case (.conversation, _, _): (400, nil, 28, 12)
            case (.job, _, _): (820, nil, 28, 12)
            // At rest it is the notch; working, the notch widens just enough for a wing either side.
            case (.dormant, .top, let notch?): (notch.width, notch.height, 10, confined ? 0 : 5)
            case (.compact, .top, let notch?):
                (notch.width + (confined ? 0 : 2 * Self.wing), notch.height, confined ? 10 : 12, confined ? 0 : 7)
            // Without one it's a lip hanging from the menu bar, never deeper than the bar itself.
            case (.dormant, .top, nil): (46, 5, 2.5, 5)
            case (.compact, .top, nil): (nil, placement.menuBar, placement.menuBar / 2, 8)
            case (.dormant, _, _): (5, 46, 2.5, 5)
            case (.compact, _, _): (Self.pill.width, Self.pill.height, 16, 12)
            }
        // Until a look has been measured, something plausible to grow toward.
        let size = measured[look] ?? CGSize(width: 120, height: 120)
        let maximum: CGSize? = switch look {
        case .conversation: placement.geometry.conversationSize
        case .peek: placement.geometry.peekSize
        case .job: placement.geometry.jobSize
        case .dormant, .compact: nil
        }
        let bounded = placement.geometry.bounded(CGSize(width: width ?? size.width, height: height ?? size.height), ear: ear, maximum: maximum)
        let w = bounded.width, h = bounded.height
        let (depth, length) = placement.edge == .top ? (h, w) : (w, h)
        return InletShape(edge: placement.edge, depth: depth, length: length, radius: radius, ear: ear)
    }

    /// Modes that show the whole conversation.
    var isConversation: Bool { [.open, .compose, .listening].contains(mode) }

    /// Modes that need the keyboard.
    var wantsKey: Bool {
        switch mode {
        case .compose, .job: true
        default: false
        }
    }
}
