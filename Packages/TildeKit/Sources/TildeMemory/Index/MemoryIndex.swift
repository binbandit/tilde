import CryptoKit
import Foundation
import TildeSupport

/// A derived, rebuildable search index over the notebook: SQLite FTS5 for words,
/// on-device embeddings for meaning, and an entity table (titles, aliases, paths)
/// for resolving what a message is about. The notebook stays the source of truth.
final class MemoryIndex {
    struct Hit: Sendable, Hashable {
        var path: String
        var heading: String
        var body: String
        var score: Double
    }

    struct Entity: Sendable, Hashable {
        var term: String
        var path: String
        var isPath: Bool
    }

    private let db: SQLite
    private let embedder = Embedder()
    private let root: URL
    /// Mean-centered chunk vectors, ready to rank against a centered query.
    private var vectors: [Int64: [Float]] = [:]
    private var center: [Float]?
    private(set) var entities: [Entity] = []

    /// Bump when chunking, parsing or embedding changes: the index rebuilds itself.
    static let version = 3

    init(database: URL, notebook: URL) throws {
        root = notebook
        db = try SQLite(path: database.path)
        if try db.query("PRAGMA user_version").first?.first?.int != Int64(Self.version) {
            try db.exec("DROP TABLE IF EXISTS files; DROP TABLE IF EXISTS chunks; DROP TABLE IF EXISTS vectors; DROP TABLE IF EXISTS entities;")
            try db.exec("PRAGMA user_version = \(Self.version)")
        }
        try db.exec("""
            CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, signature TEXT);
            CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(path UNINDEXED, heading, body, tokenize='porter unicode61');
            CREATE TABLE IF NOT EXISTS vectors(id INTEGER PRIMARY KEY, path TEXT, vector BLOB);
            CREATE TABLE IF NOT EXISTS entities(term TEXT, path TEXT, is_path INTEGER);
            """)
        try loadCaches()
    }

    // MARK: Sync

    /// Re-indexes notes that changed on disk; returns their paths.
    @discardableResult
    func sync() throws -> [String] {
        let onDisk = Dictionary(uniqueKeysWithValues: noteFiles().map { ($0, signature(of: $0)) })
        let known = Dictionary(uniqueKeysWithValues: try db.query("SELECT path, signature FROM files").compactMap { row in
            row[0].text.map { ($0, row[1].text ?? "") }
        })
        let changed = onDisk.filter { known[$0.key] != $0.value }.map(\.key)
        let removed = known.keys.filter { onDisk[$0] == nil }
        guard !changed.isEmpty || !removed.isEmpty else { return [] }

        try db.transaction {
            for path in changed + removed { try forget(path) }
            for path in changed {
                let text = (try? String(contentsOf: root.appending(path: path), encoding: .utf8)) ?? ""
                try index(Note(path: path, parsing: text))
                try db.run("INSERT INTO files(path, signature) VALUES(?, ?)", [.text(path), .text(onDisk[path]!)])
            }
        }
        try loadCaches()
        return changed
    }

    private func forget(_ path: String) throws {
        try db.run("DELETE FROM chunks WHERE path = ?", [.text(path)])
        try db.run("DELETE FROM vectors WHERE path = ?", [.text(path)])
        try db.run("DELETE FROM entities WHERE path = ?", [.text(path)])
        try db.run("DELETE FROM files WHERE path = ?", [.text(path)])
    }

    private func index(_ note: Note) throws {
        for chunk in note.chunks {
            let id = try db.run(
                "INSERT INTO chunks(path, heading, body) VALUES(?, ?, ?)",
                [.text(note.path), .text(chunk.heading), .text(chunk.body)])
            if let vector = embedder.vector("\(chunk.heading). \(chunk.body)") {
                try db.run("INSERT INTO vectors(id, path, vector) VALUES(?, ?, ?)", [.int(id), .text(note.path), .blob(Embedder.encode(vector))])
            }
        }
        let stem = ((note.path as NSString).lastPathComponent as NSString).deletingPathExtension
        let terms = Set(([note.title, stem] + note.aliases).map { $0.lowercased() }.filter { $0.count >= 3 })
        for term in terms {
            try db.run("INSERT INTO entities(term, path, is_path) VALUES(?, ?, 0)", [.text(term), .text(note.path)])
        }
        for path in note.paths {
            try db.run("INSERT INTO entities(term, path, is_path) VALUES(?, ?, 1)", [.text((path as NSString).expandingTildeInPath), .text(note.path)])
        }
    }

