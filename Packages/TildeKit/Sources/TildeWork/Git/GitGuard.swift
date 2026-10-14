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
/// written back under git's own `config.lock`. Access stays relative to verified directory descriptors,
/// so a substituted parent cannot redirect a repair. Links are replaced, never written through.
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
    private var directory: Identity?
    private var hooksTarget: HookTarget?
    private var hookFileTargets: [String: HookFileTarget] = [:]
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
        guard let root = try? Directory(path: path) else {
            snapshot.snapshotRefusals = ["git directory"]
            return snapshot
        }
        snapshot.directory = root.identity
        do {
            let config = try await codeKeys(Self.config("config", in: root)?.data ?? Data())
            snapshot.configs["config"] = config
            for file in try snapshot.worktreeConfigs(config, in: root) {
                snapshot.configs[file] = try await codeKeys(Self.config(file, in: root)?.data ?? Data())
            }
        } catch { snapshot.snapshotRefusals.append("config") }
        do {
            switch try root.entry("hooks") {
            case .link(let target)?:
                snapshot.hooksLink = target
                let path = URL(fileURLWithPath: path).appending(path: "hooks").resolvingSymlinksInPath().path
                let hooks = try Directory(path: path)
                snapshot.hooksTarget = HookTarget(path: path, identity: hooks.identity)
                snapshot.hooks = try hookEntries(in: hooks)
            case .directory?:
                guard let hooks = try root.child("hooks") else { throw IOFailure() }
                snapshot.hooks = try hookEntries(in: hooks)
            case .file?: throw IOFailure()
            case nil: break
            }
            let hooksPath = snapshot.hooksTarget?.path ?? "\(path)/hooks"
            for (name, entry) in snapshot.hooks {
                guard case .link = entry else { continue }
                let target = URL(fileURLWithPath: hooksPath).appending(path: name).resolvingSymlinksInPath()
                let parent = try Directory(path: target.deletingLastPathComponent().path)
                let file = try parent.regularFile(target.lastPathComponent)
                guard URL(fileURLWithPath: hooksPath).appending(path: name).resolvingSymlinksInPath().path == target.path else { throw IOFailure() }
                snapshot.hookFileTargets[name] = HookFileTarget(
                    path: target.path, parent: parent.identity, identity: file.identity, entry: file.entry)
            }
            if let target = snapshot.hooksTarget {
                guard URL(fileURLWithPath: "\(path)/hooks").resolvingSymlinksInPath().path == target.path else { throw IOFailure() }
            }
        } catch { snapshot.snapshotRefusals.append("hooks") }
        if !root.matches(path: path) { snapshot.snapshotRefusals.append("git directory") }
        return snapshot
    }

    /// Puts back what changed since the snapshot and says what that was.
    public func restore() async -> Restoration {
        guard snapshotRefusals.isEmpty else { return Restoration(refused: snapshotRefusals) }
        guard let root = try? Directory(path: gitDirectory), root.identity == directory else {
            return Restoration(refused: ["git directory"])
        }
        var result = Restoration()
        for (file, before) in configs.sorted(by: { $0.key < $1.key }) {
            do { result.restored += try await restoreConfig(file, to: before, in: root).map { file == "config" ? $0 : "\(file):\($0)" } }
            catch { result.refused.append(file) }
        }
        do { result.restored += try restoreHooks(in: root) } catch { result.refused.append("hooks") }
        if !root.matches(path: gitDirectory) { result.refused.append("git directory") }
        return result
    }

    /// With `extensions.worktreeConfig` on in `config`, git also reads each worktree's own `config.worktree`:
    /// the main worktree's beside `config`, a linked one's (a job's) under `worktrees/<name>`.
    private func worktreeConfigs(_ config: [String: [String]], in root: Directory) throws -> [String] {
        // Over-guarding is harmless, so anything but an explicit false counts as on.
        guard let value = config["extensions.worktreeconfig"]?.last, !["false", "no", "off", "0"].contains(value.lowercased()) else {
            return []
        }
        let linked = try root.child("worktrees")?.names() ?? []
        return ["config.worktree"] + linked.map { "worktrees/\($0)/config.worktree" }
    }

    /// A missing linked worktree has no config to repair. Every existing parent must be a real directory.
    private static func config(_ file: String, in root: Directory) throws -> (data: Data, mode: mode_t)? {
        guard let parent = try root.parent(of: file) else { return nil }
        return try configEntry((file as NSString).lastPathComponent, in: parent)
    }

    private static func configEntry(_ name: String, in parent: Directory) throws -> (data: Data, mode: mode_t) {
        switch try parent.entry(name) {
        case .file(let data, let mode)?: return (data, mode)
        case nil: return (Data(), 0o644)
        default: throw IOFailure()
        }
    }

    /// Reverts `file`'s code-running keys under git's lock, so a concurrent `git config` (or another job's
    /// guard) can't lose a write. The lock and replacement stay in the same anchored directory.
    private func restoreConfig(_ file: String, to before: [String: [String]], in root: Directory) async throws -> [String] {
        guard let parent = try root.parent(of: file) else { return [] }
        let name = (file as NSString).lastPathComponent
        let unlocked = try Self.configEntry(name, in: parent)
        let keys = try await Self.codeKeys(unlocked.data)
        guard root.matches(path: gitDirectory), try root.parent(of: file)?.identity == parent.identity else { throw IOFailure() }
        guard keys != before else { return [] }
        let lock = name + ".lock"
        let locked = try await Self.lock(lock, in: parent)
        var committed = false
        defer {
            close(locked)
            if !committed { _ = unlinkat(parent.fd, lock, 0) }
        }
        let current = try Self.configEntry(name, in: parent)
        let (replacement, changed) = try await Self.reverted(current.data, to: before)
        guard root.matches(path: gitDirectory), try root.parent(of: file)?.identity == parent.identity else { throw IOFailure() }
        guard !changed.isEmpty else { return [] }
        guard fchmod(locked, current.mode) == 0 else { throw IOFailure() }
        try FileHandle(fileDescriptor: locked).write(contentsOf: replacement)
        guard parent.matchesFile(lock, descriptor: locked), renameat(parent.fd, lock, parent.fd, name) == 0 else { throw IOFailure() }
        committed = true
        guard root.matches(path: gitDirectory), try root.parent(of: file)?.identity == parent.identity,
            try await Self.codeKeys(Self.configEntry(name, in: parent).data) == before else { throw IOFailure() }
        return changed
    }

    private func restoreHooks(in root: Directory) throws -> [String] {
        let current = try root.entry("hooks")
        let directory: Directory
        var restored: [String] = []
        if let hooksLink {
            // The original link's target is trusted only while the snapshotted directory is still there.
            // Restoring its contents must never follow a replacement target or parent into another folder.
            guard let target = hooksTarget else { throw IOFailure() }
            directory = try Directory(path: target.path)
            guard directory.identity == target.identity else { throw IOFailure() }
            if current != .link(hooksLink) {
                try root.put(.link(hooksLink), at: "hooks")
                restored.append("hooks")
            }
        } else {
            switch current {
            case .directory?: break
            case nil where hooks.isEmpty: return []
            default:
                if current != nil { try root.remove("hooks") }
                guard mkdirat(root.fd, "hooks", 0o755) == 0 else { throw IOFailure() }
                restored.append("hooks")
            }
            guard let hooks = try root.child("hooks") else { throw IOFailure() }
            directory = hooks
        }
        func stillAnchored() throws -> Bool {
            guard root.matches(path: gitDirectory) else { return false }
            if let target = hooksTarget, let link = hooksLink {
                guard directory.matches(path: target.path),
                    URL(fileURLWithPath: "\(gitDirectory)/hooks").resolvingSymlinksInPath().path == target.path else { return false }
                return try root.entry("hooks") == .link(link)
            }
            return try root.child("hooks")?.identity == directory.identity
        }
        func stillResolves(_ name: String, to target: String) -> Bool {
            URL(fileURLWithPath: "\(gitDirectory)/hooks").appending(path: name).resolvingSymlinksInPath().path == target
        }
        guard try stillAnchored() else { throw IOFailure() }
        let now = try Self.hookEntries(in: directory)
        for name in Set(now.keys).union(hooks.keys).sorted() where now[name] != hooks[name] {
            guard try stillAnchored() else { throw IOFailure() }
            if let hook = hooks[name] { try directory.put(hook, at: name) }
            else { try directory.remove(name) }
            restored.append("hooks/\(name)")
        }
        for (name, target) in hookFileTargets.sorted(by: { $0.key < $1.key }) {
            guard stillResolves(name, to: target.path) else { throw IOFailure() }
            let path = URL(fileURLWithPath: target.path)
            let parentPath = path.deletingLastPathComponent().path
            let parent = try Directory(path: parentPath)
            guard parent.identity == target.parent, try stillAnchored() else { throw IOFailure() }
            let file = try parent.regularFile(path.lastPathComponent)
            guard parent.matches(path: parentPath) else { throw IOFailure() }
            guard file.entry != target.entry else { continue }
            // A replaced target needs manual review. Only the snapshotted file may be repaired.
            guard file.identity == target.identity, parent.matches(path: parentPath) else { throw IOFailure() }
            try parent.put(target.entry, at: path.lastPathComponent)
            guard parent.matches(path: parentPath), stillResolves(name, to: target.path),
                try parent.entry(path.lastPathComponent) == target.entry else { throw IOFailure() }
            restored.append("hooks/\(name):target")
        }
        guard try stillAnchored(), try Self.hookEntries(in: directory) == hooks,
            hookFileTargets.allSatisfy({ stillResolves($0.key, to: $0.value.path) }) else { throw IOFailure() }
        return restored
    }

    /// The files and links in `hooks`. Git never runs a directory as a hook.
    private static func hookEntries(in directory: Directory) throws -> [String: Entry] {
        var entries: [String: Entry] = [:]
        for name in try directory.names() {
            if let entry = try directory.entry(name), entry != .directory { entries[name] = entry }
        }
        return entries
    }

    private struct Identity: Sendable, Equatable {
        let device: dev_t
        let inode: ino_t
        init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
    }

    private struct HookTarget: Sendable, Equatable {
        let path: String
        let identity: Identity
    }

    private struct HookFileTarget: Sendable, Equatable {
        let path: String
        let parent: Identity
        let identity: Identity
        let entry: Entry
    }

    /// Each operation uses a descriptor, including parent traversal, reads, locks and renames.
    private final class Directory: Sendable {
        let fd: Int32
        let identity: Identity

        convenience init(path: String) throws {
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw IOFailure() }
            do { try self.init(fd: fd) } catch { close(fd); throw error }
        }

        private init(fd: Int32) throws {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw IOFailure() }
            self.fd = fd
            identity = Identity(info)
        }

        deinit { close(fd) }

        func matches(path: String) -> Bool { (try? Directory(path: path))?.identity == identity }

        func child(_ name: String) throws -> Directory? {
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if child < 0, errno == ENOENT { return nil }
            guard child >= 0 else { throw IOFailure() }
            do { return try Directory(fd: child) } catch { close(child); throw error }
        }

        func parent(of file: String) throws -> Directory? {
            var parent = self
            for component in file.split(separator: "/").dropLast() {
                guard component != ".", component != "..", let next = try parent.child(String(component)) else { return nil }
                parent = next
            }
            return parent
        }

        func entry(_ name: String) throws -> Entry? {
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { return nil }
                throw IOFailure()
            }
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                var buffer = [CChar](repeating: 0, count: Int(info.st_size) + 1)
                let count = readlinkat(fd, name, &buffer, buffer.count)
                guard count >= 0, count < buffer.count else { throw IOFailure() }
                return .link(String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self))
            case S_IFDIR: return .directory
            case S_IFREG:
                return try regularFile(name).entry
            default: throw IOFailure()
            }
        }

        func regularFile(_ name: String) throws -> (entry: Entry, identity: Identity) {
            let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard file >= 0 else { throw IOFailure() }
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw IOFailure() }
            let data = try handle.readToEnd() ?? Data()
            guard matchesFile(name, descriptor: file) else { throw IOFailure() }
            return (.file(data, mode: info.st_mode & 0o7777), Identity(info))
        }

        func names() throws -> [String] {
            let listing = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard listing >= 0 else { throw IOFailure() }
            guard let stream = fdopendir(listing) else { close(listing); throw IOFailure() }
            defer { closedir(stream) }
            var names: [String] = []
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw IOFailure() }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name != ".", name != ".." { names.append(name) }
            }
            return names
        }

        func put(_ entry: Entry, at name: String) throws {
            let temporary = ".tilde-\(UUID().uuidString)"
            defer { _ = unlinkat(fd, temporary, 0) }
            switch entry {
            case .file(let data, let mode):
                let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard file >= 0 else { throw IOFailure() }
                let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
                defer { try? handle.close() }
                try handle.write(contentsOf: data)
                guard fchmod(file, mode) == 0 else { throw IOFailure() }
            case .link(let target):
                guard symlinkat(target, fd, temporary) == 0 else { throw IOFailure() }
            case .directory: throw IOFailure()
            }
            guard renameat(fd, temporary, fd, name) == 0 else { throw IOFailure() }
        }

        func remove(_ name: String) throws {
            guard unlinkat(fd, name, 0) == 0 else { throw IOFailure() }
        }

        func matchesFile(_ name: String, descriptor: Int32) -> Bool {
            var named = stat(), opened = stat()
            return fstatat(fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0 && fstat(descriptor, &opened) == 0
                && named.st_mode & S_IFMT == S_IFREG && Identity(named) == Identity(opened)
        }
    }

    /// Takes git's lock in the anchored config directory, waiting briefly for another holder.
    private static func lock(_ name: String, in directory: Directory) async throws -> Int32 {
        let deadline = ContinuousClock.now + .seconds(2)
        while true {
            let file = openat(directory.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
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
