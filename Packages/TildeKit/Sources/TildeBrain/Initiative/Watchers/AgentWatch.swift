import Foundation
import TildeSupport

/// Claude Code and Codex sessions run outside tilde that finished a turn and
/// have been waiting a while: with many agents going, these are easy to lose.
enum AgentWatch {
    struct Waiting: Sendable {
        var harness: String
        var session: String
        var cwd: String
        var finishedAt: Date
        var lastWords: String
    }

    static func waiting(since: Date, quiet: TimeInterval = 5 * 60) -> [Waiting] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let now = Date.now
        var found: [Waiting] = []
        let claude = recent(home.appending(path: ".claude/projects"), since: since)
        for (url, modified) in claude where now.timeIntervalSince(modified) > quiet {
            guard let tail = lastLines(url), let last = tail.last(where: { ["assistant", "user"].contains($0["type"]?.string) }),
                last["type"]?.string == "assistant", last["message"]?["stop_reason"]?.string == "end_turn",
                let cwd = last["cwd"]?.string, !cwd.contains("/.tilde/"), !cwd.contains("/T/"), !cwd.contains("/tmp/")
            else { continue }
            let text = (last["message"]?["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: " ")
            found.append(Waiting(
                harness: "Claude Code", session: url.deletingPathExtension().lastPathComponent, cwd: cwd, finishedAt: modified,
                lastWords: text.clipped(to: 140)))
        }
        let codex = recent(home.appending(path: ".codex/sessions"), since: since)
        for (url, modified) in codex where now.timeIntervalSince(modified) > quiet {
            guard let tail = lastLines(url), let done = tail.last, done["payload"]?["type"]?.string == "task_complete" else { continue }
            let head = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").first.flatMap { JSON.parse(String($0)) }
            guard let cwd = head?["payload"]?["cwd"]?.string, !cwd.contains("/.tilde/"), !cwd.contains("/tmp/"), !cwd.contains("/T/") else { continue }
            found.append(Waiting(
                harness: "Codex", session: url.deletingPathExtension().lastPathComponent, cwd: cwd, finishedAt: modified,
                lastWords: (done["payload"]?["last_agent_message"]?.string ?? "").clipped(to: 140)))
        }
        return found
    }

    private static func recent(_ root: URL, since: Date) -> [(URL, Date)] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var files: [(URL, Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified > since { files.append((url, modified)) }
        }
        return files
    }

    /// The last few JSON lines of a transcript, read from the end.
    private static func lastLines(_ url: URL, bytes: Int = 64_000) -> [JSON]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").suffix(20).compactMap { JSON.parse(String($0)) }
    }
}

extension AgentWatch.Waiting {
    var notice: Notice {
        Notice(
            key: "agent:\(session):\(Int(finishedAt.timeIntervalSince1970))", subject: "agent:\(session)",
            urgency: .fyi,
            summary: "\(harness) in \((cwd as NSString).abbreviatingWithTildeInPath) finished and is waiting for you: \(lastWords)",
            project: cwd, suggestion: nil)
    }
}
