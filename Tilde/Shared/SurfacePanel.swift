import AppKit

/// A borderless, transparent panel that never activates tilde. The Inlet and
/// the Lens are each one of these.
final class SurfacePanel: NSPanel {
    var acceptsKey = false

    init(level: NSWindow.Level, interactive: Bool = true) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        // Before the level: making a panel floating resets its level to .floating.
        isFloatingPanel = true
        // A click takes the keyboard only for a text field; buttons leave it where it was.
        becomesKeyOnlyIfNeeded = true
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        // Surfaces are part of the desktop, not windows to put away when tilde
        // hands focus back with NSApp.hide.
        canHide = false
        isMovable = false
        animationBehavior = .none
        ignoresMouseEvents = !interactive
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
    }

    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }

    /// Surfaces place themselves deliberately, over the menu bar included.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Sets the frame on whole points: a window at a fractional origin
    /// resamples everything in it, and text blurs on a 1x display.
    func place(_ frame: CGRect) {
        setFrame(NSIntegralRectWithOptions(frame, .alignAllEdgesNearest), display: true)
    }
}
