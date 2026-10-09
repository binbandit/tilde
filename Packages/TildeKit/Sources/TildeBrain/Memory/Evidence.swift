import Foundation
import TildeMemory
import TildeSupport
import TildeWork

/// The raw material for the memory passes, read from what's already on this Mac.
enum Evidence {
    /// Everything that happened on `day`, for the dream.
    static func gather(day: Date, home: TildeHome, notebook: Notebook, projects: ProjectIndex) async -> String {
        let start = Calendar.current.startOfDay(for: day)
        let end = start.addingTimeInterval(86_400)
        var sections: [(String, String)] = []

        let activity = Self.activity(home: home, from: start, to: end)
        if !activity.isEmpty { sections.append(("Where the time went (focused app and window)", activity)) }

        let commits = await Self.commits(projects: projects, from: start, to: end)
        if !commits.isEmpty { sections.append(("Commits", commits)) }

        let sessions = Self.claudeSessions(from: start, to: end) + Self.codexSessions(from: start, to: end)
        if !sessions.isEmpty { sections.append(("Coding-agent sessions", sessions.joined(separator: "\n"))) }

        let conversation = ThreadStore(home: home).transcript(day)
        if !conversation.isEmpty { sections.append(("Conversation with tilde", conversation)) }

        if let journal = notebook.read(Notebook.journalName(for: day)) { sections.append(("tilde's log for the day", journal)) }

        let tasks = Self.tasks(notebook: notebook, from: start, to: end)
        if !tasks.isEmpty { sections.append(("Jobs tilde ran", tasks)) }

        return sections.map { "<\($0.0)>\n\($0.1)\n</\($0.0)>" }.joined(separator: "\n\n")
    }

    // MARK: Activity

    private struct Span: Decodable {
        var app: String
        var title: String?
        var path: String?
        var start: Date
        var end: Date
    }

    /// Minutes per app and project/window, longest first.
    static func activity(home: TildeHome, from start: Date, to end: Date) -> String {
        guard let text = try? String(contentsOf: home.state.appending(path: "activity.jsonl"), encoding: .utf8) else { return "" }
        let decoder = JSONDecoder()
        var minutes: [String: Double] = [:]
        for line in text.split(separator: "\n") {
            guard let span = try? decoder.decode(Span.self, from: Data(line.utf8)), span.end > start, span.start < end else { continue }
            let place = span.path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? span.title.map { $0.clipped(to: 60) } ?? ""
            minutes["\(span.app) · \(place)", default: 0] += min(span.end, end).timeIntervalSince(max(span.start, start)) / 60
        }
        return minutes.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.prefix(30)
            .map { "- \($0.key): \(Int($0.value))m" }.joined(separator: "\n")
    }

    // MARK: Git

