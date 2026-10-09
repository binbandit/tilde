import Foundation
import TildeMemory
import TildeSupport

/// A standing objective tilde works toward until it's done, kept as `goals/<slug>.md`:
///
///     ---
///     kind: goal
///     status: active
///     check-in: 2026-10-09 17:00
///     project: /Users/b/Developer/frontend/paradise
///     ---
///     # Ship paradise's checkout
///
///     ## Objective
///     ## Done when
///     ## Plan
///     ## Log
///     - 2026-10-09 10:02 Delegated the cart summary (j-abc1).
///
/// A typed view over the note, so whatever else the owner writes in it survives tilde's edits.
/// When the check-in passes, the goal reaches the manager as `<due>`.
public struct Goal: Sendable, Equatable {
    public enum Status: String, Sendable, CaseIterable { case active, paused, done }

    public private(set) var note: Note

    public init(
        title: String, objective: String, doneWhen: String, plan: String = "", project: String? = nil, checkIn: Date? = nil,
        created: Date = .now
    ) {
        note = Note(path: "goals/\(IDs.slug(title, limit: 48)).md", kind: "goal", title: title)
        note.set("status", [Status.active.rawValue])
        note.sections = [("Objective", objective), ("Done when", doneWhen), ("Plan", plan), ("Log", "")]
        self.checkIn = checkIn
        self.project = project
        note.set("created", [LocalTime.format(created)])
    }

    public init?(note: Note) {
        guard note.path.hasPrefix("goals/") else { return nil }
        self.note = note
    }

    public var path: String { note.path }
    public var slug: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
    public var title: String { note.title }

    public var status: Status {
        get { note.values("status").first.flatMap { Status(rawValue: $0.lowercased()) } ?? .active }
        set { note.set("status", [newValue.rawValue]) }
    }

    /// When tilde next reviews it.
    public var checkIn: Date? {
        get { note.values("check-in").first.flatMap { LocalTime.parse($0) } }
        set { set("check-in", newValue.map { LocalTime.format($0) }) }
    }

    /// The repo it's about, if any.
    public var project: String? {
        get { note.values("project").first }
        set { set("project", newValue.map { ($0 as NSString).expandingTildeInPath }) }
    }

    public var objective: String {
        get { section("Objective") }
        set { setSection("Objective", newValue) }
    }

    public var doneWhen: String {
        get { section("Done when") }
        set { setSection("Done when", newValue) }
    }

    public var plan: String {
        get { section("Plan") }
        set { setSection("Plan", newValue) }
    }

    /// Dated entries, oldest first.
    public var log: [String] {
        section("Log").components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
    }

    public mutating func log(_ entry: String, at date: Date = .now) {
        let line = "- \(LocalTime.format(date)) \(entry.replacingOccurrences(of: "\n", with: " "))"
        let body = section("Log")
        setSection("Log", body.isEmpty ? line : body + "\n" + line)
    }

    /// Active with a check-in that has come.
    public func isDue(at now: Date) -> Bool {
        status == .active && (checkIn.map { $0 <= now } ?? false)
    }

    /// One line for lists: what, its state, where, what done means, and the latest entry.
    public var digest: String {
        var facts = [status.rawValue]
        if let checkIn, status == .active { facts.append("check-in \(LocalTime.format(checkIn))") }
        if let project { facts.append((project as NSString).abbreviatingWithTildeInPath) }
        var line = "\(title) [\(facts.joined(separator: ", "))] (\(path))"
        let done = doneWhen.replacingOccurrences(of: "\n", with: " ")
        if !done.isEmpty { line += ". Done when: \(done.clipped(to: 200))" }
        if let last = log.last { line += ". Latest: \(last.clipped(to: 200))" }
        return line
    }

    // MARK: Reading the notebook

    /// Every goal in the notebook, by path.
    public static func all(in notebook: Notebook) -> [Goal] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: notebook.url.appending(path: "goals").path)) ?? []
        return files.filter { $0.hasSuffix(".md") }.sorted().compactMap { name in
            let path = "goals/\(name)"
            return notebook.read(path).flatMap { Goal(note: Note(path: path, parsing: $0)) }
        }
    }

    /// The goal `query` names: its slug or path, its title, or the one goal whose title contains it.
    public static func find(_ query: String, in notebook: Notebook) -> Goal? {
        let goals = all(in: notebook)
        let wanted = query.trimmingCharacters(in: .whitespaces)
        let slug = IDs.slug(((wanted as NSString).lastPathComponent as NSString).deletingPathExtension, limit: 48)
        if let exact = goals.first(where: { $0.slug == slug || $0.title.caseInsensitiveCompare(wanted) == .orderedSame }) { return exact }
        let partial = goals.filter { $0.title.localizedCaseInsensitiveContains(wanted) }
        return partial.count == 1 ? partial[0] : nil
    }

    // MARK: Note plumbing

    private func section(_ heading: String) -> String {
        note.sections.first { $0.heading.caseInsensitiveCompare(heading) == .orderedSame }?.body ?? ""
    }

    private mutating func setSection(_ heading: String, _ body: String) {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = note.sections.firstIndex(where: { $0.heading.caseInsensitiveCompare(heading) == .orderedSame }) {
            note.sections[i].body = body
        } else {
            note.sections.append((heading, body))
        }
    }

    private mutating func set(_ key: String, _ value: String?) {
        if let value { note.set(key, [value]) } else { note.meta.removeAll { $0.key == key } }
    }
}
