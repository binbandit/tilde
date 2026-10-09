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
    /// The shape's frame in the panel's SwiftUI space, for hit-testing.
    var shapeFrame: CGRect = .zero

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
