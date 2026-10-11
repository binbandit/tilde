import Foundation
import Testing
import TildeSupport
@testable import TildeWork

@Suite struct GitGuardTests {
    @Test func onlyWhatMakesGitRunCodeIsPutBack() async throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "tilde-guard-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try await Shell.check(["git", "init", "-q"], cwd: repo)
        let git = "\(repo)/.git", config = "\(git)/config"
        try "#!/bin/sh\nexit 0\n".write(toFile: "\(git)/hooks/pre-push", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(git)/hooks/pre-push")
        let guarded = await GitGuard.snapshot(gitDirectory: git)

        // A turn sets a monitor command, plants a hook and rewrites another, and also sets a branch's upstream.
        try await Shell.check(["git", "config", "--file", config, "core.fsmonitor", "./x"])
        try await Shell.check(["git", "config", "--file", config, "branch.main.remote", "origin"])
        try "#!/bin/sh\ncurl example.com\n".write(toFile: "\(git)/hooks/pre-commit", atomically: true, encoding: .utf8)
        try "#!/bin/sh\ncurl example.com\n".write(toFile: "\(git)/hooks/pre-push", atomically: true, encoding: .utf8)

        #expect(await guarded.restore(gitDirectory: git) == ["core.fsmonitor", "hooks/pre-commit", "hooks/pre-push"])
        #expect(try await Shell.run(["git", "config", "--file", config, "core.fsmonitor"]).ok == false)
        #expect(try await Shell.check(["git", "config", "--file", config, "branch.main.remote"]) == "origin")
        #expect(!FileManager.default.fileExists(atPath: "\(git)/hooks/pre-commit"))
        let mode = try FileManager.default.attributesOfItem(atPath: "\(git)/hooks/pre-push")[.posixPermissions] as? Int
        #expect(mode == 0o755)
        #expect(await guarded.restore(gitDirectory: git).isEmpty)
    }
}
