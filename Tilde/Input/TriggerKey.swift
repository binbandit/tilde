import AppKit

/// How you get tilde's attention, chosen in Settings (UserDefaults "trigger").
///
/// The default works on any keyboard: double-tap ⌥ to type, or tap once and
/// hold the second press to point and talk. Single-key choices (right ⌥,
/// right ⌘, Fn) work the same way with one press: tap to type, hold to talk.
/// In every mode a modifier used with another key is just a shortcut, and
/// tilde stays out of the way.
enum Trigger: String, CaseIterable {
    case doubleOption, doubleCommand, doubleControl
    case rightOption, rightCommand, fn

    static var current: Trigger {
        UserDefaults.standard.string(forKey: "trigger").flatMap(Trigger.init) ?? .doubleOption
    }

    /// Key codes that count as this trigger's key.
    var keyCodes: Set<UInt16> {
        switch self {
        case .doubleOption: [58, 61]
        case .doubleCommand: [54, 55]
        case .doubleControl: [59, 62]
        case .rightOption: [61]
        case .rightCommand: [54]
        case .fn: [63]
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .doubleOption, .rightOption: .option
        case .doubleCommand, .rightCommand: .command
        case .doubleControl: .control
        case .fn: .function
        }
    }

    var isDouble: Bool { [.doubleOption, .doubleCommand, .doubleControl].contains(self) }

    /// How to say it in hints ("double-tap ⌥").
    var hint: String {
        switch self {
        case .doubleOption: "double-tap ⌥ (hold the second tap to talk)"
        case .doubleCommand: "double-tap ⌘ (hold the second tap to talk)"
        case .doubleControl: "double-tap ⌃ (hold the second tap to talk)"
        case .rightOption: "tap right ⌥ (hold it to talk)"
        case .rightCommand: "tap right ⌘ (hold it to talk)"
        case .fn: "tap Fn (hold it to talk)"
        }
    }
}

@MainActor
final class TriggerKey {
    enum Event { case tap, holdBegan, holdEnded, cancelled }

    var onEvent: ((Event) -> Void)?

    /// A press longer than this is a hold.
    private let holdThreshold: TimeInterval = 0.28
    /// Double-tap: the first tap must be quick, and the second must follow soon after.
    private let tapMax: TimeInterval = 0.25
    private let gapMax: TimeInterval = 0.35

    private var trigger = Trigger.current
    private var downAt: Date?
    /// For double-tap triggers: when the first quick tap ended.
    private var armedAt: Date?
    private var holding = false
    private var chorded = false
    private var holdTimer: Timer?
    private var monitors: [Any] = []
    private var defaultsObserver: Any?

    func start() {
        let flags: (NSEvent) -> Void = { [weak self] event in self?.flagsChanged(event) }
        let keys: (NSEvent) -> Void = { [weak self] _ in self?.otherKey() }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { flags($0); return $0 } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in keys(event); return event } as Any)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func reload() {
        let next = Trigger.current
        guard next != trigger else { return }
        trigger = next
        reset()
    }

    private func reset() {
        holdTimer?.invalidate()
        downAt = nil
        armedAt = nil
        holding = false
        chorded = false
    }

    // MARK: Events

    private func flagsChanged(_ event: NSEvent) {
        guard trigger.keyCodes.contains(event.keyCode) else {
            // Another modifier joined in: it's a shortcut, not a tap.
            if downAt != nil || armedAt != nil { otherKey() }
            return
        }
        // Only the trigger modifier may be down, so ⌥⇧ and friends stay shortcuts.
        let others = event.modifierFlags.intersection([.command, .option, .control, .shift, .function]).subtracting(trigger.flag)
        let down = event.modifierFlags.contains(trigger.flag) && others.isEmpty

        if down, downAt == nil {
            pressed()
        } else if !down, let downAt {
            released(after: Date.now.timeIntervalSince(downAt))
        }
    }

    private func pressed() {
        downAt = .now
        chorded = false
        // A double-tap trigger only listens for a hold on its second press.
        let armed = armedAt.map { Date.now.timeIntervalSince($0) <= gapMax } ?? false
        guard !trigger.isDouble || armed else { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdThreshold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.downAt != nil, !self.chorded else { return }
                self.holding = true
                self.armedAt = nil
                self.onEvent?(.holdBegan)
            }
        }
    }

    private func released(after duration: TimeInterval) {
        holdTimer?.invalidate()
        defer {
            downAt = nil
            holding = false
        }
        if holding {
            onEvent?(.holdEnded)
            return
        }
        guard !chorded else {
            armedAt = nil
            return
        }
        guard trigger.isDouble else {
            onEvent?(.tap)
            return
        }
        if let armedAt, Date.now.timeIntervalSince(armedAt) <= gapMax + duration {
            self.armedAt = nil
            onEvent?(.tap)
        } else if duration <= tapMax {
            armedAt = .now
        } else {
            armedAt = nil
        }
    }

    private func otherKey() {
        armedAt = nil
        guard downAt != nil, !chorded else { return }
        chorded = true
        holdTimer?.invalidate()
        if holding {
            holding = false
            onEvent?(.cancelled)
        }
    }
}
