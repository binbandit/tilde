import Darwin
import Foundation
import TildeSupport

/// The parts of a repo's git directory that make git run code: config keys like `core.fsmonitor` (run by
/// every `git status`, in the owner's prompt too), diff and filter drivers, aliases, includes, credential
/// helpers, and the hooks. A worker in a worktree writes objects and refs there, never these; tilde notes
/// them before a worker's turn and puts back whatever the turn changed. The rest of the config (a branch's
/// upstream, a new remote) is left alone.
///
/// Config is only parsed and edited as a private copy with `git config --file`, which runs none of it, and
/// written back under git's own `config.lock`. Everything is read with `lstat` and put back by renaming a
/// fresh copy into place, so a link planted where a file was is replaced, never written through.
public struct GitGuard: Sendable, Equatable {
    enum Entry: Sendable, Equatable {
        case file(Data, mode: mode_t)
        case link(String)
        case directory
    }

    public struct Restoration: Sendable, Equatable {
        public var restored: [String] = []
        /// What couldn't be put back. The job's git setup needs the owner's review before work goes on.
        public var refused: [String] = []
    }

    /// The git directory all the repo's worktrees share.
    let gitDirectory: String
    /// Code-running keys and their values, by config file (relative to `gitDirectory`).
    var configs: [String: [String: [String]]] = [:]
    /// Where `hooks` pointed, when it's a link rather than a directory of hooks.
    var hooksLink: String?
    var hooks: [String: Entry] = [:]
    /// What couldn't be read, so can't be guarded: a worker must not start.
    public private(set) var snapshotRefusals: [String] = []

    /// Config keys whose values git runs, matched without case against keys as `git config --list` prints
    /// them (a subsection keeps its case). Turning on `extensions.worktreeConfig` makes git read more files.
    static let runsCode =
        #"^(core\.(fsmonitor|hookspath|sshcommand|pager|editor|askpass|gitproxy)|diff\.external|diff\..+\.(textconv|command)|filter\..+\.(clean|smudge|process)|merge\..+\.driver|alias\..+|include\.path|includeif\..+\.path|credential\.(.+\.)?helper|gpg\.(.+\.)?program|sequence\.editor|pager\..+|interactive\.difffilter|uploadpack\.packobjectshook|extensions\.worktreeconfig)$"#

    public static func snapshot(repository: String) async -> GitGuard {
        guard let path = try? await Git.commonDirectory(repository) else {
            return GitGuard(gitDirectory: repository, snapshotRefusals: ["git directory"])
        }
        var snapshot = GitGuard(gitDirectory: path)
        do {
            let config = try await codeKeys(snapshot.config("config")?.data ?? Data())
            snapshot.configs["config"] = config
            for file in snapshot.worktreeConfigs(config) {
                snapshot.configs[file] = try await codeKeys(snapshot.config(file)?.data ?? Data())
            }
        } catch { snapshot.snapshotRefusals.append("config") }
        do {
            switch try entry(at: "\(path)/hooks") {
            case .link(let target)?: snapshot.hooksLink = target
            case .directory?: snapshot.hooks = try snapshot.hookEntries()
            case .file?: throw IOFailure()
            case nil: break
            }
        } catch { snapshot.snapshotRefusals.append("hooks") }
        return snapshot
    }

    /// Puts back what changed since the snapshot and says what that was.
    public func restore() async -> Restoration {
        guard snapshotRefusals.isEmpty else { return Restoration(refused: snapshotRefusals) }
        var result = Restoration()
        for (file, before) in configs.sorted(by: { $0.key < $1.key }) {
            do { result.restored += try await restoreConfig(file, to: before).map { file == "config" ? $0 : "\(file):\($0)" } }
            catch { result.refused.append(file) }
        }
        do { result.restored += try restoreHooks() } catch { result.refused.append("hooks") }
        return result
    }

    /// With `extensions.worktreeConfig` on in `config`, git also reads each worktree's own `config.worktree`:
    /// the main worktree's beside `config`, a linked one's (a job's) under `worktrees/<name>`.
    private func worktreeConfigs(_ config: [String: [String]]) -> [String] {
        // Over-guarding is harmless, so anything but an explicit false counts as on.
        guard let value = config["extensions.worktreeconfig"]?.last, !["false", "no", "off", "0"].contains(value.lowercased()) else {
            return []
        }
        let linked = (try? FileManager.default.contentsOfDirectory(atPath: "\(gitDirectory)/worktrees")) ?? []
        return ["config.worktree"] + linked.map { "worktrees/\($0)/config.worktree" }
    }

