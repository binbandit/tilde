import Foundation
import TildeSupport

/// tilde's long-term memory: a git repo of plain markdown the manager reads and
/// edits with its ordinary file tools. Every change is a commit, so how tilde
/// learned is `git log`, and a bad memory is `git revert`.
public struct Notebook: Sendable {
    /// A write the notebook turned down (a secret, mostly).
    public struct Refused: Error, CustomStringConvertible {
        public var description: String
    }

    public let url: URL
    public var path: String { url.path }

    public init(url: URL) { self.url = url }

    /// Creates the notebook on first run, seeded with the files the manager expects.
    public func prepare() async throws {
        let fm = FileManager.default
        for dir in ["projects", "journal", "tasks"] {
            try fm.createDirectory(at: url.appending(path: dir), withIntermediateDirectories: true)
        }
        for (name, contents) in Self.seeds where !fm.fileExists(atPath: url.appending(path: name).path) {
            try contents.write(to: url.appending(path: name), atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: url.appending(path: ".git").path) {
            try await Shell.check(["git", "init", "-q", "-b", "main"], cwd: path)
            try await Shell.check(["git", "add", "-A"], cwd: path)
            try await Shell.check(Self.commit("Start the notebook"), cwd: path)
        }
    }

    /// Commits whatever changed, describing it by the files touched.
    @discardableResult
    public func commitChanges(context: String? = nil) async -> Bool {
        // Untrimmed: porcelain lines start with a two-letter status that may begin with a space.
        guard let status = try? await Shell.run(["git", "status", "--porcelain"], cwd: path).stdout,
            !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        let files = status.split(separator: "\n").map { String($0.dropFirst(3)) }
        let summary = files.count <= 3 ? files.joined(separator: ", ") : "\(files.count) notes"
        let message = context.map { "\(summary): \($0)" } ?? summary
        _ = try? await Shell.run(["git", "add", "-A"], cwd: path)
        return (try? await Shell.run(Self.commit(message.clipped(to: 120)), cwd: path))?.ok ?? false
    }

    /// Appends a standing rule (from an "Always" answer) in the owner's own words.
    public func addRule(_ rule: String) async throws {
        let rules = url.appending(path: "rules.md")
        var text = (try? String(contentsOf: rules, encoding: .utf8)) ?? Self.seeds["rules.md"]!
        if !text.hasSuffix("\n") { text += "\n" }
        text += "- \(rule)\n"
        try text.write(to: rules, atomically: true, encoding: .utf8)
        await commitChanges(context: "new rule")
    }

    public func read(_ name: String) -> String? {
        try? String(contentsOf: url.appending(path: name), encoding: .utf8)
    }

    public static func journalName(for date: Date = .now) -> String {
        "journal/\(date.formatted(.iso8601.year().month().day())).md"
    }

    private static func commit(_ message: String) -> [String] {
        // The notebook is tilde's own repo; never borrow the user's signing or hooks for it.
        ["git", "-c", "user.name=tilde", "-c", "user.email=tilde@localhost", "-c", "commit.gpgsign=false",
         "commit", "-q", "--no-verify", "-m", message]
    }

    static let seeds: [String: String] = [
        "me.md": """
            # Me

            Who I am, how I like to work, and standing instructions. tilde keeps this current.

            """,
        "rules.md": """
            # Rules

            When agents may act without asking. Written in plain English; tilde applies them.
            Pushes, pull requests, deploys, and anything outside a job's worktree always come to me unless a rule here allows it.

            """,
        "README.md": """
            # tilde's notebook

            - `me.md`: who I am and how I like things done
            - `rules.md`: what agents may do without asking
            - `projects/`: one note per project (paths, aliases, stack, how to build and test)
            - `journal/`: one note per day
            - `tasks/`: one note per delegated job

            tilde commits every change. `git log` shows what it learned and when.

            """,
    ]
}
