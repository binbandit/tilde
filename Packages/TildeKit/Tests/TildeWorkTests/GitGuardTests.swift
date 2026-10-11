import Foundation
import Testing
@testable import TildeWork

@Suite struct GitGuardTests {
    @Test func whatMakesGitRunCodeIsPutBack() throws {
        let git = FileManager.default.temporaryDirectory.appending(path: "tilde-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: git.appending(path: "hooks"), withIntermediateDirectories: true)
        try "[core]\n\tbare = false\n".write(to: git.appending(path: "config"), atomically: true, encoding: .utf8)
        let guarded = GitGuard.snapshot(gitDirectory: git.path)

        // A worker sets a monitor command and plants a hook; objects and refs are its to write.
        try "[core]\n\tfsmonitor = ./x\n".write(to: git.appending(path: "config"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(to: git.appending(path: "hooks/pre-commit"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: git.appending(path: "objects/ab"), withIntermediateDirectories: true)

        #expect(guarded.restore(gitDirectory: git.path) == ["config", "hooks/pre-commit"])
        #expect(try String(contentsOf: git.appending(path: "config"), encoding: .utf8).contains("bare = false"))
        #expect(!FileManager.default.fileExists(atPath: git.appending(path: "hooks/pre-commit").path))
        #expect(guarded.restore(gitDirectory: git.path).isEmpty)
    }
}
