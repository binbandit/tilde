import Foundation

/// One markdown note in the notebook.
///
///     ---
///     kind: project
///     aliases: [paradise app, the paradise one]
///     paths: [/Users/b/Developer/frontend/paradise]
///     updated: 2026-10-08
///     ---
///     # paradise
///
///     One-line summary.
///
///     ## Facts
///     - Uses pnpm and the Next.js app router. _(2026-10-08, observed)_
///
/// Facts are bullets that end with a provenance stamp, so every memory says when
/// tilde learned it and how.
public struct Note: Sendable, Equatable {
    public var path: String
    /// Frontmatter, in file order. Lists are written as `[a, b]`.
    public var meta: [(key: String, values: [String])]
    public var title: String
    public var intro: String
    public var sections: [(heading: String, body: String)]

    public static func == (a: Note, b: Note) -> Bool { a.render() == b.render() }

    public init(path: String, kind: String, title: String, intro: String = "") {
        self.path = path
        meta = [("kind", [kind])]
        self.title = title
        self.intro = intro
        sections = []
    }

    public init(path: String, parsing text: String) {
        self.path = path
        meta = []
        title = ""
        intro = ""
        sections = []

        var lines = text.components(separatedBy: "\n")[...]
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---", let end = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) {
            for line in lines[lines.startIndex + 1..<end] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("["), value.hasSuffix("]") {
                    value = String(value.dropFirst().dropLast())
                    meta.append((key, value.split(separator: ",").map { Note.unquote(String($0)) }.filter { !$0.isEmpty }))
                } else {
                    meta.append((key, value.isEmpty ? [] : [Note.unquote(value)]))
                }
            }
            lines = lines[(end + 1)...]
        }

        var heading: String?
        var body: [String] = []
        func flush() {
            let text = body.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if let heading { sections.append((heading, text)) } else { intro = text }
            body = []
        }
        for line in lines {
            if line.hasPrefix("# "), title.isEmpty, heading == nil, body.allSatisfy({ $0.isEmpty }) {
                title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("## ") {
                flush()
                heading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else {
                body.append(line)
            }
        }
        flush()
        if title.isEmpty { title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
    }

    public func render() -> String {
        var out = ""
        if !meta.isEmpty {
            out += "---\n"
            for (key, values) in meta {
                out += values.count == 1 && !["aliases", "paths"].contains(key)
                    ? "\(key): \(values[0])\n" : "\(key): [\(values.joined(separator: ", "))]\n"
            }
            out += "---\n"
        }
        out += "# \(title)\n"
        if !intro.isEmpty { out += "\n\(intro)\n" }
        for (heading, body) in sections {
            out += "\n## \(heading)\n"
            if !body.isEmpty { out += "\n\(body)\n" }
        }
        return out
    }

    // MARK: Metadata

    public func values(_ key: String) -> [String] { meta.first { $0.key == key }?.values ?? [] }

    public mutating func set(_ key: String, _ values: [String]) {
        if let i = meta.firstIndex(where: { $0.key == key }) { meta[i].values = values } else { meta.append((key, values)) }
    }

    public var kind: String { values("kind").first ?? "topic" }
    public var aliases: [String] { values("aliases") }
    public var paths: [String] { values("paths") }

    // MARK: Facts

    public struct Fact: Sendable, Hashable {
        public var section: String
        public var text: String
        public var stamp: String?
    }

    public var facts: [Fact] {
        sections.flatMap { section in
            section.body.components(separatedBy: "\n").compactMap { line -> Fact? in
                guard line.hasPrefix("- ") else { return nil }
                let (text, stamp) = Note.split(String(line.dropFirst(2)))
                return Fact(section: section.heading, text: text, stamp: stamp)
            }
        }
    }

    /// Adds a fact bullet under `section` (created if missing), or replaces `replacing`.
    public mutating func add(_ text: String, section: String, stamp: String, replacing old: Fact? = nil) {
        let line = "- \(text) _(\(stamp))_"
        if let old, let s = sections.firstIndex(where: { $0.heading == old.section }) {
            var lines = sections[s].body.components(separatedBy: "\n")
            if let i = lines.firstIndex(where: { $0.hasPrefix("- ") && Note.split(String($0.dropFirst(2))).text == old.text }) {
                lines[i] = line
                sections[s].body = lines.joined(separator: "\n")
                return
            }
        }
        if let s = sections.firstIndex(where: { $0.heading.caseInsensitiveCompare(section) == .orderedSame }) {
            sections[s].body = sections[s].body.isEmpty ? line : sections[s].body + "\n" + line
        } else {
            sections.append((section, line))
        }
    }

    /// Removes a fact bullet; returns true if one was removed.
    @discardableResult
    public mutating func remove(_ fact: Fact) -> Bool {
        guard let s = sections.firstIndex(where: { $0.heading == fact.section }) else { return false }
        var lines = sections[s].body.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.hasPrefix("- ") && Note.split(String($0.dropFirst(2))).text == fact.text })
        else { return false }
        lines.remove(at: i)
        sections[s].body = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        return true
    }

    /// Models often quote YAML scalars; the notebook's frontmatter doesn't need them.
    static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, let first = trimmed.first, first == trimmed.last, first == "\"" || first == "'" else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }

    /// "Uses pnpm. _(2026-10-08, tap)_" -> ("Uses pnpm.", "2026-10-08, tap")
    static func split(_ bullet: String) -> (text: String, stamp: String?) {
        guard bullet.hasSuffix(")_"), let open = bullet.range(of: " _(", options: .backwards) else {
            return (bullet.trimmingCharacters(in: .whitespaces), nil)
        }
        let stamp = bullet[open.upperBound..<bullet.index(bullet.endIndex, offsetBy: -2)]
        return (String(bullet[..<open.lowerBound]).trimmingCharacters(in: .whitespaces), String(stamp))
    }

    // MARK: Chunks

    /// Searchable pieces: the intro and each section, long sections split by bullets.
    public var chunks: [(heading: String, body: String)] {
        var out: [(String, String)] = []
        let header = ([title] + aliases).joined(separator: " · ")
        if !intro.isEmpty { out.append((header, intro)) }
        for (heading, body) in sections where !body.isEmpty {
            var current = ""
            for line in body.components(separatedBy: "\n") {
                if current.count + line.count > 1_200, !current.isEmpty {
                    out.append(("\(title) › \(heading)", current))
                    current = ""
                }
                current += current.isEmpty ? line : "\n" + line
            }
            if !current.isEmpty { out.append(("\(title) › \(heading)", current)) }
        }
        if out.isEmpty { out.append((header, title)) }
        return out
    }
}
