import Darwin
import Foundation
import TildeSupport

/// Restores code-running git configuration and hooks after a worker's turn. File access is relative
/// to verified directory descriptors: a replaced path must never redirect a repair outside the repo.
public struct GitGuard: Sendable, Equatable {
    struct Hook: Sendable, Equatable {
        var data: Data
        var permissions: Int
    }

    public struct Restoration: Sendable, Equatable {
        public var restored: [String] = []
        /// Paths that could not be inspected or restored safely. Callers must not continue as if repaired.
        public var refused: [String] = []

        public init(restored: [String] = [], refused: [String] = []) {
            self.restored = restored
            self.refused = refused
        }
    }

    private var directory: Identity?
    private var hookDirectory: Identity?
    private var configs: [String: [String: [String]]] = [:]
    private var hooks: [String: Hook] = [:]
    private var snapshotFailures: [String] = []

    // Enabling worktreeConfig can introduce another source of executable configuration.
    static let runsCode =
        #"^(core\.(fsmonitor|hookspath|sshcommand|pager|editor|askpass|gitproxy)|diff\.external|diff\..+\.(textconv|command)|filter\..+\.(clean|smudge|process)|merge\..+\.driver|alias\..+|include\.path|includeif\..+\.path|credential\.(.+\.)?helper|gpg\.(.+\.)?program|sequence\.editor|pager\..+|interactive\.difffilter|uploadpack\.packobjectshook|extensions\.worktreeconfig)$"#

    public static func snapshot(gitDirectory: String) async -> GitGuard {
        var snapshot = GitGuard()
        guard let root = try? Directory(path: gitDirectory) else {
            snapshot.snapshotFailures = ["git directory"]
            return snapshot
        }
        snapshot.directory = root.identity
        for name in ["config", "config.worktree"] {
            do { snapshot.configs[name] = try await codeKeys(root.read(name)?.data ?? Data()) }
            catch { snapshot.snapshotFailures.append(name) }
        }
        do {
            if let directory = try root.child("hooks") {
                snapshot.hookDirectory = directory.identity
                snapshot.hooks = try directory.files()
            }
        } catch { snapshot.snapshotFailures.append("hooks") }
        return snapshot
    }

    /// Compatibility for callers that only display repaired keys. Use restoreSafely to handle refusals.
    @discardableResult
    public func restore(gitDirectory: String) async -> [String] {
        await restoreSafely(gitDirectory: gitDirectory).restored
    }

    /// Refuses changed directory identities, symlinks and non-regular files, without following them.
    /// Ordinary file replacement is allowed because git config uses atomic replacement itself.
    public func restoreSafely(gitDirectory: String) async -> Restoration {
        guard snapshotFailures.isEmpty else { return Restoration(refused: snapshotFailures) }
        guard let root = try? Directory(path: gitDirectory), root.identity == directory else {
            return Restoration(refused: ["git directory"])
        }
        var result = Restoration()
        for name in ["config", "config.worktree"] {
            do {
                let current = try root.read(name)
                let before = configs[name] ?? [:]
                let (replacement, changed) = try await restoredConfig(current?.data ?? Data(), before: before)
                guard !changed.isEmpty else { continue }
                // The root may have been moved while git parsed the private copy.
                guard root.matches(path: gitDirectory) else { throw UnsafePath() }
                try root.replace(name, with: replacement, permissions: current?.permissions ?? 0o644)
                result.restored += changed.map { name == "config" ? $0 : "\(name):\($0)" }
            } catch { result.refused.append(name) }
        }
        do {
            guard root.matches(path: gitDirectory) else { throw UnsafePath() }
            if let current = try root.child("hooks") {
                guard hookDirectory == nil || hookDirectory == current.identity else { throw UnsafePath() }
                let now = try current.files()
                for name in Set(now.keys).union(hooks.keys).sorted() where now[name] != hooks[name] {
                    guard root.matches(path: gitDirectory), try root.child("hooks")?.identity == current.identity else {
                        throw UnsafePath()
                    }
                    if let hook = hooks[name] {
                        try current.replace(name, with: hook.data, permissions: hook.permissions)
                    } else {
                        try current.remove(name)
                    }
                    result.restored.append("hooks/\(name)")
                }
            } else if hookDirectory != nil {
                // Do not recreate a removed or moved directory at a potentially substituted location.
                throw UnsafePath()
            }
        } catch { result.refused.append("hooks") }
        return result
    }

