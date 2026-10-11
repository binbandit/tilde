import SwiftUI
import TildeKit

/// tilde's look is AMOLED: true black that melts into the bezel, white type,
/// and colour only where it carries meaning. Amber means "needs you", green
/// "ready", red "failed", blue "you": your words, and what you're pointing at.
enum Theme {
    static let ink = Color.black
    /// Rows and wells inside black surfaces.
    static let raised = Color(white: 0.085)
    static let line = Color.white.opacity(0.09)
    /// tilde's side of the conversation.
    static let bubble = Color(white: 0.14)
    static let text = Color.white
    static let text2 = Color.white.opacity(0.62)
    static let text3 = Color.white.opacity(0.38)

    static let amber = Color(red: 1.0, green: 0.69, blue: 0.13)
    static let ready = Color(red: 0.2, green: 0.84, blue: 0.29)
    static let failed = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let focus = Color(red: 0.04, green: 0.52, blue: 1.0)

    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.8)
    /// The Inlet opening out of the bezel, with a little give at the end.
    static let morph = Animation.spring(response: 0.5, dampingFraction: 0.8)
    /// The Inlet going back into the bezel: a touch quicker, and nearly settled, so it
    /// slips in rather than slams.
    static let tuck = Animation.spring(response: 0.44, dampingFraction: 0.88)
    static let quick = Animation.spring(response: 0.24, dampingFraction: 0.9)

    static func tint(_ phase: Job.Phase) -> Color {
        switch phase {
        case .needsYou: amber
        case .ready, .landed: ready
        case .failed: failed
        default: text2
        }
    }
}

/// Small secondary text.
struct Meta: View {
    var text: String
    var color = Theme.text2
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(color).lineLimit(1)
    }
}
