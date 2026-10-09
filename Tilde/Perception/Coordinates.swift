import AppKit

/// Accessibility and CoreGraphics use a top-left origin on the primary screen; AppKit uses bottom-left.
enum Coordinates {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func cocoa(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func cocoa(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: primaryHeight - point.y) }

    static func quartz(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: primaryHeight - point.y) }
}
