import Foundation
import TildeSupport

/// tilde's memory: the notebook (truth), its index (recall), and the rules for
/// reading and writing it.
///
/// Recall is automatic: before the manager sees a message, `briefing` pulls in
/// the notes it's about and the most relevant facts, so remembering never
/// depends on the model deciding to look. Writes go through `remember`, which
/// files each fact in the right note with a date and source, and replaces the
/// fact it supersedes instead of piling up contradictions.
public actor Memory {
    public struct Recalled: Sendable, Hashable {
        public var path: String
        public var heading: String
        public var text: String
    }

    public enum Kind: String, Sendable, Codable { case me, project, topic }

    public struct Written: Sendable, Hashable {
        public var path: String
        public var fact: String
        /// The older fact this one replaced, if any.
        public var replaced: String?
    }

    /// A repo on this Mac that a project note can point at.
    public struct Project: Sendable, Hashable {
        public var name: String
        public var path: String

        public init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    public nonisolated let notebook: Notebook
    private let index: MemoryIndex
    /// The repo that best matches a name, so project notes can learn their path.
    private let findProject: @Sendable (_ name: String) async -> Project?
    private var lastCore: String?

    public init(home: TildeHome, findProject: @escaping @Sendable (_ name: String) async -> Project? = { _ in nil }) throws {
        try home.prepare()
        notebook = Notebook(url: home.notebook)
        index = try MemoryIndex(database: home.state.appending(path: "memory.sqlite"), notebook: home.notebook)
        self.findProject = findProject
    }

    public func prepare() async throws {
        try await notebook.prepare()
        try index.sync()
    }

    /// Re-indexes after something else (the dream, Brayden's editor) changed notes.
    public func refresh() {
        _ = try? index.sync()
    }

    // MARK: Reading

    /// Who Brayden is and the rules: small, and always worth having.
    public func core() -> String {
        ["me.md", "rules.md"].compactMap { name in
            notebook.read(name).map { "<note path=\"\(name)\">\n\($0.trimmingCharacters(in: .whitespacesAndNewlines))\n</note>" }
        }.joined(separator: "\n")
    }

    /// The memory block that precedes a manager turn. `nil` when nothing is relevant.
    public func briefing(for text: String, paths: [String] = [], jobs: [String] = []) -> String? {
        refresh()
        // The core rides along whenever it changed since the manager last saw it.
        let core = core()
        let changed = core != lastCore
        lastCore = core
        return context(for: text, paths: paths, jobs: jobs, core: changed ? core : nil)
    }

    /// A fresh model session needs the whole core without consuming the manager's next update.
    public func context(for text: String) -> String? {
        refresh()
        return context(for: text, paths: [], jobs: [], core: core())
    }

    private func context(for text: String, paths: [String], jobs: [String], core: String?) -> String? {
        var blocks = core.map { [$0] } ?? []

        var included: Set<String> = ["me.md", "rules.md"]
        for path in jobs.map({ "tasks/\($0).md" }) + index.notes(mentionedIn: text, paths: paths) where !included.contains(path) {
            guard let body = notebook.read(path) else { continue }
            included.insert(path)
            blocks.append("<note path=\"\(path)\">\n\(body.clipped(to: 2_400, keepLines: true))\n</note>")
            if included.count > 6 { break }
        }

        let hits = index.search(text, limit: 6, excluding: included)
        if !hits.isEmpty {
            blocks.append(hits.map { "<recall path=\"\($0.path)\" section=\"\($0.heading)\">\n\($0.body)\n</recall>" }
                .joined(separator: "\n"))
        }
        return blocks.isEmpty ? nil : "<memory>\n\(blocks.joined(separator: "\n"))\n</memory>"
    }

    public func recall(_ query: String, limit: Int = 8) -> [Recalled] {
        refresh()
        return index.search(query, limit: limit).map { Recalled(path: $0.path, heading: $0.heading, text: $0.body) }
    }

    /// Forces the core into the next briefing (a new manager session starts blank).
    public func resetBriefing() { lastCore = nil }

    // MARK: Writing

    /// Files `fact` under the note for `about`, replacing a fact it supersedes.
    @discardableResult
    public func remember(
        _ fact: String, about: String, kind: Kind? = nil, section: String = "Facts", replaces: String? = nil,
        source: String
    ) async throws -> Written {
        let fact = Self.clean(fact)
        guard !fact.isEmpty, !Self.looksSecret(fact) else {
            throw Notebook.Refused(description: "That looks like a secret; tilde doesn't keep those.")
        }
        var note = await note(about: about, kind: kind)
        // Rules are permissions: only the owner adds one (Notebook.addRule, from their "Always").
        guard note.path != "rules.md" else {
            throw Notebook.Refused(description: "Rules are \(Owner.firstName)'s to write; ask them, or note it as a preference instead.")
        }
        let stamp = "\(Date.now.day), \(source)"

        let old = supersededFact(in: note, by: fact, hint: replaces)
        note.add(fact, section: old?.section ?? section, stamp: stamp, replacing: old)
        note.set("updated", [Date.now.day])
        try write(note)
        await notebook.commitChanges(context: old == nil ? "remember" : "revise")
        refresh()
        return Written(path: note.path, fact: fact, replaced: old?.text)
    }

    /// Removes the fact about `about` that best matches `fact`.
    @discardableResult
    public func forget(_ fact: String, about: String) async throws -> String? {
        var note = await note(about: about, kind: nil)
        guard note.path != "rules.md" else {
            throw Notebook.Refused(description: "Rules are \(Owner.firstName)'s to write.")
        }
        guard let match = supersededFact(in: note, by: fact, hint: fact, threshold: 0.9) else { return nil }
        note.remove(match)
        try write(note)
        await notebook.commitChanges(context: "forget")
        refresh()
        return match.text
    }

    /// Replaces a whole note (the dream and the manager's rewrites).
    public func rewrite(_ path: String, _ text: String, reason: String) async throws {
        guard path != "rules.md" else { throw Notebook.Refused(description: "Rules are \(Owner.firstName)'s to write.") }
        let url = notebook.url.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        await notebook.commitChanges(context: reason)
        refresh()
    }

    /// The note a subject lives in, loaded or freshly created (not yet written).
    func note(about subject: String, kind: Kind?) async -> Note {
        let path = await resolve(subject, kind: kind)
        if let text = notebook.read(path) { return Note(path: path, parsing: text) }

        switch path {
        case "me.md": return Note(path: path, kind: "me", title: "Me")
        case _ where path.hasPrefix("projects/"):
            var note = Note(path: path, kind: "project", title: ((path as NSString).lastPathComponent as NSString).deletingPathExtension)
            let expanded = (subject as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                note.set("paths", [expanded])
            } else if let repo = await findProject(subject), repo.name.caseInsensitiveCompare(subject) == .orderedSame {
                note.set("paths", [repo.path])
            }
            if !expanded.hasPrefix("/"), subject.lowercased() != note.title.lowercased() { note.set("aliases", [subject]) }
            return note
        default:
            return Note(path: path, kind: "topic", title: subject)
        }
    }

    /// Maps "me", a project name or alias, a path, or a topic to a note path.
    func resolve(_ subject: String, kind: Kind?) async -> String {
        let lowered = subject.trimmingCharacters(in: .whitespaces).lowercased()
        if kind == .me || ["me", "user", "owner", Owner.firstName.lowercased()].contains(lowered) { return "me.md" }
        if lowered == "rules" { return "rules.md" }
        let expanded = (subject as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            if let hit = index.entities.first(where: { $0.isPath && Paths.isInside(expanded, $0.term) }) { return hit.path }
            return "projects/\(IDs.slug((expanded as NSString).lastPathComponent)).md"
        }
        if let hit = index.entities.first(where: { !$0.isPath && $0.term == lowered }) { return hit.path }
        var isProject = kind == .project
        if kind == nil { isProject = await findProject(subject)?.name.lowercased() == lowered }
        return isProject ? "projects/\(IDs.slug(subject)).md" : "topics/\(IDs.slug(subject)).md"
    }

    /// The fact in `note` that `fact` updates: the hinted text, the same words, or
    /// a near-identical sentence (raw similarity this high means a restatement, or
    /// a reversal like "prefers X over Y", which the newer fact should replace too).
    private func supersededFact(in note: Note, by fact: String, hint: String?, threshold: Float = 0.95) -> Note.Fact? {
        let facts = note.facts
        if let hint = hint.map(Self.key), !hint.isEmpty {
            if let exact = facts.first(where: { Self.key($0.text) == hint }) { return exact }
            if let contained = facts.first(where: { Self.key($0.text).contains(hint) }) { return contained }
        }
        if let same = facts.first(where: { Self.key($0.text) == Self.key(fact) }) { return same }
        guard let target = index.vector(hint ?? fact) else { return nil }
        return facts
            .compactMap { f in index.vector(f.text).map { (f, Embedder.similarity(target, $0)) } }
            .filter { $0.1 >= threshold }
            .max { $0.1 < $1.1 }?.0
    }

    private func write(_ note: Note) throws {
        let url = notebook.url.appending(path: note.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try note.render().write(to: url, atomically: true, encoding: .utf8)
    }

    /// Case- and punctuation-blind form for comparing facts.
    static func key(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines.union(["-", "*"]))
    }

    /// Tokens, keys and passwords never go in the notebook.
    static func looksSecret(_ text: String) -> Bool {
        let patterns = [
            #"(sk|pk|rk)-[A-Za-z0-9_-]{16,}"#, #"gh[pousr]_[A-Za-z0-9]{20,}"#, #"xox[abposr]-[A-Za-z0-9-]{10,}"#,
            #"AKIA[0-9A-Z]{16}"#, #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, #"(?i)(password|passwd|secret|token)\s*[:=]\s*\S{6,}"#,
            #"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\."#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}
