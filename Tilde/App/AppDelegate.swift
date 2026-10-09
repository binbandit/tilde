import AppKit
import TildeKit
import UserNotifications

/// Wires the senses (trigger key, pointing, voice) to the brain and the surfaces.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let lens = LensController()
    private(set) lazy var inlet = InletController(model: model, lens: lens)
    private let trigger = TriggerKey()
    private let listener = Listener()
    private let perception = MacPerception()
    private lazy var notifications = Notifications(model: model, inlet: inlet)
    private let presence = Presence()
    private var lensTracking: Any?
    private var tapPoint: CGPoint = .zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.conductor?.perception = perception
        perception.start()

        Task {
            do { try await model.conductor?.start() } catch { Log.info("app", "start failed: \(error)") }
        }
        if let conductor = model.conductor {
            Task { for await signal in conductor.signals { notifications.handle(signal) } }
            // Back after a while: tilde says what happened while you were away, if anything did.
            presence.onReturn = { [weak conductor] away in conductor?.welcomeBack(after: away) }
            presence.start()
        }
        notifications.start()

        trigger.onEvent = { [weak self] in self?.trigger($0) }
        trigger.start()
        listener.onUpdate = { [weak self] transcript, level in
            self?.model.listening = AppModel.Listening(transcript: transcript, level: level)
        }
        inlet.show()

        if !Pointing.isTrusted { Pointing.requestTrust() }
        Task { _ = await Listener.requestAccess() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(route)
    }

    // MARK: The tilde key

    private func trigger(_ event: TriggerKey.Event) {
        switch event {
        case .tap:
            inlet.compose(about: Pointing.referent(at: NSEvent.mouseLocation) ?? Pointing.frontmost())
        case .holdBegan:
            beginListening(at: NSEvent.mouseLocation)
        case .holdEnded:
            Task { await endListening(send: true) }
        case .cancelled:
            Task { await endListening(send: false) }
        }
    }

    private func beginListening(at point: CGPoint) {
        tapPoint = point
        let referent = Pointing.referent(at: point) ?? Pointing.frontmost()
        if let referent { lens.show(on: referent) }
        model.listening = AppModel.Listening()
        inlet.listen(about: referent)
        // Re-aim the Lens as the pointer moves while you talk.
        lensTracking = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.reaim() }
        }
        Task { await listener.start() }
    }

    private var lastAim = Date.distantPast

    private func reaim() {
        guard Date.now.timeIntervalSince(lastAim) > 0.06 else { return }
        lastAim = .now
        let point = NSEvent.mouseLocation
        guard let referent = Pointing.referent(at: point), referent != lens.target else { return }
        inlet.exchangeTarget = referent
        lens.show(on: referent)
    }

    private func endListening(send: Bool) async {
        if let lensTracking { NSEvent.removeMonitor(lensTracking) }
        lensTracking = nil
        let heard = await listener.finish()
        model.listening = nil
        inlet.heard(send ? heard : "")
    }

    // MARK: tilde:// routes

    private func route(_ url: URL) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in query.first { $0.name == name }?.value }
        switch url.host() {
        case "tap":
            inlet.exchangeTarget = Pointing.frontmost()
            inlet.send(value("text") ?? "")
        case "open":
            inlet.set(.open)
        case "settings":
            NSApp.activate()
            inlet.openSettings?()
        case "debug":
            DebugRoutes.route(url.path(), value: value, delegate: self)
        default:
            break
        }
    }
}
