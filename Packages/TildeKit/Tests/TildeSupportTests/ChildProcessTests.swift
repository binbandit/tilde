import Darwin
import Foundation
import Synchronization
import Testing
@testable import TildeSupport

@Suite(.timeLimit(.minutes(1))) struct ChildProcessTests {
    func spawn(_ script: String) throws -> ChildProcess {
        try ChildProcess(.init(executable: "/bin/sh", arguments: ["-c", script], cwd: "/tmp", environment: ["PATH": "/bin:/usr/bin"]))
    }

    @Test func childProcessStreamsLinesAndReportsExit() async throws {
        let child = try spawn("echo one; echo two; read x; echo got $x; exit 3")
        try child.write(Data("ping\n".utf8))
        var lines: [String] = []
        for await line in child.lines { lines.append(line) }
        #expect(lines == ["one", "two", "got ping"])
        #expect(await child.waitForExit() == 3)
    }

    @Test func terminateEscalatesToSIGKILL() async throws {
        let child = try spawn("trap '' TERM; echo ready; sleep 30")
        var lines = child.lines.makeAsyncIterator()
        #expect(await lines.next() == "ready")
        let started = ContinuousClock.now
        await child.terminate(grace: .milliseconds(300))
        #expect(child.exitStatus == 128 + SIGKILL)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func terminateStopsTheWholeGroup() async throws {
        // The leader dies on SIGTERM; its child ignores it and holds stdout open until it's killed.
        let child = try spawn("(trap '' TERM; echo ready; exec sleep 30) & wait")
        var lines = child.lines.makeAsyncIterator()
        #expect(await lines.next() == "ready")
        let started = ContinuousClock.now
        await child.terminate(grace: .milliseconds(100))
        while await lines.next() != nil {}
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func anExitedLeadersChildrenAreStopped() async throws {
        let child = try spawn("(echo ready; exec sleep 30) & read line; exit 0")
        var lines = child.lines.makeAsyncIterator()
        #expect(await lines.next() == "ready")
        let started = ContinuousClock.now
        try child.write(Data("exit\n".utf8))
        // stdout ends once the child, which never exits on its own, has been stopped.
        while await lines.next() != nil {}
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func theLeadersExitIsReportedWhileItsGroupIsStillStopping() async throws {
        // The child ignores SIGTERM, so it outlives the leader until SIGKILL.
        let child = try spawn("(trap '' TERM; echo ready; exec sleep 30) & read line; exit 4")
        var lines = child.lines.makeAsyncIterator()
        #expect(await lines.next() == "ready")
        let started = ContinuousClock.now
        try child.write(Data("exit\n".utf8))
        #expect(await child.waitForExit() == 4)
        #expect(ContinuousClock.now - started < ChildProcess.grace)
        await child.terminate(grace: .milliseconds(100))
        while await lines.next() != nil {}
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

    @Test func terminationEscalatesWhileANonreadingChildHoldsAFullStdinPipe() async throws {
        let child = try spawn("trap '' TERM; echo ready; exec sleep 30")
        defer { killpg(child.pid, SIGKILL) }
        var lines = child.lines.makeAsyncIterator()
        #expect(await lines.next() == "ready")
        let writeFinished = Mutex(false), stopFinished = Mutex(false), watchdogFired = Mutex(false)
        let writing = Task.detached {
            try? child.write(Data(repeating: 65, count: 1_000_000))
            writeFinished.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!writeFinished.withLock { $0 })
        // Keep the regression bounded even if termination never reaches its own SIGKILL timer.
        let watchdog = Task.detached {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled, !stopFinished.withLock({ $0 }) {
                watchdogFired.withLock { $0 = true }
                killpg(child.pid, SIGKILL)
            }
        }
        defer { watchdog.cancel() }
        let started = ContinuousClock.now
        await child.terminate(grace: .milliseconds(100))
        stopFinished.withLock { $0 = true }
        await writing.value
        #expect(!watchdogFired.withLock { $0 })
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(child.exitStatus == 128 + SIGKILL)
    }
}
