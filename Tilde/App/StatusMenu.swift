import AppKit
import SwiftUI

/// The app's persistent controls, available even while the Inlet is resting.
struct StatusMenu: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit tilde") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    /// Use the same wave as the Inlet, with a template image for either menu bar appearance.
    static let icon: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(Wave(phase: 0, amplitude: 0.8)
                .path(in: CGRect(x: 2, y: 4, width: 16, height: 10)).cgPath)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(2)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "tilde"
        return image
    }()
}