    private struct UnsafePath: Error {}

    private struct Identity: Sendable, Equatable {
        let device: dev_t
        let inode: ino_t
        init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
    }

    /// Descriptors anchor access even if a pathname changes between validation and an operation.
    private final class Directory: Sendable {
        let fd: Int32
        let identity: Identity

        convenience init(path: String) throws {
            let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw UnsafePath() }
            do { try self.init(fd: fd) } catch { Darwin.close(fd); throw error }
        }

        private init(fd: Int32) throws {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw UnsafePath() }
            self.fd = fd
            identity = Identity(info)
        }

        deinit { Darwin.close(fd) }

        func matches(path: String) -> Bool { (try? Directory(path: path))?.identity == identity }

        func child(_ name: String) throws -> Directory? {
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if child < 0, errno == ENOENT { return nil }
            guard child >= 0 else { throw UnsafePath() }
            do { return try Directory(fd: child) } catch { Darwin.close(child); throw error }
        }

        func read(_ name: String) throws -> Hook? {
            let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if file < 0, errno == ENOENT { return nil }
            guard file >= 0 else { throw UnsafePath() }
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
            var info = stat()
            guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw UnsafePath() }
            return Hook(data: try handle.readToEnd() ?? Data(), permissions: Int(info.st_mode & 0o7777))
        }

        func files() throws -> [String: Hook] {
            // A fresh description gives each enumeration its own offset.
            let listing = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard listing >= 0 else { throw UnsafePath() }
            guard let stream = fdopendir(listing) else { Darwin.close(listing); throw UnsafePath() }
            defer { closedir(stream) }
            var files: [String: Hook] = [:]
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw UnsafePath() }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                guard name != ".", name != ".." else { continue }
                // Git ignores directories in hooks; never descend into one.
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw UnsafePath() }
                if info.st_mode & S_IFMT == S_IFDIR { continue }
                guard let file = try read(name) else { throw UnsafePath() }
                files[name] = file
            }
            return files
        }

        func replace(_ name: String, with data: Data, permissions: Int) throws {
            // Validate the destination without following a final symlink. Rename itself also never follows it.
            _ = try read(name)
            let temporary = ".tilde-guard-\(UUID().uuidString)"
            let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard file >= 0 else { throw UnsafePath() }
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
            defer { _ = unlinkat(fd, temporary, 0) }
            try handle.write(contentsOf: data)
            guard fchmod(file, mode_t(permissions)) == 0, renameat(fd, temporary, fd, name) == 0 else { throw UnsafePath() }
        }

        func remove(_ name: String) throws {
            _ = try read(name)
            guard unlinkat(fd, name, 0) == 0 else { throw UnsafePath() }
        }
    }

    // Git parses and edits a private regular copy, never an untrusted path in the worker's directory.
    private static func withConfig<T>(_ data: Data, _ body: (String) async throws -> T) async throws -> T {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tilde-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "config").path
        try data.write(to: URL(fileURLWithPath: path))
        return try await body(path)
    }

    private static func keys(in path: String) async throws -> [String: [String]] {
        let output = try await Shell.run(["git", "config", "--file", path, "--list", "--null"], timeout: .seconds(10))
        guard output.ok else { throw UnsafePath() }
        var keys: [String: [String]] = [:]
        for entry in output.stdout.split(separator: "\0") {
            let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0]).lowercased()
            guard key.range(of: runsCode, options: .regularExpression) != nil else { continue }
            keys[key, default: []].append(parts.count > 1 ? String(parts[1]) : "")
        }
        return keys
    }

    private static func codeKeys(_ data: Data) async throws -> [String: [String]] {
        try await withConfig(data) { try await keys(in: $0) }
    }

    private func restoredConfig(_ data: Data, before: [String: [String]]) async throws -> (Data, [String]) {
        try await Self.withConfig(data) { path in
            let now = try await Self.keys(in: path)
            let changed = Set(now.keys).union(before.keys).sorted().filter { now[$0] != before[$0] }
            for key in changed {
                let unset = try await Shell.run(["git", "config", "--file", path, "--unset-all", key])
                guard unset.ok || unset.status == 5 else { throw UnsafePath() }
                for value in before[key] ?? [] {
                    try await Shell.check(["git", "config", "--file", path, "--add", key, value])
                }
            }
            return (try Data(contentsOf: URL(fileURLWithPath: path)), changed)
        }
    }
}