    private func loadCaches() throws {
        let raw: [Int64: [Float]] = Dictionary(uniqueKeysWithValues: try db.query("SELECT id, vector FROM vectors").compactMap { row in
            guard let id = row[0].int, let blob = row[1].blob else { return nil }
            return (id, Embedder.decode(blob))
        })
        center = Embedder.mean(Array(raw.values) + embedder.background)
        vectors = center.map { center in raw.mapValues { Embedder.centered($0, center) } } ?? [:]
        entities = try db.query("SELECT term, path, is_path FROM entities").compactMap { row in
            guard let term = row[0].text, let path = row[1].text else { return nil }
            return Entity(term: term, path: path, isPath: row[2].int == 1)
        }
    }

    private func noteFiles() -> [String] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var files: [String] = []
        for case let url as URL in walker {
            if url.lastPathComponent == ".git" { walker.skipDescendants(); continue }
            // The notebook's README describes the notebook; it isn't a memory.
            guard url.pathExtension == "md", url.lastPathComponent != "README.md" else { continue }
            files.append(String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)))
        }
        return files
    }

    private func signature(of path: String) -> String {
        let data = (try? Data(contentsOf: root.appending(path: path))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Search

    /// Hybrid recall: keyword (BM25) and meaning (cosine) rankings fused with
    /// reciprocal rank fusion, so either signal alone can surface a memory.
    /// Keyword matches are the more precise signal, so they weigh a little more.
    func search(_ query: String, limit: Int = 6, excluding: Set<String> = []) -> [Hit] {
        var fused: [Int64: Double] = [:]
        var rows: [Int64: (String, String, String)] = [:]

        let terms = Self.terms(query)
        if !terms.isEmpty {
            let match = terms.map { "\"\($0)\"" }.joined(separator: " OR ")
            let keyword = (try? db.query(
                "SELECT rowid, path, heading, body FROM chunks WHERE chunks MATCH ? ORDER BY bm25(chunks, 0, 2.0, 1.0) LIMIT 40",
                [.text(match)])) ?? []
            for (rank, row) in keyword.enumerated() {
                guard let id = row[0].int else { continue }
                fused[id, default: 0] += 1.0 / Double(60 + rank)
                rows[id] = (row[1].text ?? "", row[2].text ?? "", row[3].text ?? "")
            }
        }

        if let center, let raw = embedder.vector(query) {
            let q = Embedder.centered(raw, center)
            let ranked = vectors.map { ($0.key, Embedder.similarity(q, $0.value)) }
                .filter { $0.1 > 0.1 }
                .sorted { $0.1 > $1.1 }
                .prefix(40)
            for (rank, (id, _)) in ranked.enumerated() { fused[id, default: 0] += 0.7 / Double(60 + rank) }
        }

        let missing = fused.keys.filter { rows[$0] == nil }
        if !missing.isEmpty {
            let list = missing.map(String.init).joined(separator: ",")
            for row in (try? db.query("SELECT rowid, path, heading, body FROM chunks WHERE rowid IN (\(list))")) ?? [] {
                if let id = row[0].int { rows[id] = (row[1].text ?? "", row[2].text ?? "", row[3].text ?? "") }
            }
        }

        // Drop the long tail: anything far weaker than the best match is noise in a briefing.
        let best = fused.values.max() ?? 0
        return fused.sorted { $0.value > $1.value }
            .filter { $0.value >= best * 0.6 }
            .compactMap { id, score in rows[id].map { Hit(path: $0.0, heading: $0.1, body: $0.2, score: score) } }
            .filter { !excluding.contains($0.path) }
            .prefix(limit)
            .map { $0 }
    }

    /// Notes the text or paths are about: path containment first, then names and aliases.
    func notes(mentionedIn text: String, paths: [String]) -> [String] {
        var found: [String] = []
        for path in paths.map({ ($0 as NSString).expandingTildeInPath }) {
            for entity in entities where entity.isPath && Paths.isInside(path, entity.term) && !found.contains(entity.path) {
                found.append(entity.path)
            }
        }
        let lowered = text.lowercased()
        for entity in entities where !entity.isPath && !found.contains(entity.path) {
            let escaped = NSRegularExpression.escapedPattern(for: entity.term)
            if lowered.range(of: "\\b\(escaped)\\b", options: .regularExpression) != nil { found.append(entity.path) }
        }
        return found
    }

    func vector(_ text: String) -> [Float]? { embedder.vector(text) }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "into", "you", "your", "are", "was", "were", "can",
        "could", "would", "should", "will", "have", "has", "had", "not", "but", "all", "any", "our", "out", "about",
        "what", "when", "where", "which", "who", "how", "why", "make", "please", "just", "some", "there", "here", "its",
        "it", "is", "in", "on", "of", "to", "a", "an", "me", "my", "i", "be", "do", "does", "did", "so", "if", "or",
    ]

    static func terms(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 && !stopwords.contains($0) && seen.insert($0).inserted }
            .prefix(16)
            .map { $0 }
    }
}
