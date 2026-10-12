import AppKit
import ApplicationServices

/// Takes only identity and geometry before focus changes, then resolves the original target away
/// from the main actor. One instance belongs to one exchange, including any re-aims during a hold.
@MainActor
final class ContextCapture {
    typealias Collector = @Sendable (Pointing.Request) -> Referent?

    private actor Reader {
        let collect: Collector

        init(collect: @escaping Collector) { self.collect = collect }

        func read(_ request: Pointing.Request) -> Referent? {
            // A slow app can hold up one request. Superseded requests waiting behind it do no AX work.
            guard !Task.isCancelled else { return nil }
            return collect(request)
        }
    }

    private let reader: Reader
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(collect: @escaping Collector = Pointing.capture) { reader = Reader(collect: collect) }

    /// Invalidate the previous target immediately, before waiting on a new read.
    /// Otherwise sending while re-aim B is pending could still attach accepted aim A.
    /// Updates deliver nil first and then the active result, even when that is nil.
    func start(_ request: Pointing.Request?, update: @escaping @MainActor (Referent?) -> Void) {
        cancel()
        update(nil)
        guard let request else { return }
        let generation = generation
        let reader = reader
        task = Task { [weak self] in
            let result = await reader.read(request)
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.task = nil
            update(result)
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
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
