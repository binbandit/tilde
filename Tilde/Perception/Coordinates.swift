import AppKit

/// Accessibility and CoreGraphics use a top-left origin on the primary screen; AppKit uses bottom-left.
enum Coordinates {
    /// The display transform, read on the main actor (NSScreen lives there) and carried to the
    /// Accessibility reads that need it.
    static var snapshot: Snapshot { Snapshot(primaryHeight: NSScreen.screens.first?.frame.height ?? 0) }

    nonisolated struct Snapshot: Sendable {
        let primaryHeight: CGFloat

        func cocoa(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }

        func quartz(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: primaryHeight - point.y) }
    }
}
