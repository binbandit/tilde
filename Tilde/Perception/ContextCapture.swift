import AppKit
import ApplicationServices
import Synchronization

/// Takes only identity and geometry before focus changes, then resolves the original target away
/// from the main thread. One instance belongs to one exchange, including any re-aims during a hold.
@MainActor
final class ContextCapture {
    typealias Collector = @Sendable (Pointing.Request) -> Referent?

    private let collect: Collector
    /// AX reads block (a quarter of a second a call against a hung app), so they take turns on
    /// their own queue instead of holding up Swift's shared threads.
    private let queue = DispatchQueue(label: "dev.tilde.context-capture")
    /// Only the latest request counts: older ones are skipped if they haven't started, and dropped if they have.
    private nonisolated let latest = Atomic<UInt64>(0)

    init(collect: @escaping Collector = Pointing.capture) { self.collect = collect }

    /// Hands back what `request` points at, unless something newer was asked for first. Finding
    /// nothing changes nothing, so what was found before stays until something replaces it.
    func start(_ request: Pointing.Request?, update: @escaping @MainActor @Sendable (Referent) -> Void) {
        let generation = latest.add(1, ordering: .relaxed).newValue
        guard let request else { return }
        let collect = collect
        queue.async {
            guard self.latest.load(ordering: .relaxed) == generation, let referent = collect(request) else { return }
            Task { @MainActor in
                if self.latest.load(ordering: .relaxed) == generation { update(referent) }
            }
        }
    }

    func cancel() {
        latest.add(1, ordering: .relaxed)
    }

    /// Call before making the Inlet key. This does no Accessibility or shell-process work.
    /// Passive composition captures a window without inspecting any selected text.
    static func snapshot(at point: CGPoint? = nil, includeSelection: Bool = false, fallbackToFrontmost: Bool = true) -> Pointing.Request? {
        let coordinates = Coordinates.snapshot
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontmost = (point == nil || fallbackToFrontmost ? NSWorkspace.shared.frontmostApplication : nil).flatMap { app -> Pointing.Application? in
            guard app.processIdentifier != ownPID else { return nil }
            return identity(app)
        }
        guard let point else {
            return frontmost.map {
                Pointing.Request(application: $0, point: nil, fallback: nil, coordinates: coordinates, includeSelection: includeSelection)
            }
        }

        let quartz = coordinates.quartz(point)
        // WindowServer metadata identifies the original owner without asking the app to respond.
        // Only owner and geometry are used; no window contents or screen permission are requested.
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let owner = windowOwner(at: quartz, windows: windows, excluding: ownPID)
        let pointed = owner.flatMap { pid -> Pointing.Application? in
            guard pid != ownPID, let app = NSRunningApplication(processIdentifier: pid) else { return nil }
            return identity(app)
        }

        if let pointed {
            return Pointing.Request(
                application: pointed, point: quartz, fallback: fallbackToFrontmost ? frontmost : nil,
                coordinates: coordinates, includeSelection: includeSelection)
        }
        guard fallbackToFrontmost, let frontmost else { return nil }
        return Pointing.Request(application: frontmost, point: nil, fallback: nil, coordinates: coordinates, includeSelection: includeSelection)
    }

    /// WindowServer lists front to back. Include floating app windows, but ignore our own Lens
    /// and Inlet so their overlays cannot turn a re-aim into a request about tilde itself.
    static func windowOwner(at point: CGPoint, windows: [[String: Any]], excluding ownPID: pid_t) -> pid_t? {
        windows.first { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point),
                let layer = window[kCGWindowLayer as String] as? Int, layer >= 0,
                (window[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { return false }
            return true
        }?[kCGWindowOwnerPID as String] as? pid_t
    }

    private static func identity(_ app: NSRunningApplication) -> Pointing.Application {
        Pointing.Application(name: app.localizedName ?? "App", bundleID: app.bundleIdentifier, pid: app.processIdentifier)
    }
}
