import Foundation
import Testing
@testable import TildeSupport

@Suite struct UserEnvironmentTests {
    /// A stand-in login shell: `body` runs first, then the `-c` command tilde passes.
    private func shell(_ body: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "tilde-shell-\(UUID().uuidString)")
        let script = """
            #!/bin/sh
            interactive=no
            while [ "$1" != "-c" ]; do [ "$1" = "-i" ] && interactive=yes; shift; done
            \(body)
            eval "$2"
            """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }

    @Test func takesEverythingTheLoginShellExports() throws {
        let fake = try shell("""
            export TILDE_TEST_KEY=sk-test
            export TILDE_TEST_LINES='one
            two'
            """)
        let env = try #require(UserEnvironment.login(shell: fake))
        #expect(env["TILDE_TEST_KEY"] == "sk-test")
        #expect(env["TILDE_TEST_LINES"] == "one\ntwo")
    }

    /// `exec fish` at the end of a .zshrc: the interactive shell never runs the command.
    @Test func fallsBackToAPlainLoginShellWhenTheInteractiveOneIsReplaced() throws {
        let fake = try shell("""
            [ $interactive = yes ] && exit 0
            export TILDE_TEST_KEY=from-login
            """)
        #expect(UserEnvironment.login(shell: fake)?["TILDE_TEST_KEY"] == "from-login")
    }

    @Test func givesUpOnAShellThatNeverFinishes() throws {
        let fake = try shell("exec sleep 30")
        let started = Date()
        #expect(UserEnvironment.login(shell: fake, timeout: 0.3) == nil)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func captureIsPrivateBeforeTheShellWritesIt() throws {
        let fake = try shell("""
            capture=$(printf '%s' "$2" | /usr/bin/cut -d "'" -f 2)
            export TILDE_TEST_FILE_MODE=$(/usr/bin/stat -f %Lp "$capture")
            export TILDE_TEST_DIR_MODE=$(/usr/bin/stat -f %Lp "$(/usr/bin/dirname "$capture")")
            """)
        defer { try? FileManager.default.removeItem(atPath: fake) }
        let env = try #require(UserEnvironment.login(shell: fake))
        #expect(env["TILDE_TEST_FILE_MODE"] == "600")
        #expect(env["TILDE_TEST_DIR_MODE"] == "700")
    }

    @Test func timedOutShellCannotRecreateItsCredentialCapture() throws {
        let record = FileManager.default.temporaryDirectory.appending(path: "tilde-timeout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: record) }
        let fake = try shell("""
            printf '%s\\n%s' "$$" "$2" > '\(record.path)'
            trap '' TERM
            sleep 1
            export TILDE_TEST_KEY=synthetic-secret
            """)
        defer { try? FileManager.default.removeItem(atPath: fake) }
        #expect(UserEnvironment.login(shell: fake, timeout: 0.1) == nil)
        let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n", maxSplits: 1)
        let pid = try #require(Int32(lines[0]))
        #expect(kill(pid, 0) == -1)
        let command = String(lines[1])
        let path = try #require(command.split(separator: "'").dropFirst().first)
        #expect(!FileManager.default.fileExists(atPath: String(path)))
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: String(path)).deletingLastPathComponent().path))
    }
}
