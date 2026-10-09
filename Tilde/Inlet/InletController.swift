import AppKit
import Observation
import SwiftUI
import TildeKit

/// Puts the Inlet on screen and decides what it shows: it peeks out when tilde
/// says something, opens under the pointer, takes the keyboard to talk, and
/// settles back to rest when you're done.
@MainActor @Observable
final class InletController {
    let model: AppModel
    let lens: LensController
    let inlet = Inlet()
    /// What the current exchange is about.
    var exchangeTarget: Referent?

    /// Debug: an edge forced over Settings, and a pretend notch on a display
    /// without one, to try every placement on any Mac.
    @ObservationIgnored var forcedEdge: InletEdge?
    @ObservationIgnored var simulatesNotch = false
    /// Debug: keeps the Inlet open without the pointer on it, for screenshots.
    @ObservationIgnored var pinnedOpen = false
    /// SwiftUI only hands this to views; the Inlet's host passes it on.
    @ObservationIgnored var openSettings: OpenSettingsAction?

    @ObservationIgnored private var panel: SurfacePanel?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var observers: [Any] = []
    /// tilde's messages already shown, so each peeks out once.
    @ObservationIgnored private var seen: Set<String>

    init(model: AppModel, lens: LensController) {
        self.model = model
        self.lens = lens
        seen = Set(model.thread.map(\.id))
        observe { [weak self] in self?.threadChanged() }
    }

    var actions: InletActions {
        InletActions(
            send: { [weak self] in self?.send($0) },
            review: { [weak self] in self?.review($0) },
            compose: { [weak self] in if self?.inlet.mode != .compose { self?.set(.compose) } },
            dismiss: { [weak self] in self?.set(.rest) })
    }

    // MARK: Showing

