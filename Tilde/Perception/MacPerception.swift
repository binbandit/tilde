import AppKit
import ApplicationServices
import TildeKit

/// What tilde knows about what you're doing: the app and window in front, the
/// directory your terminal is in, and a running log of where your time went.
/// Window titles only; no screenshots. The log stays on this Mac.
@MainActor
final class MacPerception: Perception {
    struct Span: Codable {
        var app: String
        var title: String?
        var path: String?
        var start: Date
        var end: Date
    }

    private var spans: [Span] = []
    private var current: Span?
    private var timer: Timer?
    private let logURL = TildeHome.default.state.appending(path: "activity.jsonl")
    private let calendar: Schedule

    init(schedule: Schedule) {
        calendar = schedule
    }

    func start() {
        load()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        sample()
    }

    // MARK: Perception

    func currentContext() -> TapContext {
        Pointing.frontmost()?.context ?? TapContext(app: NSWorkspace.shared.frontmostApplication?.localizedName)
    }

    func recentActivity(hours: Double) -> String {
        let since = Date.now.addingTimeInterval(-hours * 3600)
        var totals: [String: TimeInterval] = [:]
        for span in spans + [current].compactMap({ $0 }) where span.end > since {
            let key = [span.app, span.path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? span.title.map(Titles.short)]
                .compactMap { $0 }.joined(separator: " · ")
            totals[key, default: 0] += span.end.timeIntervalSince(max(span.start, since))
        }
        let top = totals.filter { $0.value > 60 }.sorted { $0.value > $1.value }.prefix(10)
        guard !top.isEmpty else { return "(no recorded activity)" }
        return top.map { "\($0.key): \(Int($0.value / 60))m" }.joined(separator: "\n")
    }

    func schedule(hours: Double) async -> String {
        let events = calendar.upcoming(hours: hours)
        let reminders = await calendar.remindersDue(days: 1)
        return [("Calendar", events), ("Reminders due", reminders)]
            .filter { !$0.1.isEmpty }
            .map { "\($0.0):\n\($0.1)" }
            .joined(separator: "\n")
    }

    // MARK: Sampling

    private func sample() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        let name = app.localizedName ?? "App"
        let window = Pointing.focusedWindow(app.processIdentifier)
        let title = window.flatMap { Pointing.string($0, kAXTitleAttribute) }
        var path = window.flatMap { Pointing.string($0, kAXDocumentAttribute) }.flatMap(Pointing.path(fromURL:))
        if path == nil, let bundle = app.bundleIdentifier, Pointing.terminals.contains(bundle) {
            path = Shells.cwd(forTerminal: app.processIdentifier, title: title)
        }
        path = Repos.root(containing: path) ?? path

        if var span = current, span.app == name, span.title == title, span.path == path {
            span.end = .now
            current = span
            return
        }
        if var finished = current {
            finished.end = .now
            spans.append(finished)
            persist(finished)
        }
        current = Span(app: name, title: title, path: path, start: .now, end: .now)
        spans.removeAll { $0.end < .now.addingTimeInterval(-86_400) }
    }

    private func persist(_ span: Span) {
        guard span.end.timeIntervalSince(span.start) > 5, let data = try? JSONEncoder().encode(span) else { return }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }

    private func load() {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        let since = Date.now.addingTimeInterval(-86_400)
        spans = text.split(separator: "\n").suffix(5_000).compactMap { try? decoder.decode(Span.self, from: Data($0.utf8)) }.filter { $0.end > since }
    }
}
