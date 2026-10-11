import Foundation

/// Every git repo under the project roots, so "the paradise app" can become a path.
public actor ProjectIndex {
    public struct Project: Sendable, Hashable {
        public var name: String
        public var path: String
        public var stack: [String]
        /// Last time anything moved in the repo (HEAD, index), a cheap recency signal.
        public var lastActive: Date
        /// Where `origin` points, as owner/repo: what tells apart checkouts with the same folder name.
        public var remote: String?
    }

    private let roots: [String]
    private var projects: [Project] = []
    private var scannedAt: Date?

    private static let skip: Set<String> = [
        "node_modules", ".build", "build", "DerivedData", "Pods", "vendor", "target", "dist", ".git", ".tilde",
        "Library", "Carthage", ".venv", "venv", "__pycache__", ".next",
    ]

    public init(roots: [String]) {
        self.roots = roots.map { ($0 as NSString).expandingTildeInPath }
    }

    public static var defaultRoots: [String] {
        let home = NSHomeDirectory()
        return ["Developer", "Projects", "Code", "src", "dev"]
            .map { "\(home)/\($0)" }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Projects matching every word of `query`, best match and most recent first.
    public func search(_ query: String, limit: Int = 8) -> [Project] {
        refreshIfStale()
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty else { return Array(projects.sorted { $0.lastActive > $1.lastActive }.prefix(limit)) }
        return projects
            .compactMap { project -> (Project, Int)? in
                let name = project.name.lowercased(), path = project.path.lowercased()
                var score = 0
                for word in words {
                    if name == word { score += 10 }
                    else if name.contains(word) { score += 5 }
                    else if project.remote?.lowercased().contains(word) == true { score += 4 }
                    else if path.contains(word) || project.stack.joined(separator: " ").lowercased().contains(word) { score += 1 }
                    else { return nil }
                }
                return (project, score)
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastActive > $1.0.lastActive }
            .prefix(limit)
            .map(\.0)
    }

    public func recent(limit: Int = 8) -> [Project] { search("", limit: limit) }

    /// The checkout of `repo` (owner/repo), the most recently active if there are several.
    public func checkout(of repo: String) -> Project? {
        refreshIfStale()
        return projects.filter { $0.remote?.caseInsensitiveCompare(repo) == .orderedSame }.max { $0.lastActive < $1.lastActive }
    }

    private func refreshIfStale() {
        if let scannedAt, Date.now.timeIntervalSince(scannedAt) < 600 { return }
        projects = roots.flatMap { scan($0, depth: 0) }
        scannedAt = .now
    }

    private func scan(_ dir: String, depth: Int) -> [Project] {
        let fm = FileManager.default
        if fm.fileExists(atPath: "\(dir)/.git") { return [project(at: dir)] }
        guard depth < 4, let children = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return children
            .filter { !$0.hasPrefix(".") && !Self.skip.contains($0) }
            .flatMap { child -> [Project] in
                let path = "\(dir)/\(child)"
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                    (try? fm.destinationOfSymbolicLink(atPath: path)) == nil
                else { return [] }
                return scan(path, depth: depth + 1)
            }
    }

    private func project(at path: String) -> Project {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        var stack: [String] = []
        if files.contains("Package.swift") || files.contains(where: { $0.hasSuffix(".xcodeproj") }) { stack.append("Swift") }
        if files.contains("package.json") { stack.append(files.contains("next.config.js") || files.contains("next.config.ts") ? "Next.js" : "JS/TS") }
        if files.contains("go.mod") { stack.append("Go") }
        if files.contains("Cargo.toml") { stack.append("Rust") }
        if files.contains("pyproject.toml") || files.contains("requirements.txt") { stack.append("Python") }
        let stamps = ["\(path)/.git/index", "\(path)/.git/HEAD", "\(path)/.git/logs/HEAD"].compactMap {
            (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }
        return Project(
            name: (path as NSString).lastPathComponent, path: path, stack: stack,
            lastActive: stamps.max() ?? .distantPast, remote: Self.origin(of: path))
    }

    /// owner/repo from the checkout's `origin` URL (https or ssh), read from its git config.
    static func origin(of path: String) -> String? {
        guard let config = try? String(contentsOfFile: "\(path)/.git/config", encoding: .utf8) else { return nil }
        var inOrigin = false
        for line in config.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("[") { inOrigin = line == "[remote \"origin\"]" }
            guard inOrigin, line.hasPrefix("url"), let url = line.split(separator: "=", maxSplits: 1).last else { continue }
            return remote(fromURL: url.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// `git@github.com:owner/repo.git` or `https://github.com/owner/repo` as `owner/repo`.
    static func remote(fromURL url: String) -> String? {
        let tail = url.split(whereSeparator: { $0 == ":" || $0 == "/" }).suffix(2).map(String.init)
        guard tail.count == 2 else { return nil }
        let repo = tail[1].hasSuffix(".git") ? String(tail[1].dropLast(4)) : tail[1]
        return "\(tail[0])/\(repo)"
    }
}
