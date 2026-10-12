import Foundation

/// Which edge of the display the Inlet sinks into. Kept independent of a screen or view
/// so the same bounds calculations can be exercised with small and offset displays.
nonisolated enum InletEdge: String, CaseIterable, Identifiable {
    case right, left, top

    static let builtInKey = "inletEdge.builtIn"
    static let externalKey = "inletEdge.external"

    var id: Self { self }

    var label: String {
        switch self {
        case .right: "Right edge"
        case .left: "Left edge"
        case .top: "Top"
        }
    }
}

/// Display and content budgets, including all of the chrome around a conversation.
/// These calculations don't consult NSScreen, defaults, or any live app state.
nonisolated struct InletGeometry {
    var edge: InletEdge
    var panelSize: CGSize
    var notch: CGSize?

    static let expandedEar: CGFloat = 12

    struct Padding {
        var top: CGFloat
        var leading: CGFloat
        var bottom: CGFloat
        var trailing: CGFloat

        var horizontal: CGFloat { leading + trailing }
        var vertical: CGFloat { top + bottom }
    }

    /// Fixed strip against the selected bezel, narrowed when the screen or Dock leaves
    /// less room. A top strip remains centred on the camera housing.
    static func panelFrame(edge: InletEdge, full: CGRect, visible: CGRect, notchCenterX: CGFloat? = nil) -> CGRect {
        let left = max(full.minX, visible.minX - full.minX > 8 ? visible.minX : full.minX)
        let right = min(full.maxX, full.maxX - visible.maxX > 8 ? visible.maxX : full.maxX)
        let bottom = max(full.minY, visible.minY)
        let top = min(full.maxY, visible.maxY)
        let availableWidth = max(0, right - left)
        let span = min(900, availableWidth)
        let rect: CGRect
        switch edge {
        case .right:
            rect = CGRect(x: right - span, y: bottom, width: span, height: max(0, top - bottom))
        case .left:
            rect = CGRect(x: left, y: bottom, width: span, height: max(0, top - bottom))
        case .top:
            let center = min(right, max(left, notchCenterX ?? full.midX))
            let width = min(span, 2 * max(0, min(center - left, right - center)))
            rect = CGRect(x: center - width / 2, y: bottom, width: width, height: max(0, full.maxY - bottom))
        }
        // Rounding inward keeps every panel edge inside the usable display.
        return CGRect(
            x: rect.minX.rounded(.up), y: rect.minY.rounded(.up),
            width: max(0, rect.maxX.rounded(.down) - rect.minX.rounded(.up)),
            height: max(0, rect.maxY.rounded(.down) - rect.minY.rounded(.up)))
    }

    /// Ears flare along the bezel beyond the body, so they need their own room.
    func bodyLimit(ear: CGFloat) -> CGSize {
        CGSize(
            width: max(0, panelSize.width - (edge == .top ? 2 * ear : 0)).rounded(.down),
            height: max(0, panelSize.height - (edge == .top ? 0 : 2 * ear)).rounded(.down))
    }

    var conversationSize: CGSize { expandedSize(width: 400, height: 600, fraction: 0.70) }
    var peekSize: CGSize { expandedSize(width: 380, height: 600, fraction: 0.70) }
    var jobSize: CGSize { expandedSize(width: 820, height: 860, fraction: 0.84) }

    private func expandedSize(width: CGFloat, height: CGFloat, fraction: CGFloat) -> CGSize {
        let limit = bodyLimit(ear: Self.expandedEar)
        return CGSize(width: min(width, limit.width), height: min(height, limit.height * fraction).rounded(.down))
    }

    /// Padding is part of the height budget. At unusually small resolutions it yields
    /// room to the scrollable content instead of making the shape overflow the screen.
    func padding(in size: CGSize) -> Padding {
        var padding: Padding
        switch edge {
        case .right: padding = Padding(top: 18, leading: 20, bottom: 18, trailing: 22)
        case .left: padding = Padding(top: 18, leading: 22, bottom: 18, trailing: 20)
        case .top: padding = Padding(top: notch.map { $0.height + 12 } ?? 18, leading: 21, bottom: 20, trailing: 21)
        }
        let horizontal = min(1, max(0, size.width - 1) / padding.horizontal)
        let vertical = min(1, max(0, size.height - 1) / padding.vertical)
        padding.leading *= horizontal
        padding.trailing *= horizontal
        padding.top *= vertical
        padding.bottom *= vertical
        return padding
    }

    func contentHeight(in size: CGSize) -> CGFloat {
        max(0, size.height - padding(in: size).vertical)
    }

    var jobTopPadding: CGFloat { min(notch?.height ?? 0, max(0, jobSize.height - 1)) }
    var jobContentHeight: CGFloat { max(0, jobSize.height - jobTopPadding) }

    /// Round content up for crisp edges, without rounding a bounded dimension beyond
    /// its budget. Used for both the drawn shape and the controller's hit rectangle.
    func bounded(_ size: CGSize, ear: CGFloat, maximum: CGSize? = nil) -> CGSize {
        let limit = bodyLimit(ear: ear)
        return CGSize(
            width: max(0, min(size.width.rounded(.up), limit.width, maximum?.width ?? limit.width)),
            height: max(0, min(size.height.rounded(.up), limit.height, maximum?.height ?? limit.height)))
    }
}