    func show() {
        guard panel == nil else { return place() }
        // Just above the Lens, so an outline never draws over tilde.
        let panel = SurfacePanel(level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1), interactive: true)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: InletHost(controller: self).environment(model).environment(inlet))
        // The panel is a fixed strip; the shape morphs inside it without resizing the window.
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        place()
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        trackMouse()

        let center = NotificationCenter.default
        let place: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.place() } }
        observers = [
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: place),
            // Settings (and the debug route) move it live.
            center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main, using: place),
            // A fullscreen space hides the menu bar, which a top Inlet sizes itself to.
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: place),
            // Clicking away from the composer or a review puts the Inlet back to rest.
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resignedKey() }
            },
        ]
    }

    /// Puts the Inlet on its display, on the edge chosen for that kind of display.
    func place() {
        guard let panel,
            let screen = InletPlacement.screen(display: UserDefaults.standard.string(forKey: InletPlacement.displayKey))
        else { return }
        let edge = forcedEdge ?? InletPlacement.edge(on: screen)
        let placement = InletPlacement(edge: edge, on: screen, simulatesNotch: simulatesNotch)
        guard placement != inlet.placement || panel.frame != placement.frame else { return }
        inlet.placement = placement
        panel.place(placement.frame)
    }

    func set(_ mode: Inlet.Mode) {
        guard inlet.mode != mode else { return }
        inlet.mode = mode
        if mode != .open { pinnedOpen = false }
        if mode == .rest {
            exchangeTarget = nil
            inlet.focusedJob = nil
        }
        // Held news is told while you're looking.
        model.conductor?.looking = inlet.isConversation
        panel?.acceptsKey = inlet.wantsKey
        if inlet.wantsKey {
            NSApp.activate()
            panel?.makeKey()
        } else if panel?.isKeyWindow == true {
            panel?.resignKey()
            NSApp.hide(nil)
        }
    }

    private func resignedKey() {
        switch inlet.mode {
        case .review: set(.rest)
        case .compose where model.draft.isEmpty: set(.rest)
        default: break
        }
    }

    // MARK: Talking

    /// A tap of the tilde key: the conversation opens with the composer ready.
    func compose(about referent: Referent?) {
        exchangeTarget = referent
        if let referent { lens.flash(on: referent) }
        set(.compose)
    }

    /// The tilde key is held: your words appear in the conversation as you speak.
    func listen(about referent: Referent?) {
        exchangeTarget = referent
        set(.listening)
    }

    /// The key was released: send what was heard, or settle back.
    func heard(_ text: String) {
        lens.hide()
        if text.isEmpty { set(.rest) } else { send(text) }
    }

    /// Sends what you said; tilde's reply peeks out as it's written.
    func send(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return set(.rest) }
        model.send(text, about: exchangeTarget)
        if let reply = model.thread.last, reply.from == .tilde {
            seen.insert(reply.id)
            set(.peek(reply.id))
        } else {
            set(.rest)
        }
    }

    func review(_ job: Job) { set(.review(job.id)) }

    /// New words from tilde peek out of the edge, unless the conversation is
    /// already open; the peek settles once it's been read.
    private func threadChanged() {
        let thread = model.thread
        let fresh = thread.filter { $0.from == .tilde && !seen.contains($0.id) }
        seen.formUnion(thread.map(\.id))

        if let latest = fresh.last, inlet.mode == .rest || isPeek {
            set(.peek(latest.id))
        }
        if case .peek(let id) = inlet.mode, let message = thread.first(where: { $0.id == id }), !message.streaming {
            settle(after: linger(for: message))
        }
    }

    /// Long enough to read; questions stay a little longer.
    private func linger(for message: Message) -> Duration {
        if message.attentionID != nil { return .seconds(12) }
        let words = (message.text + message.noted.joined(separator: " ")).split(separator: " ").count
        return .seconds(min(20, 4 + Double(words) * 0.3))
    }

    private var isPeek: Bool { if case .peek = inlet.mode { true } else { false } }

    /// Returns the Inlet to rest after a while, unless you're using it.
    private func settle(after delay: Duration) {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.isPeek,
                !self.inletRect.insetBy(dx: -16, dy: -16).contains(NSEvent.mouseLocation)
            else { return }
            self.set(.rest)
        }
    }

    // MARK: Pointer

    /// The Inlet's shape on screen, in Cocoa coordinates.
    private var inletRect: CGRect {
        guard let panel else { return .zero }
        let local = inlet.shapeFrame
        return CGRect(x: panel.frame.minX + local.minX, y: panel.frame.maxY - local.maxY, width: local.width, height: local.height)
    }

    /// The Inlet only takes the mouse where it's drawn; everywhere else clicks
    /// fall through to the windows beneath. Resting the pointer at the edge opens it.
    private func trackMouse() {
        guard monitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.pointerMoved() }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { handler($0); return $0 } as Any)
    }

    private func pointerMoved() {
        guard let panel else { return }
        if case .review = inlet.mode { return }
        let mouse = NSEvent.mouseLocation
        let rect = inletRect
        // At rest the target is the sliver plus a band along the very edge.
        let slop: CGFloat = inlet.mode == .rest ? 10 : 16
        let hot = rect.insetBy(dx: -slop, dy: -slop).contains(mouse)
            || (inlet.mode == .rest && inlet.placement.edge.bezelBand(beside: rect).contains(mouse))
        panel.ignoresMouseEvents = !rect.contains(mouse)

        hoverTask?.cancel()
        guard inlet.mode != .listening else { return }
        if hot, inlet.mode == .rest || isPeek {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled else { return }
                self?.set(.open)
            }
        } else if !hot, !pinnedOpen, inlet.mode == .open || (inlet.mode == .compose && model.draft.isEmpty && !panel.isKeyWindow) {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(380))
                guard !Task.isCancelled else { return }
                self?.set(.rest)
            }
        }
    }

    // MARK: Observation

    private func observe(_ apply: @escaping @MainActor () -> Void) {
        withObservationTracking(apply) { [weak self] in
            Task { @MainActor in self?.observe(apply) }
        }
    }
}

private struct InletHost: View {
    var controller: InletController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        InletView(referent: controller.exchangeTarget, actions: controller.actions)
            .onAppear { controller.openSettings = openSettings }
    }
}
