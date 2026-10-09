import SwiftUI
import TildeKit

/// A worker's state as a dot: white working, amber needs you, green ready,
/// red failed. The `~` is tilde's alone; the crew are always dots.
struct StatusDot: View {
    var phase: Job.Phase
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(Theme.tint(phase)).frame(width: size, height: size)
    }
}
