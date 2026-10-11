import Foundation
import TildeSupport

/// The parts of a repo's git directory that make git run code: config keys like `core.fsmonitor` (run by
/// every `git status`, in the owner's prompt too), diff and filter drivers, aliases, includes, credential
/// helpers, and the hooks. A worker in a worktree writes objects and refs there, never these; tilde notes
/// them before a worker's turn and puts back what the turn changed. Everything else in the config (a
/// branch's upstream, a new remote) is left alone, and the config is only ever read and edited with
/// `git config --file`, which runs none of it.
public struct GitGuard: Sendable, Equatable {
    struct Hook: Sendable, Equatable {
        var data: Data
        var permissions: Int
    }

    /// Code-running keys and their values.
    var config: [String: [String]]
    /// Hooks by file name.
    var hooks: [String: Hook]

    /// Config keys (lowercased, as `git config --list` prints them) whose values git runs.
    static let runsCode =
        #"^(core\.(fsmonitor|hookspath|sshcommand|pager|editor|askpass|gitproxy)|diff\.external|diff\..+\.(textconv|command)|filter\..+\.(clean|smudge|process)|merge\..+\.driver|alias\..+|include\.path|includeif\..+\.path|credential\.(.+\.)?helper|gpg\.(.+\.)?program|sequence\.editor|pager\..+|interactive\.difffilter|uploadpack\.packobjectshook)$"#

    public static func snapshot(gitDirectory: String) async -> GitGuard {
        GitGuard(config: await codeKeys(gitDirectory), hooks: hooks(gitDirectory))
    }

    /// Puts back what changed since the snapshot: code-running config keys to their old values, and hooks
    /// as they were (new ones removed). Returns what had changed.
    @discardableResult
    public func restore(gitDirectory: String) async -> [String] {
        var changed: [String] = []
        let config = "\(gitDirectory)/config"
        let now = await Self.codeKeys(gitDirectory)
        for key in Set(now.keys).union(self.config.keys).sorted() where now[key] != self.config[key] {
            changed.append(key)
            _ = try? await Shell.run(["git", "config", "--file", config, "--unset-all", key])
            for value in self.config[key] ?? [] { _ = try? await Shell.run(["git", "config", "--file", config, "--add", key, value]) }
        }
        let current = Self.hooks(gitDirectory)
        for name in Set(current.keys).union(hooks.keys).sorted() where current[name] != hooks[name] {
            changed.append("hooks/\(name)")
            let url = URL(fileURLWithPath: gitDirectory).appending(path: "hooks/\(name)")
            if let hook = hooks[name] {
                try? hook.data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: hook.permissions], ofItemAtPath: url.path)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return changed
    }

    private static func codeKeys(_ gitDirectory: String) async -> [String: [String]] {
        let path = "\(gitDirectory)/config"
        guard FileManager.default.fileExists(atPath: path),
            let output = try? await Shell.run(["git", "config", "--file", path, "--list", "--null"], timeout: .seconds(10)), output.ok
        else { return [:] }
        var keys: [String: [String]] = [:]
        for entry in output.stdout.split(separator: "\0") {
            let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0]).lowercased()
            guard key.range(of: runsCode, options: .regularExpression) != nil else { continue }
            keys[key, default: []].append(parts.count > 1 ? String(parts[1]) : "")
        }
        return keys
    }

    private static func hooks(_ gitDirectory: String) -> [String: Hook] {
        let dir = "\(gitDirectory)/hooks"
        var hooks: [String: Hook] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
            let path = "\(dir)/\(name)"
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            let permissions = ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int) ?? 0o644
            hooks[name] = Hook(data: data, permissions: permissions)
        }
        return hooks
    }
}
