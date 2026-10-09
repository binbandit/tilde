import Foundation
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
}