    /// A config file's contents and mode: empty when there's none, nil when its folder is gone too (a linked
    /// worktree removed). Git would follow a link here, and only the code-running keys are known, so anything
    /// but a regular file can't be guarded or rebuilt.
    private func config(_ file: String) throws -> (data: Data, mode: mode_t)? {
        let path = "\(gitDirectory)/\(file)"
        switch try Self.entry(at: path) {
        case .file(let data, let mode)?: return (data, mode)
        case nil: return FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent) ? (Data(), 0o644) : nil
        default: throw IOFailure()
        }
    }

    /// Reverts `file`'s code-running keys under git's lock, so a concurrent `git config` (or another job's
    /// guard) can't lose a write. Returns the keys that had changed.
    private func restoreConfig(_ file: String, to before: [String: [String]]) async throws -> [String] {
        guard let unlocked = try config(file), try await Self.codeKeys(unlocked.data) != before else { return [] }
        let path = "\(gitDirectory)/\(file)", lock = path + ".lock"
        let locked = try await Self.lock(lock)
        var committed = false
        defer {
            close(locked)
            if !committed { unlink(lock) }
        }
        guard let current = try config(file) else { return [] }
        let (replacement, changed) = try await Self.reverted(current.data, to: before)
        guard !changed.isEmpty else { return [] }
        guard fchmod(locked, current.mode) == 0 else { throw IOFailure() }
        try FileHandle(fileDescriptor: locked).write(contentsOf: replacement)
        guard rename(lock, path) == 0 else { throw IOFailure() }
        committed = true
        return changed
    }

    private func restoreHooks() throws -> [String] {
        let path = "\(gitDirectory)/hooks"
        let current = try Self.entry(at: path)
        if let hooksLink {
            guard current != .link(hooksLink) else { return [] }
            try Self.put(.link(hooksLink), at: path)
            return ["hooks"]
        }
        var restored: [String] = []
        switch current {
        case .directory?: break
        case nil where hooks.isEmpty: return []
        default:
            // A link or file in its place goes (unlinking never follows a link) and a fresh directory takes it.
            if current != nil, unlink(path) != 0 { throw IOFailure() }
            guard mkdir(path, 0o755) == 0 else { throw IOFailure() }
            restored.append("hooks")
        }
        let now = try hookEntries()
        for name in Set(now.keys).union(hooks.keys).sorted() where now[name] != hooks[name] {
            if let hook = hooks[name] {
                try Self.put(hook, at: "\(path)/\(name)")
            } else if unlink("\(path)/\(name)") != 0 {
                throw IOFailure()
            }
            restored.append("hooks/\(name)")
        }
        return restored
    }

    /// The files and links in `hooks`. Git never runs a directory as a hook.
    private func hookEntries() throws -> [String: Entry] {
        let path = "\(gitDirectory)/hooks"
        var entries: [String: Entry] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: path) {
            if let entry = try Self.entry(at: "\(path)/\(name)"), entry != .directory { entries[name] = entry }
        }
        return entries
    }

    /// What's at `path`, without following a link there; nil when nothing is.
    private static func entry(at path: String) throws -> Entry? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw IOFailure()
        }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return .link(try FileManager.default.destinationOfSymbolicLink(atPath: path))
        case S_IFDIR: return .directory
        case S_IFREG:
            guard let data = FileManager.default.contents(atPath: path) else { throw IOFailure() }
            return .file(data, mode: info.st_mode & 0o7777)
        default: throw IOFailure()
        }
    }

    /// Renames a fresh copy of `entry` over `path`, which replaces a link there rather than following it.
    private static func put(_ entry: Entry, at path: String) throws {
        let temporary = "\((path as NSString).deletingLastPathComponent)/.tilde-\(UUID().uuidString)"
        do {
            switch entry {
            case .file(let data, let mode):
                try data.write(to: URL(fileURLWithPath: temporary), options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary)
            case .link(let target):
                try FileManager.default.createSymbolicLink(atPath: temporary, withDestinationPath: target)
            case .directory:
                throw IOFailure()
            }
            guard rename(temporary, path) == 0 else { throw IOFailure() }
        } catch {
            unlink(temporary)
            throw error
        }
    }

    /// Creates `path` as git takes a lock, only if nothing is there, and returns its descriptor. Waits a
    /// while for another holder.
    private static func lock(_ path: String) async throws -> Int32 {
        let deadline = ContinuousClock.now + .seconds(2)
        while true {
            let file = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if file >= 0 { return file }
            guard errno == EEXIST, ContinuousClock.now < deadline else { throw IOFailure() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// `config` with its code-running keys put back to `before`, and which keys that changed.
    private static func reverted(_ config: Data, to before: [String: [String]]) async throws -> (Data, [String]) {
        try await withCopy(of: config) { path in
            let now = try await keys(in: path)
            let changed = Set(now.keys).union(before.keys).sorted().filter { now[$0] != before[$0] }
            for key in changed {
                let unset = try await Shell.run(["git", "config", "--file", path, "--unset-all", key])
                // 5: it isn't set, because the turn removed it.
                guard unset.ok || unset.status == 5 else { throw IOFailure() }
                for value in before[key] ?? [] {
                    try await Shell.check(["git", "config", "--file", path, "--add", key, value])
                }
            }
            return (try Data(contentsOf: URL(fileURLWithPath: path)), changed)
        }
    }

    private static func codeKeys(_ config: Data) async throws -> [String: [String]] {
        try await withCopy(of: config) { try await keys(in: $0) }
    }

    private static func keys(in path: String) async throws -> [String: [String]] {
        let output = try await Shell.run(["git", "config", "--file", path, "--list", "--null"], timeout: .seconds(10))
        guard output.ok else { throw IOFailure() }
        var keys: [String: [String]] = [:]
        for entry in output.stdout.split(separator: "\0") {
            let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            guard key.range(of: runsCode, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            keys[key, default: []].append(parts.count > 1 ? String(parts[1]) : "")
        }
        return keys
    }

    private static func withCopy<T>(of config: Data, _ body: (String) async throws -> T) async throws -> T {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tilde-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "config").path
        try config.write(to: URL(fileURLWithPath: path))
        return try await body(path)
    }

    private struct IOFailure: Error {}
}
