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
    private lazy var perception = MacPerception(schedule: model.schedule)
    private lazy var notifications = Notifications(model: model, inlet: inlet)
    private let presence = Presence()
    private var lensTracking: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // A hung app answers accessibility calls slowly, and tilde asks often: a quarter of a second each, not six.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
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
        listener.onUpdate = { [weak self] session, transcript, level in
            guard let self, self.voiceSession == session, self.inlet.ownsVoicePresentation(session) else { return }
            self.model.listening = AppModel.Listening(transcript: transcript, level: level)
            self.loudest = max(self.loudest, level)
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
            cancelListening()
            inlet.composeCapturingContext(at: NSEvent.mouseLocation, includeSelection: true)
        case .holdBegan:
            guard Permission.microphone.granted else {
                // Without the microphone, holding the key opens the composer instead, saying why.
                cancelListening()
                model.cantHear = true
                inlet.composeCapturingContext(at: NSEvent.mouseLocation, includeSelection: true)
                Task { _ = await Listener.requestAccess() }
                return
            }
            model.cantHear = false
            beginListening(at: NSEvent.mouseLocation)
        case .holdEnded:
            endListening(send: true)
        case .cancelled:
            endListening(send: false)
        }
    }

    /// When the current hold began, and the loudest the microphone heard during it: together, whether you
    /// actually tried to say something.
    private var holdBegan = Date.distantPast
    private var loudest = 0.0
    private var voiceSession: UUID?
    private var finishingVoiceSession: UUID?

    private func beginListening(at point: CGPoint) {
        if let lensTracking { NSEvent.removeMonitor(lensTracking) }
        let session = listener.begin()
        voiceSession = session
        finishingVoiceSession = nil
        holdBegan = .now
        loudest = 0
        model.listening = AppModel.Listening()
        inlet.listenCapturingContext(at: point, session: session)
        // Re-aim the Lens as the pointer moves while you talk.
        lensTracking = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.reaim() }
        }
        Task { await listener.start(session) }
    }

    private var lastAim = Date.distantPast

    private func reaim() {
        guard Date.now.timeIntervalSince(lastAim) > 0.06 else { return }
        lastAim = .now
        let point = NSEvent.mouseLocation
        inlet.reaim(at: point)
    }

    private func endListening(send: Bool) {
        // Reserve the ending hold before scheduling any async work. A later release or start
        // cannot make this task finish whichever session happens to be current when it runs.
        guard let session = voiceSession, finishingVoiceSession != session else { return }
        finishingVoiceSession = session
        listener.stop(session)
        let request = inlet.releaseVoice(session)
        if let lensTracking { NSEvent.removeMonitor(lensTracking) }
        lensTracking = nil
        let tried = Date.now.timeIntervalSince(holdBegan) > 1 && loudest > 0.2
        Task {
            let heard = await listener.finish(session)
            guard voiceSession == session else { return }
            voiceSession = nil
            finishingVoiceSession = nil
            if let request { inlet.heard(send ? heard ?? "" : "", from: request, cancelled: !send || !tried) }
        }
    }

    private func cancelListening() {
        voiceSession = nil
        finishingVoiceSession = nil
        listener.cancel()
        inlet.cancelVoiceExchange()
        if let lensTracking { NSEvent.removeMonitor(lensTracking) }
        lensTracking = nil
        model.listening = nil
    }

    // MARK: tilde:// routes

    private func route(_ url: URL) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in query.first { $0.name == name }?.value }
        switch url.host() {
        case "tap":
            cancelListening()
            // Anything can open a link, so a link only fills in the words: sending them is yours.
            model.draft = value("text") ?? ""
            inlet.composeCapturingContext()
        case "open":
            inlet.set(.open)
        case "settings":
            NSApp.activate()
            inlet.openSettings?()
        case "debug" where UserDefaults.standard.bool(forKey: DebugRoutes.enabledKey):
            DebugRoutes.route(url.path(), value: value, delegate: self)
        default:
            break
        }
    }
}
