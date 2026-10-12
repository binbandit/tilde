import Darwin
import Foundation
import Synchronization
import Testing
@testable import TildeSupport

@Suite struct ShellTests {
    private let environment = ["PATH": "/bin:/usr/bin"]

    @Test func timeoutKillsAnUncooperativeCommandAndItsChildren() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "tilde-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let done = Mutex(false)
        let task = Task {
            let output = try await Shell.run(
                ["/bin/sh", "-c", "echo $$ > leader; trap '' TERM; sleep 30 & echo $! > descendant; wait"],
                cwd: root.path, environment: environment, timeout: .milliseconds(100))
            done.withLock { $0 = true }
            return output
        }
        try await Task.sleep(for: .seconds(1))
        #expect(done.withLock { $0 })
        if !done.withLock({ $0 }) {
            let pid = Int32(try String(contentsOf: root.appending(path: "leader"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
            // Foundation's original Process does not create a new process group.
            // Its shell's background sleep is cleaned up by the recorded child pid.
            let descendants = try String(contentsOf: root.appending(path: "descendant"), encoding: .utf8)
            if let descendant = Int32(descendants.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(descendant, SIGKILL) }
            kill(pid, SIGKILL)
        }
        let output = try await task.value
        #expect(output.timedOut)
        #expect(!output.ok)
    }

    @Test func preservesOutputIncludingBlankLinesAndUnterminatedText() async throws {
        let output = try await Shell.run(
            ["/bin/sh", "-c", "printf 'first\\n\\nlast'; printf 'problem\\n\\nend' >&2"], environment: environment)
        #expect(output.ok)
        #expect(output.stdout == "first\n\nlast")
        #expect(output.stderr == "problem\n\nend")
    }

    @Test func timeoutAlsoClosesPipesInheritedFromAnExitedLeader() async throws {
        let started = ContinuousClock.now
        let output = try await Shell.run(
            ["/bin/sh", "-c", "(trap '' TERM; sleep 10) & exit 0"], environment: environment,
            timeout: .milliseconds(100))
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

    @Test func cancellationStopsACommandEvenWhileInputIsBlocked() async throws {
        let task = Task {
            try await Shell.run(
                ["/bin/sh", "-c", "trap '' TERM; sleep 10"], environment: environment,
                input: String(repeating: "x", count: 1_000_000))
        }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func aLaunchFailureThrows() async {
        await #expect(throws: ChildProcess.Failure.self) {
            try await Shell.run(["/tilde-test-does-not-exist"], environment: environment)
        }
    }

    @Test func timeoutDoesNotWaitForeverOnADetachedHelpersPipe() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "tilde-detached-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        if let text = try? String(contentsOf: root.appending(path: "pid"), encoding: .utf8), let pid = Int32(text) {
            kill(pid, SIGKILL)
        }
        #expect(elapsed < .seconds(2))
        #expect(output.timedOut)
    }

    @Test(arguments: [false, true])
    func shutdownInterruptsInputHeldByADetachedHelper(cancel: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "tilde-detached-input-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = """
            import os, time
            r, w = os.pipe()
            if os.fork():
                os.close(w)
                os.read(r, 1)
                os._exit(0)
            os.close(r)
            os.setsid()
            with open('pid', 'w') as f: f.write(str(os.getpid()))
            os.write(w, b'x')
            os.close(w)
            time.sleep(10)
            """
        let done = Mutex(false)
        let task = Task {
            defer { done.withLock { $0 = true } }
            return try await Shell.run(
                ["/usr/bin/python3", "-I", "-c", script], cwd: root.path, environment: environment,
                input: String(repeating: "x", count: 2_000_000), timeout: cancel ? nil : .milliseconds(200))
        }
        try await Task.sleep(for: .milliseconds(200))
        if cancel { task.cancel() }
        try await Task.sleep(for: .milliseconds(800))
        #expect(done.withLock { $0 })
        // Deliberately detached from Shell's group; clean up even on the failing baseline.
        if let text = try? String(contentsOf: root.appending(path: "pid"), encoding: .utf8), let pid = Int32(text) {
            kill(pid, SIGKILL)
        }
        if cancel {
            await #expect(throws: CancellationError.self) { try await task.value }
        } else {
            #expect(try await task.value.timedOut)
        }
    }
}
