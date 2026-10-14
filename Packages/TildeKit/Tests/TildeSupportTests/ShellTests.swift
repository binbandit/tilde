import Darwin
import Foundation
import Testing
@testable import TildeSupport

@Suite(.timeLimit(.minutes(1))) struct ShellTests {
    private let environment = ["PATH": "/bin:/usr/bin"]
    private let root = FileManager.default.temporaryDirectory.appending(path: "tilde-shell-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// The PID a fixture wrote to `name` in `root`.
    private func pid(_ name: String) throws -> pid_t? {
        pid_t(try String(contentsOf: root.appending(path: name), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test func timeoutStopsAnUncooperativeCommandAndItsChildren() async throws {
        let started = ContinuousClock.now
        let output = try await Shell.run(
            ["/bin/sh", "-c", "trap '' TERM; sleep 30 & echo $! > child; wait"],
            cwd: root.path, environment: environment, timeout: .milliseconds(100))
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(output.timedOut)
        #expect(!output.ok)
        // Killed, the orphan is reaped by launchd rather than by us.
        let child = try #require(try pid("child"))
        for _ in 0..<100 where kill(child, 0) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kill(child, 0) == -1)
    }

    @Test func preservesOutputIncludingBlankLinesAndUnterminatedText() async throws {
        let output = try await Shell.run(
            ["/bin/sh", "-c", "printf 'first\\n\\nlast'; printf 'problem\\n\\nend' >&2"], environment: environment)
        #expect(output.ok)
        #expect(output.stdout == "first\n\nlast")
        #expect(output.stderr == "problem\n\nend")
    }

    @Test func timeoutReturnsWhileAnExitedLeadersChildHoldsThePipes() async throws {
        let started = ContinuousClock.now
        let output = try await Shell.run(
            ["/bin/sh", "-c", "sleep 10 & echo $! > child; exit 0"], cwd: root.path, environment: environment,
            timeout: .milliseconds(100))
        // A command may leave something running on purpose, so Shell leaves it to finish.
        if let child = try pid("child") { kill(child, SIGKILL) }
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(output.timedOut)
    }

    @Test func drainsBothPipesWithoutTruncatingStderr() async throws {
        let output = try await Shell.run(
            ["/bin/sh", "-c", "printf '%020000d' 0; printf '%020000d' 0 >&2"], environment: environment)
        #expect(output.ok)
        #expect(output.stdout == String(repeating: "0", count: 20_000))
        #expect(output.stderr == output.stdout)
    }

    @Test func aLaunchFailureThrows() async {
        await #expect(throws: ChildProcess.Failure.self) {
            try await Shell.run(["/tilde-test-does-not-exist"], environment: environment)
        }
    }

    @Test func timeoutDoesNotWaitForeverOnADetachedHelpersPipe() async throws {
        let script = """
            import os, time
            if os.fork() == 0:
                os.setsid()
                with open('pid', 'w') as f: f.write(str(os.getpid()))
                time.sleep(10)
            """
        let started = ContinuousClock.now
        let output = try await Shell.run(
            ["/usr/bin/python3", "-I", "-c", script], cwd: root.path, environment: environment,
            timeout: .milliseconds(200))
        let elapsed = ContinuousClock.now - started
        // The detached helper is outside the group Shell owns. Only this fixture knows its PID.
        if let helper = try? pid("pid") { kill(helper, SIGKILL) }
        #expect(elapsed < .seconds(2))
        #expect(output.timedOut)
    }

    @Test func quotedTextIsOneWordToSh() async throws {
        let text = "it's $HOME `id` \"x\""
        let output = try await Shell.run(["/bin/sh", "-c", "printf %s \(Shell.quote(text))"], environment: environment)
        #expect(output.stdout == text)
    }
}
