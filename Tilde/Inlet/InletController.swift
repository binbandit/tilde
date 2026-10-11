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
    /// Where resting the pointer is taking the Inlet, once it's rested a moment.
    @ObservationIgnored private var hoverIntent: Inlet.Mode?
    /// Keeps the hit area honest while the Inlet is out: the mouse-move monitors don't
    /// fire for a pointer that's still, or (once tilde has the keyboard) at all.
    @ObservationIgnored private var pointerTimer: Timer?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var observers: [Any] = []
    /// tilde's messages already shown, so each peeks out once.
    @ObservationIgnored private var seen: Set<String>
    /// A job opened from the conversation closes back to it, as a detail does in a messaging app.
    @ObservationIgnored private var backToConversation = false
    /// Where the pointer was when the current peek came out: one already resting there didn't come for it.
    @ObservationIgnored private var pointerAtPeek: CGPoint?

    init(model: AppModel, lens: LensController) {
        self.model = model
        self.lens = lens
        seen = Set(model.thread.map(\.id))
        observe { [weak self] in self?.threadChanged() }
    }

    var actions: InletActions {
        InletActions(
            send: { [weak self] in self?.send($0) },
            openJob: { [weak self] in self?.openJob($0) },
            compose: { [weak self] in if self?.inlet.mode != .compose { self?.set(.compose) } },
            dismiss: { [weak self] in self?.dismiss() })
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

    /// `focus: false` shows a mode that wants the keyboard without taking it (debug routes,
    /// so screenshots never steal what you're typing).
    func set(_ mode: Inlet.Mode, focus: Bool = true) {
        guard inlet.mode != mode else { return }
        inlet.mode = mode
        // A peek's timer belongs to that peek.
        settleTask?.cancel()
        if case .peek = mode { pointerAtPeek = NSEvent.mouseLocation }
        if mode != .open { pinnedOpen = false }
        if mode == .rest { exchangeTarget = nil }
        // Held news is told while you're looking.
        model.conductor?.looking = inlet.isConversation
        panel?.acceptsKey = inlet.wantsKey && focus
        if inlet.wantsKey && focus {
            NSApp.activate()
            panel?.makeKey()
        } else if panel?.isKeyWindow == true {
            panel?.resignKey()
            NSApp.hide(nil)
        }
        watchPointer(mode != .rest)
    }

    /// Clicking somewhere else puts the Inlet away; an unsent draft waits in the composer for next time.
    private func resignedKey() {
        switch inlet.mode {
        case .job, .compose: set(.rest)
        default: break
        }
    }

    // MARK: Talking

    /// A tap of the tilde key: the conversation opens with the composer ready.
    func compose(about referent: Referent?, focus: Bool = true) {
        exchangeTarget = referent
        if let referent { lens.flash(on: referent) }
        set(.compose, focus: focus)
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
        // "This" belonged to what you just said; the next thing starts fresh.
        exchangeTarget = nil
        if let reply = model.thread.last, reply.from == .tilde {
            seen.insert(reply.id)
            set(.peek(reply.id))
        } else {
            set(.rest)
        }
    }

    func openJob(_ job: Job, focus: Bool = true) {
        backToConversation = inlet.isConversation
        set(.job(job.id), focus: focus)
    }

    /// Put away what's showing: a job opened from the conversation goes back to it (keeping the keyboard, so
    /// it doesn't slip away while the pointer is still where the job was); anything else, to rest.
    private func dismiss() {
        if case .job = inlet.mode, backToConversation {
            backToConversation = false
            set(.compose)
        } else {
            set(.rest)
        }
    }

    /// New words from tilde peek out of the edge, unless the conversation is
    /// already open; the peek settles once it's been read.
    private func threadChanged() {
        let thread = model.thread
        let fresh = thread.filter { $0.from == .tilde && !seen.contains($0.id) }
        seen.formUnion(thread.map(\.id))

        if let latest = fresh.last, inlet.mode == .rest || isPeek {
            set(.peek(latest.id))
        }
        guard case .peek(var id) = inlet.mode else { return }
        // The reply it was showing is gone (what you said never got through): show that instead, with Try again.
        if !thread.contains(where: { $0.id == id }) {
            guard let failed = thread.last(where: { if case .failed = $0.delivery { true } else { false } }) else { return set(.rest) }
            id = failed.id
            set(.peek(id))
        }
        if let message = thread.first(where: { $0.id == id }), !message.streaming { settle(id, after: linger(for: message)) }
    }

    /// Long enough to read; questions stay a little longer.
    private func linger(for message: Message) -> Duration {
        if message.attentionID != nil { return .seconds(12) }
        let words = (message.text + message.noted.joined(separator: " ")).split(separator: " ").count
        return .seconds(min(20, 4 + Double(words) * 0.3))
    }

    private var isPeek: Bool { if case .peek = inlet.mode { true } else { false } }

    /// Returns the peek of `id` to rest after a while, unless you're using it.
    private func settle(_ id: String, after delay: Duration) {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, case .peek(let showing) = self.inlet.mode, showing == id,
                !self.inletRect.insetBy(dx: -16, dy: -16).contains(NSEvent.mouseLocation)
            else { return }
            self.set(.rest)
        }
    }

    // MARK: Pointer

    /// For the debug route: where the Inlet is and whether it's taking the mouse.
    var hitDescription: String {
        "panel \(panel?.frame ?? .zero) hit \(inletRect) ignoring \(panel?.ignoresMouseEvents ?? true) mouse \(NSEvent.mouseLocation)"
    }

    /// The shape the Inlet is becoming, on screen in Cocoa coordinates: the same shape the
    /// view draws (the panel's content fills it, top-left origin), so the two never disagree.
    private var inletRect: CGRect {
        guard let panel else { return .zero }
        let look = inlet.look(busy: !model.openJobs.isEmpty || !model.attention.isEmpty)
        let local = inlet.shape(for: look).body(in: CGRect(origin: .zero, size: panel.frame.size))
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

    /// While the Inlet is out, checks the pointer a few dozen times a second. At rest, the
    /// monitors are enough: the pointer is over other apps, which always report it.
    private func watchPointer(_ on: Bool) {
        guard on != (pointerTimer != nil) else { return }
        pointerTimer?.invalidate()
        pointerTimer = nil
        guard on else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
        pointerMoved()
    }

    private func pointerMoved() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let rect = inletRect
        let taking = rect.contains(mouse)
        if panel.ignoresMouseEvents == taking { panel.ignoresMouseEvents = !taking }
        hover(toward: intent(at: mouse, in: rect))
    }

    /// What the pointer resting here asks of the Inlet: open it at the edge, put it away
    /// once it has wandered off. Nil when it should stay as it is.
    private func intent(at mouse: CGPoint, in rect: CGRect) -> Inlet.Mode? {
        switch inlet.mode {
        case .rest, .peek:
            // Not mid-drag (a window, a file, a selection carried to the edge), not for a peek that came
            // out under a pointer that was just resting there, and not a question's peek, whose buttons
            // would move away as the conversation opened under the pointer (its mark opens it instead).
            if NSEvent.pressedMouseButtons != 0 { return nil }
            if case .peek(let id) = inlet.mode {
                if let at = pointerAtPeek, hypot(mouse.x - at.x, mouse.y - at.y) < 4 { return nil }
                if let asked = model.thread.first(where: { $0.id == id })?.attentionID, model.attention.contains(where: { $0.id == asked }) {
                    return nil
                }
            }
            // At rest the target is the sliver plus a band along the very edge.
            let slop: CGFloat = inlet.mode == .rest ? 10 : 16
            let hot = rect.insetBy(dx: -slop, dy: -slop).contains(mouse)
                || (inlet.mode == .rest && inlet.placement.edge.bezelBand(beside: rect).contains(mouse))
            return hot ? .open : nil
        case .open:
            return pinnedOpen || rect.insetBy(dx: -16, dy: -16).contains(mouse) ? nil : .rest
        case .compose:
            let idle = panel?.isKeyWindow != true
            return idle && !rect.insetBy(dx: -16, dy: -16).contains(mouse) ? .rest : nil
        case .listening, .job:
            return nil
        }
    }

    /// Moves toward `mode` once the pointer has stayed put long enough; a change of
    /// heart before then calls it off.
    private func hover(toward mode: Inlet.Mode?) {
        guard mode != hoverIntent else { return }
        hoverTask?.cancel()
        hoverIntent = mode
        guard let mode else { return }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: mode == .open ? .milliseconds(200) : .milliseconds(380))
            guard !Task.isCancelled, let self else { return }
            self.hoverIntent = nil
            self.set(mode)
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
