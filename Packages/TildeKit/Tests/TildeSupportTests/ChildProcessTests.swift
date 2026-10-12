import Darwin
import Foundation
import Synchronization
import Testing
@testable import TildeSupport

@Suite struct ChildProcessTests {
    @Test func childProcessStreamsLinesAndReportsExit() async throws {
        let child = try ChildProcess(.init(
            executable: "/bin/sh", arguments: ["-c", "echo one; echo two; read x; echo got $x; exit 3"], cwd: "/tmp",
            environment: ["PATH": "/bin:/usr/bin"]))
        try child.write(Data("ping\n".utf8))
        var lines: [String] = []
        for await line in child.lines { lines.append(line) }
        #expect(lines == ["one", "two", "got ping"])
        #expect(await child.waitForExit() == 3)
    }

    @Test func terminateEscalatesToSIGKILL() async throws {
        let child = try ChildProcess(.init(
            executable: "/bin/sh", arguments: ["-c", "trap '' TERM; sleep 30"], cwd: "/tmp", environment: ["PATH": "/bin:/usr/bin"]))
        try await Task.sleep(for: .milliseconds(100))
        let started = Date()
        await child.terminate(grace: .milliseconds(300))
        #expect(child.exitStatus != nil)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func terminateKillsTheWholeGroup() async throws {
        let child = try ChildProcess(.init(
            executable: "/bin/sh", arguments: ["-c", "sleep 30 & sleep 30; wait"], cwd: "/tmp", environment: ["PATH": "/bin:/usr/bin"]))
        await child.terminate(grace: .milliseconds(200))
        #expect(await child.waitForExit() != 0)
    }

    @Test func terminateEscalatesAfterTheLeaderExits() async throws {
        let child = try ChildProcess(.init(
            executable: "/bin/sh", arguments: ["-c", "(trap '' TERM; echo ready; while :; do sleep 1; done) & wait"],
            cwd: "/tmp", environment: ["PATH": "/bin:/usr/bin"]))
        let drained = Mutex(false)
        var lines = child.lines.makeAsyncIterator()
        #expect(await lines.next() == "ready")
        let drain = Task {
            while await lines.next() != nil {}
            drained.withLock { $0 = true }
        }
        await child.terminate(grace: .milliseconds(100))
        try await Task.sleep(for: .milliseconds(250))
        #expect(drained.withLock { $0 })
        // Also clean up when exercising the broken implementation.
        if !drained.withLock({ $0 }) { killpg(child.pid, SIGKILL) }
        await drain.value
    }

    @Test func anExitedLeaderDoesNotLeaveItsChildrenRunning() async throws {
        let child = try ChildProcess(.init(
            executable: "/bin/sh", arguments: ["-c", "(trap '' TERM; echo ready; while :; do sleep 1; done) & read line; exit 0"],
            cwd: "/tmp", environment: ["PATH": "/bin:/usr/bin"]))
        var lines = child.lines.makeAsyncIterator()
        #expect(await lines.next() == "ready")
        try child.write(Data("exit\n".utf8))
        try await Task.sleep(for: .milliseconds(100))
        let drained = Mutex(false)
        let drain = Task {
            while await lines.next() != nil {}
            drained.withLock { $0 = true }
        }
        await child.terminate(grace: .milliseconds(100))
        try await Task.sleep(for: .milliseconds(250))
        #expect(drained.withLock { $0 })
        if !drained.withLock({ $0 }) { killpg(child.pid, SIGKILL) }
        await drain.value
    }

    @Test func largeConcurrentWritesStayWholeAndExact() async throws {
        let child = try ChildProcess(.init(
            executable: "/bin/cat", arguments: [], cwd: "/tmp", environment: ["PATH": "/bin:/usr/bin"]))
        let first = String(repeating: "a", count: 200_000)
        let second = String(repeating: "b", count: 200_000)
        let one = Task.detached { try child.write(Data((first + "\n").utf8)) }
        let two = Task.detached { try child.write(Data((second + "\n").utf8)) }
        try await one.value
        try await two.value
        child.closeStdin()
        var lines: [String] = []
        for await line in child.lines { lines.append(line) }
        #expect(lines.sorted() == [first, second])
        #expect(await child.waitForExit() == 0)
    }
}
