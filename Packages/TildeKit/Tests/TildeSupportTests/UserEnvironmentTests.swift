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
}
