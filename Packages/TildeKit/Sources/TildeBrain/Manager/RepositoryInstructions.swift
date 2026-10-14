import Foundation
import TildeSupport

/// A repo's root AGENTS.md: what its owner wants coding agents to know about it. The manager reads it
/// before acting in a repo, and a new worker gets it with its brief (Claude Code doesn't read it itself).
enum RepositoryInstructions {
    /// The file's text, or nil when there's none. One that can't be read is as good as none (it's
    /// logged): it's guidance, never a reason for work to stop.
    static func read(repository: String) -> String? {
        let file = URL(fileURLWithPath: repository).appending(path: "AGENTS.md")
        do {
            return try String(contentsOf: file, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            Log.info("instructions", "couldn't read \(file.path): \(error)")
            return nil
        }
    }

    /// The file as it's handed to a model: its markdown as written, in a tag it can't close early.
    static func tagged(repository: String) -> String? {
        read(repository: repository).map { tagged(repository: repository, text: $0) }
    }

    static func tagged(repository: String, text: String) -> String {
        let path = (repository as NSString).appendingPathComponent("AGENTS.md")
        return "<agents-md path=\"\(path)\">\n\(text.replacingOccurrences(of: "</agents-md", with: "‹/agents-md"))\n</agents-md>"
    }

    /// The repo `path` is in (or is): the nearest folder with a `.git`, by its real path, so a repo
    /// reached through a link is still the same repo.
    static func repository(containing path: String) -> String? {
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath()
        while true {
            if FileManager.default.fileExists(atPath: url.appending(path: ".git").path) { return url.path }
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else { return nil }
            url = parent
        }
    }
}
