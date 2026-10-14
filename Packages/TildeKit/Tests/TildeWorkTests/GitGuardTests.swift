import Foundation
import Testing
import TildeSupport
@testable import TildeWork

/// Each test is a scratch repo where the test plays a worker's turn between the snapshot and the restore.
/// Nothing here runs the code it plants: config is only read with `git config --file`.
@Suite struct GitGuardTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "tilde-guard-\(UUID().uuidString)").path
    var repo: String { "\(root)/repo" }
    var git: String { "\(repo)/.git" }
    var hooks: String { "\(git)/hooks" }
    /// Somewhere a planted link points that a restore must never write.
    var outside: String { "\(root)/outside" }

    init() async throws {
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        // No template, so the hooks are exactly what the test puts there.
        try await run("init", "-q", "-b", "main", "--template=")
        try await run("commit", "-q", "--allow-empty", "-m", "init")
        try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        try write("#!/bin/sh\nexit 0\n", to: "\(hooks)/pre-push", mode: 0o755)
    }

    func run(_ args: String..., in cwd: String? = nil) async throws {
        try await Shell.check(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args, cwd: cwd ?? repo)
    }

    func config(_ args: String..., file: String? = nil) async throws -> Shell.Output {
        try await Shell.run(["git", "config", "--file", file ?? "\(git)/config"] + args)
    }

    func write(_ text: String, to path: String, mode: Int = 0o644) throws {
        try text.write(toFile: path, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    func read(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }
    func link(_ path: String) -> String? { try? FileManager.default.destinationOfSymbolicLink(atPath: path) }
    func mode(_ path: String) throws -> Int? { try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int }

    @Test func codeRunningConfigIsPutBackAndTheRestIsKept() async throws {
        let guarded = await GitGuard.snapshot(repository: repo)
        #expect(guarded.snapshotRefusals.isEmpty)
        _ = try await config("core.fsmonitor", "./monitor")
        // git keeps a subsection's case, so this key only unsets as `filter.Evil.clean`.
        _ = try await config("filter.Evil.clean", "./clean")
        try await run("remote", "add", "origin", "https://example.com/repo.git")

        #expect(await guarded.restore() == GitGuard.Restoration(restored: ["core.fsmonitor", "filter.Evil.clean"]))
        #expect(try await config("--list").stdout.contains("fsmonitor") == false)
        #expect(try await config("--list").stdout.contains("filter.") == false)
        #expect(try await config("remote.origin.url").trimmed == "https://example.com/repo.git")
        #expect(await guarded.restore() == GitGuard.Restoration())
    }

    @Test func plantedAndRewrittenHooksArePutBack() async throws {
        try write("#!/bin/sh\necho owner\n", to: "\(outside)/kept")
        let guarded = await GitGuard.snapshot(repository: repo)
        try write("#!/bin/sh\ncurl example.com\n", to: "\(hooks)/pre-commit", mode: 0o755)
        try write("#!/bin/sh\ncurl example.com\n", to: "\(hooks)/pre-push", mode: 0o700)
        try FileManager.default.createSymbolicLink(atPath: "\(hooks)/post-checkout", withDestinationPath: "\(outside)/kept")

        #expect(await guarded.restore().restored == ["hooks/post-checkout", "hooks/pre-commit", "hooks/pre-push"])
        #expect(!FileManager.default.fileExists(atPath: "\(hooks)/pre-commit"))
        #expect(link("\(hooks)/post-checkout") == nil)
        #expect(try read("\(hooks)/pre-push") == "#!/bin/sh\nexit 0\n")
        #expect(try mode("\(hooks)/pre-push") == 0o755)
        #expect(try read("\(outside)/kept") == "#!/bin/sh\necho owner\n")
    }

    @Test func aHookSwappedForALinkIsReplacedNotWrittenThrough() async throws {
        let guarded = await GitGuard.snapshot(repository: repo)
        try write("outside", to: "\(outside)/sentinel")
        try FileManager.default.removeItem(atPath: "\(hooks)/pre-push")
        try FileManager.default.createSymbolicLink(atPath: "\(hooks)/pre-push", withDestinationPath: "\(outside)/sentinel")

        #expect(await guarded.restore().restored == ["hooks/pre-push"])
        #expect(link("\(hooks)/pre-push") == nil)
        #expect(try read("\(hooks)/pre-push") == "#!/bin/sh\nexit 0\n")
        #expect(try read("\(outside)/sentinel") == "outside")
    }

    @Test(arguments: [true, false]) func aSwappedHooksDirectoryIsRebuilt(withALink: Bool) async throws {
        let guarded = await GitGuard.snapshot(repository: repo)
        let planted = withALink ? outside : "\(root)/planted"
        try FileManager.default.createDirectory(atPath: planted, withIntermediateDirectories: true)
        try write("#!/bin/sh\ncurl example.com\n", to: "\(planted)/pre-commit", mode: 0o755)
        try FileManager.default.moveItem(atPath: hooks, toPath: "\(git)/moved-hooks")
        if withALink {
            try FileManager.default.createSymbolicLink(atPath: hooks, withDestinationPath: planted)
        } else {
            try FileManager.default.moveItem(atPath: planted, toPath: hooks)
        }

        let restored = await guarded.restore().restored
        #expect(restored == (withALink ? ["hooks", "hooks/pre-push"] : ["hooks/pre-commit", "hooks/pre-push"]))
        #expect(link(hooks) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: hooks) == ["pre-push"])
        #expect(try read("\(hooks)/pre-push") == "#!/bin/sh\nexit 0\n")
        if withALink { #expect(FileManager.default.fileExists(atPath: "\(outside)/pre-commit")) }
    }

    @Test func linkedHooksAreGuardedAsLinks() async throws {
        // A common setup: `ln -s ../../scripts/pre-commit .git/hooks/`.
        try FileManager.default.createSymbolicLink(atPath: "\(hooks)/pre-commit", withDestinationPath: "../../scripts/pre-commit")
        let guarded = await GitGuard.snapshot(repository: repo)
        #expect(guarded.snapshotRefusals.isEmpty)
        #expect(await guarded.restore() == GitGuard.Restoration())

        try FileManager.default.removeItem(atPath: "\(hooks)/pre-commit")
        try write("#!/bin/sh\ncurl example.com\n", to: "\(hooks)/pre-commit", mode: 0o755)
        #expect(await guarded.restore().restored == ["hooks/pre-commit"])
        #expect(link("\(hooks)/pre-commit") == "../../scripts/pre-commit")
    }

    @Test func sparseCheckoutsGuardEachWorktreesOwnConfig() async throws {
        // `sparse-checkout set` turns on extensions.worktreeConfig, and a new worktree inherits it.
        try await run("sparse-checkout", "set", "src")
        try await run("worktree", "add", "-q", "-b", "job", "\(root)/job")
        let guarded = await GitGuard.snapshot(repository: repo)
        #expect(guarded.snapshotRefusals.isEmpty)
        let main = "\(git)/config.worktree", job = "\(git)/worktrees/job/config.worktree"
        for file in [main, job] { _ = try await config("core.fsmonitor", "./monitor", file: file) }

        #expect(await guarded.restore().restored == ["config.worktree:core.fsmonitor", "worktrees/job/config.worktree:core.fsmonitor"])
        for file in [main, job] {
            #expect(try await config("core.fsmonitor", file: file).ok == false)
            #expect(try await config("core.sparsecheckout", file: file).trimmed == "true")
        }
    }

    @Test func aRepositoryWhoseGitIsAFileIsGuardedAtItsGitDirectory() async throws {
        try await run("worktree", "add", "-q", "-b", "linked", "\(root)/linked")
        let guarded = await GitGuard.snapshot(repository: "\(root)/linked")
        #expect(guarded.snapshotRefusals.isEmpty)
        _ = try await config("core.fsmonitor", "./monitor")
        #expect(await guarded.restore().restored == ["core.fsmonitor"])
        #expect(try await config("core.fsmonitor").ok == false)
    }

    @Test func aConfigSwappedForALinkIsRefusedNotWrittenThrough() async throws {
        let guarded = await GitGuard.snapshot(repository: repo)
        try write("[core]\n\tfsmonitor = ./monitor\n", to: "\(outside)/config")
        try FileManager.default.removeItem(atPath: "\(git)/config")
        try FileManager.default.createSymbolicLink(atPath: "\(git)/config", withDestinationPath: "\(outside)/config")

        #expect(await guarded.restore().refused == ["config"])
        #expect(try read("\(outside)/config") == "[core]\n\tfsmonitor = ./monitor\n")
    }
}
