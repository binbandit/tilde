import AppKit
import SwiftUI

/// The Lens: a blue outline around whatever "this" is while you point.
@MainActor @Observable
final class LensController {
    private(set) var target: Referent?
    @ObservationIgnored private var panel: SurfacePanel?

    func show(on referent: Referent) {
        target = referent
        let panel = panel ?? {
            let panel = SurfacePanel(level: .statusBar, interactive: false)
            let host = NSHostingView(rootView: LensHost(lens: self))
            // The panel is sized to the target; the view never resizes it.
            host.sizingOptions = []
            panel.contentView = host
            self.panel = panel
            return panel
        }()
        panel.place(referent.frame.insetBy(dx: -8, dy: -8))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        target = nil
    }

    /// A brief outline, so a typed request still shows what "this" is.
    func flash(on referent: Referent) {
        show(on: referent)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            if self?.target == referent { self?.hide() }
        }
    }
}

private struct LensHost: View {
    var lens: LensController
    var body: some View {
        if let target = lens.target { LensView(referent: target).id(target.frame) }
    }
}
