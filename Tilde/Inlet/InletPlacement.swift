import AppKit
import SwiftUI

/// Which edge of the display the Inlet sinks into. Settings keep one choice
/// for the built-in display and one for external displays.
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

    /// Where the shape sits in its panel: flush with the bezel.
    var alignment: Alignment {
        switch self {
        case .right: .trailing
        case .left: .leading
        case .top: .top
        }
    }

    /// Where content sits inside the shape while it morphs: against the inner
    /// side, so anything that overflows spills toward the bezel.
    var inward: Alignment {
        switch self {
        case .right: .leading
        case .left: .trailing
        case .top: .bottom
        }
    }

    /// The bezel side of the shape, which things grow out of and shrink back into.
    var anchor: UnitPoint {
        switch self {
        case .right: .trailing
        case .left: .leading
        case .top: .top
        }
    }

    /// Maps a point measured from the bezel (`depth` in from it, `along` it)
    /// into `rect`, so one outline serves every edge.
    func point(depth: CGFloat, along: CGFloat, in rect: CGRect) -> CGPoint {
        switch self {
        case .right: CGPoint(x: rect.maxX - depth, y: rect.minY + along)
        case .left: CGPoint(x: rect.minX + depth, y: rect.minY + along)
        case .top: CGPoint(x: rect.minX + along, y: rect.minY + depth)
        }
    }

    /// The strip of bezel beside `shape` (Cocoa screen coordinates). Pushing
    /// the pointer into the edge anywhere along it opens the Inlet, so it
    /// doesn't need aiming.
    func bezelBand(beside shape: CGRect, reach: CGFloat = 24) -> CGRect {
        switch self {
        case .right: CGRect(x: shape.maxX - 2, y: shape.minY - reach, width: 4, height: shape.height + 2 * reach)
        case .left: CGRect(x: shape.minX - 2, y: shape.minY - reach, width: 4, height: shape.height + 2 * reach)
        case .top: CGRect(x: shape.minX - reach, y: shape.maxY - 2, width: shape.width + 2 * reach, height: 4)
        }
    }
}

/// Where the Inlet is right now: an edge of one display, and on the top edge,
/// what it shares that edge with.
struct InletPlacement: Equatable {
    static let displayKey = "inletDisplay"

    var edge: InletEdge = .right
    /// The camera housing a top Inlet fuses with. Nil on the sides, and on a
    /// top edge without one, where it hangs from the menu bar instead.
    var notch: CGSize?
    /// The menu bar's thickness. A top Inlet at rest stays inside it.
    var menuBar: CGFloat = 24
    /// The panel the Inlet morphs inside, in Cocoa screen coordinates. It's a
    /// fixed strip along the edge, wide enough for the review.
    var frame: CGRect = .zero

    /// Across the edge for the sides, along it for the top: room for the
    /// widest look (the review) and its ears.
    private static let span: CGFloat = 900

    init() {}

    init(edge: InletEdge, on screen: NSScreen, simulatesNotch: Bool = false) {
        let full = screen.frame, visible = screen.visibleFrame
        let bar = full.maxY - visible.maxY
        self.edge = edge
        // An auto-hidden menu bar leaves no gap; use its usual thickness.
        menuBar = bar > 0 ? bar : screen.notch?.height ?? NSStatusBar.system.thickness
        if edge == .top {
            // A pretend notch is a 14-inch MacBook Pro's, near enough.
            notch = screen.notch?.size ?? (simulatesNotch ? CGSize(width: 190, height: 32) : nil)
        }
        // A Dock on a side edge owns it, so the Inlet sits against the Dock
        // instead. An auto-hidden Dock only reserves a few points.
        switch edge {
        case .right:
            let bezel = full.maxX - visible.maxX > 8 ? visible.maxX : full.maxX
            frame = CGRect(x: bezel - Self.span, y: visible.minY, width: Self.span, height: visible.height)
        case .left:
            let bezel = visible.minX - full.minX > 8 ? visible.minX : full.minX
            frame = CGRect(x: bezel, y: visible.minY, width: Self.span, height: visible.height)
        case .top:
            let center = screen.notch?.midX ?? full.midX
            frame = CGRect(x: center - Self.span / 2, y: visible.minY, width: Self.span, height: full.maxY - visible.minY)
        }
        frame = NSIntegralRectWithOptions(frame, .alignAllEdgesNearest)
    }

    /// The display the Inlet lives on: the one picked in Settings while it's
    /// connected, otherwise the built-in display while the lid is open,
    /// otherwise the main display.
    static func screen(display: String?) -> NSScreen? {
        let screens = NSScreen.screens
        if let display, let chosen = screens.first(where: { $0.uuid == display }) { return chosen }
        return screens.first(where: \.isBuiltIn) ?? screens.first
    }

    /// The edge chosen for this kind of display: by default the notch on a
    /// MacBook, and the right edge of anything else.
    static func edge(on screen: NSScreen) -> InletEdge {
        let key = screen.isBuiltIn ? InletEdge.builtInKey : InletEdge.externalKey
        return UserDefaults.standard.string(forKey: key).flatMap(InletEdge.init) ?? (screen.isBuiltIn ? .top : .right)
    }
}

extension NSScreen {
    /// The camera housing cut into the top of the display, in screen coordinates.
    var notch: CGRect? {
        guard safeAreaInsets.top > 0, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        let height = safeAreaInsets.top
        return CGRect(
            x: frame.minX + left.width, y: frame.maxY - height, width: frame.width - left.width - right.width, height: height)
    }

    private var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    var isBuiltIn: Bool { displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false }

    /// Stable across reconnects and restarts, unlike the display ID, so it's
    /// what Settings remembers.
    var uuid: String? {
        guard let displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
