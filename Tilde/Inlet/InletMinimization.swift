import Foundation
import CoreGraphics

/// Explicit minimization stays in force until the user returns to the Inlet.
/// Moving out of the old expanded surface rearms hover, but never shows a reply.
nonisolated struct InletMinimization {
    private(set) var isMinimized = false
    private(set) var excludedHoverRect: CGRect?

    mutating func minimize(in rect: CGRect) {
        isMinimized = true
        excludedHoverRect = rect.insetBy(dx: -16, dy: -16)
    }

    mutating func open() {
        isMinimized = false
        excludedHoverRect = nil
    }

    mutating func pointerMoved(to point: CGPoint) {
        if let rect = excludedHoverRect, !rect.contains(point) { excludedHoverRect = nil }
    }
}
