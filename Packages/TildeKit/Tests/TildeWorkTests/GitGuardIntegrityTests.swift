import Foundation
import Testing
@testable import TildeWork

@Suite struct GitGuardIntegrityTests {
    struct Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "tilde-guard-integrity-\(UUID().uuidString)")
        var git: URL { root.appending(path: "git") }
        var outside: URL { root.appending(path: "outside") }
        var config: URL { git.appending(path: "config") }
        var hooks: URL { git.appending(path: "hooks") }

        init() throws {
            for directory in [git, outside, hooks] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try "[core]\n\tfsmonitor = original-value\n".write(to: config, atomically: true, encoding: .utf8)
        }

        func write(_ text: String, to path: URL) throws {
            try text.write(to: path, atomically: true, encoding: .utf8)
        }
        func text(_ path: URL) throws -> String { try String(contentsOf: path, encoding: .utf8) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func preservesOutsideFilesWhenHooksDirectoryIsReplaced() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let sentinel = f.outside.appending(path: "sentinel.txt")
        try f.write("outside content", to: sentinel)
        let guardState = await GitGuard.snapshot(gitDirectory: f.git.path)
        try FileManager.default.removeItem(at: f.hooks)
        try FileManager.default.createSymbolicLink(at: f.hooks, withDestinationURL: f.outside)

        let result = await guardState.restoreSafely(gitDirectory: f.git.path)
        #expect(result.refused == ["hooks"])
        #expect(result.restored.isEmpty)
        #expect(try f.text(sentinel) == "outside content")
    }

    @Test func refusesConfigAndHookFileLinks() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let sentinel = f.outside.appending(path: "sentinel.txt")
        let hook = f.hooks.appending(path: "inert-file")
        try f.write("outside content", to: sentinel)
        try f.write("original contents", to: hook)
        let guardState = await GitGuard.snapshot(gitDirectory: f.git.path)
        for path in [f.config, hook] {
            try FileManager.default.removeItem(at: path)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: sentinel)
        }

        let result = await guardState.restoreSafely(gitDirectory: f.git.path)
        #expect(result.refused == ["config", "hooks"])
        #expect(result.restored.isEmpty)
        #expect(try f.text(sentinel) == "outside content")
    }

    @Test func refusesReplacementDirectoriesEvenAtTheSamePath() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let guardState = await GitGuard.snapshot(gitDirectory: f.git.path)
        try FileManager.default.moveItem(at: f.hooks, to: f.git.appending(path: "original-hooks"))
        try FileManager.default.createDirectory(at: f.hooks, withIntermediateDirectories: false)
        let sentinel = f.hooks.appending(path: "sentinel.txt")
        try f.write("replacement content", to: sentinel)
        #expect(await guardState.restoreSafely(gitDirectory: f.git.path).refused == ["hooks"])
        #expect(try f.text(sentinel) == "replacement content")

        try FileManager.default.moveItem(at: f.git, to: f.root.appending(path: "original-git"))
        try FileManager.default.createDirectory(at: f.git, withIntermediateDirectories: false)
        try f.write("replacement config", to: f.config)
        #expect(await guardState.restoreSafely(gitDirectory: f.git.path).refused == ["git directory"])
        #expect(try f.text(f.config) == "replacement config")
    }

    @Test func restoresOrdinaryFilesPermissionsAndWorktreeConfiguration() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let original = f.hooks.appending(path: "inert-file")
        let added = f.hooks.appending(path: "new-inert-file")
        try f.write("original contents", to: original)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: original.path)
        let guardState = await GitGuard.snapshot(gitDirectory: f.git.path)
        try f.write("changed contents", to: original)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: original.path)
        try f.write("new contents", to: added)
        try f.write("[core]\n\tfsmonitor = changed-value\n[branch \"main\"]\n\tremote = origin\n[extensions]\n\tworktreeConfig = true\n", to: f.config)
        let worktreeConfig = f.git.appending(path: "config.worktree")
        try f.write("[core]\n\tfsmonitor = worktree-value\n[branch \"feature\"]\n\tremote = origin\n", to: worktreeConfig)

        let result = await guardState.restoreSafely(gitDirectory: f.git.path)
        #expect(result.refused.isEmpty)
        #expect(result.restored == ["core.fsmonitor", "extensions.worktreeconfig", "config.worktree:core.fsmonitor", "hooks/inert-file", "hooks/new-inert-file"])
        #expect(try f.text(f.config).contains("original-value"))
        #expect(try f.text(f.config).contains("remote = origin"))
        #expect(try !f.text(worktreeConfig).contains("fsmonitor"))
        #expect(try f.text(worktreeConfig).contains("remote = origin"))
        #expect(try f.text(original) == "original contents")
        #expect(!FileManager.default.fileExists(atPath: added.path))
        #expect(try FileManager.default.attributesOfItem(atPath: original.path)[.posixPermissions] as? Int == 0o640)
        #expect(await guardState.restoreSafely(gitDirectory: f.git.path) == GitGuard.Restoration())
    }

    @Test func enabledWorktreeConfigurationIsRefusedBeforeRestoration() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write("[extensions]\n\tworktreeConfig = true\n", to: f.config)
        let linked = f.git.appending(path: "worktrees/job")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        let linkedConfig = linked.appending(path: "config.worktree")
        try f.write("[core]\n\tfsmonitor = original-inert-value\n", to: linkedConfig)
        let guardState = await GitGuard.snapshot(gitDirectory: f.git.path)
        try f.write("[core]\n\tfsmonitor = changed-inert-value\n", to: linkedConfig)

        #expect(guardState.snapshotRefusals == ["extensions.worktreeConfig"])
        let result = await guardState.restoreSafely(gitDirectory: f.git.path)
        #expect(result.refused == ["extensions.worktreeConfig"])
        #expect(result.restored.isEmpty)
        #expect(try f.text(linkedConfig).contains("changed-inert-value"))
    }

    @Test func unreadableSnapshotCannotBeMistakenForAnEmptySnapshot() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write("[invalid", to: f.config)
        let guardState = await GitGuard.snapshot(gitDirectory: f.git.path)
        try f.write("[core]\n\tfsmonitor = changed-value\n", to: f.config)
        let result = await guardState.restoreSafely(gitDirectory: f.git.path)
        #expect(result.refused == ["config"])
        #expect(result.restored.isEmpty)
        #expect(try f.text(f.config).contains("changed-value"))
    }
}