    static func commits(projects: ProjectIndex, from start: Date, to end: Date) async -> String {
        let email = (try? await Shell.check(["git", "config", "--global", "user.email"])) ?? ""
        let active = await projects.recent(limit: 40).filter { $0.lastActive >= start }
        var lines: [String] = []
        for repo in active {
            let log = (try? await Shell.check([
                "git", "log", "--all", "--no-merges", "--since=\(Int(start.timeIntervalSince1970))",
                "--until=\(Int(end.timeIntervalSince1970))", "--format=%h %s",
            ] + (email.isEmpty ? [] : ["--author=\(email)"]), cwd: repo.path)) ?? ""
            let commits = log.split(separator: "\n").prefix(15)
            if !commits.isEmpty {
                lines.append("\(repo.name) (\((repo.path as NSString).abbreviatingWithTildeInPath)):")
                lines += commits.map { "  - \($0)" }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Agent sessions

    /// Claude Code transcripts: one line per session with its directory and first request.
    static func claudeSessions(from start: Date, to end: Date) -> [String] {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/projects")
        return recentFiles(under: root, from: start, to: end).compactMap { file in
            var cwd: String?, first: String?, turns = 0
            for line in head(of: file, lines: 400) {
                guard let json = JSON.parse(String(line)), json["type"]?.string == "user" else { continue }
                cwd = cwd ?? json["cwd"]?.string
                let content = json["message"]?["content"]
                let text = content?.string ?? content?.array?.first { $0["type"]?.string == "text" }?["text"]?.string
                guard let text, !text.hasPrefix("<"), !text.isEmpty else { continue }
                turns += 1
                first = first ?? text
            }
            guard let cwd, let first, !cwd.contains("/.tilde/") else { return nil }
            return "- Claude Code in \((cwd as NSString).abbreviatingWithTildeInPath) (\(turns) requests): \(first.clipped(to: 160))"
        }
    }

    /// Codex rollouts, same shape.
    static func codexSessions(from start: Date, to end: Date) -> [String] {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".codex/sessions")
        return recentFiles(under: root, from: start, to: end).compactMap { file in
            var cwd: String?, first: String?, turns = 0
            for line in head(of: file, lines: 400) {
                guard let json = JSON.parse(String(line)) else { continue }
                let payload = json["payload"]
                if json["type"]?.string == "session_meta" { cwd = payload?["cwd"]?.string }
                if json["type"]?.string == "event_msg", payload?["type"]?.string == "user_message",
                    let text = payload?["message"]?.string, !text.isEmpty
                {
                    turns += 1
                    first = first ?? text
                }
            }
            guard let cwd, let first, !cwd.contains("/.tilde/") else { return nil }
            return "- Codex in \((cwd as NSString).abbreviatingWithTildeInPath) (\(turns) requests): \(first.clipped(to: 160))"
        }
    }

    private static func recentFiles(under root: URL, from start: Date, to end: Date) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified >= start, modified < end.addingTimeInterval(6 * 3600) { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }.suffix(60)
    }

    private static func head(of url: URL, lines: Int) -> [Substring] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 2_000_000)) ?? Data()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(lines).map { $0 }
    }

    // MARK: tilde's own jobs

    static func tasks(notebook: Notebook, from start: Date, to end: Date) -> String {
        let dir = notebook.url.appending(path: "tasks")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter {
            let modified = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return modified >= start && modified < end.addingTimeInterval(6 * 3600)
        }
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        .map { $0.clipped(to: 1_500, keepLines: true) }
        .joined(separator: "\n\n")
    }

    // MARK: First meeting

    /// Instruction files people already keep for their agents; read only with consent.
    static var instructionFiles: [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return ["AGENTS.md", ".claude/CLAUDE.md", ".codex/AGENTS.md", ".config/AGENTS.md"]
            .map { home.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The owner's agent instructions and most active projects, for the first meeting.
    static func introduction(instructions files: [URL], projects: ProjectIndex, limit: Int = 12) async -> String {
        var evidence: [String] = files.compactMap { url in
            guard var text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            // Follow `@path` includes one level, the way Claude Code does.
            for line in text.split(separator: "\n") where line.hasPrefix("@") {
                let path = (String(line.dropFirst()) as NSString).expandingTildeInPath
                if let included = try? String(contentsOfFile: path, encoding: .utf8) { text += "\n\n<!-- \(path) -->\n" + included }
            }
            return "<instructions file=\"\((url.path as NSString).abbreviatingWithTildeInPath)\">\n\(text.clipped(to: 20_000, keepLines: true))\n</instructions>"
        }
        let recent = await projects.recent(limit: limit)
        if !recent.isEmpty {
            evidence.append("<active-projects>\n" + recent.map {
                "- \($0.name): \($0.path) [\($0.stack.joined(separator: ", "))] active \($0.lastActive.formatted(.relative(presentation: .named)))"
            }.joined(separator: "\n") + "\n</active-projects>")
        }
        return evidence.joined(separator: "\n\n")
    }
}
