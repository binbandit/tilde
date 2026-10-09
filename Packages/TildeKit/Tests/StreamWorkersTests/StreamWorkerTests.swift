import Foundation
import Testing
import TildeSupport
import WorkerKit
@testable import StreamWorkers

/// Runs `StreamWorker` against the fake harnesses in Fixtures.
@Suite struct StreamWorkerTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "tilde-stream-tests-\(UUID().uuidString)")
    var workdir: String { root.appending(path: "work").path }

    init() throws {
        try FileManager.default.createDirectory(atPath: root.appending(path: "work").path, withIntermediateDirectories: true)
    }

    func worker(_ dialect: some StreamDialect, fake: String, sessionID: String? = nil) -> StreamWorker {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(fake)")
        return StreamWorker(
            dialect, launch: WorkerLaunch(workdir: workdir, sessionID: sessionID, instructions: "Work for tilde."),
            executable: fixture.path,
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "FAKE_LOG": root.appending(path: "fake.log").path],
            scratch: root.appending(path: "scratch"))
    }

    // MARK: Amp

    @Test func ampRunsTurnsOnOneThread() async throws {
        let amp = worker(AmpDialect(), fake: "fake_amp.py")
        let log = StreamEvents(amp)
        try await amp.start(brief: "say hi")
        #expect(try await log.next(StreamPick.session) == "T-fake-0001")
        #expect(try await log.next(StreamPick.turn) == StreamTurn(ok: true, text: "T-fake-0001 heard: say hi (briefed)"))

        // Same process: no brief again, and no resume.
        try await amp.steer("and again")
        #expect(try await log.next(StreamPick.turn) == StreamTurn(ok: true, text: "T-fake-0001 heard: and again"))
        await amp.stop()
        #expect(try await log.next(StreamPick.exit) == .some(nil))
    }

    @Test func ampGateAllowsOrdinaryWorkAndEscalatesRails() async throws {
        let amp = worker(AmpDialect(), fake: "fake_amp.py")
        let log = StreamEvents(amp)
        try await amp.start(brief: "gate swift build")
        #expect(try await log.next(StreamPick.turn) == StreamTurn(ok: true, text: "ran swift build"))
        #expect(await log.all.allSatisfy { StreamPick.request($0) == nil })

        try await amp.steer("gate git push origin main")
        let request = try await log.next(StreamPick.request)
        guard case .permission(let tool, let action, let rail) = request.kind else { Issue.record("not a permission"); return }
        #expect(tool == "Bash" && action == "git push origin main" && rail == "Pushes to a remote")
        await amp.resolve(request.id, .deny("Not before review."))
        #expect(try await log.next(StreamPick.turn) == StreamTurn(ok: true, text: "Tool execution rejected by user: Not before review."))
        await amp.stop()
    }

    @Test func ampPicksItsThreadBackUpAfterAnError() async throws {
        let amp = worker(AmpDialect(), fake: "fake_amp.py", sessionID: "T-earlier")
        let log = StreamEvents(amp)
        try await amp.start(brief: "fail")
        #expect(try await log.next(StreamPick.session) == "T-earlier")
        #expect(try await log.next(StreamPick.turn) == StreamTurn(ok: false, text: "Rate limited, try again later"))

        // Amp exited with the error; the follow-up continues the thread in a new process.
        try await amp.steer("carry on")
        #expect(try await log.next(StreamPick.turn) == StreamTurn(ok: true, text: "T-earlier heard: carry on (resumed)"))
        await amp.stop()
    }

    @Test func ampCrashingMidTurnEndsTheWorker() async throws {
        let amp = worker(AmpDialect(), fake: "fake_amp.py")
        let log = StreamEvents(amp)
        try await amp.start(brief: "crash")
        let detail = try await log.next(StreamPick.exit)
        #expect(detail?.hasPrefix("Amp exited (3).") == true)
        await #expect(throws: (any Error).self) { try await amp.steer("hello?") }
    }

    @Test func ampStopTerminatesARunningTurn() async throws {
        let amp = worker(AmpDialect(), fake: "fake_amp.py")
        let log = StreamEvents(amp)
        try await amp.start(brief: "hang")
        #expect(try await log.next(StreamPick.activity) == "Running sleep 60")
        await amp.stop()
        #expect(try await log.next(StreamPick.exit) == .some(nil))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "scratch").path))
    }

    // MARK: Pi

    @Test func piGatesSteersAndAsks() async throws {
        let pi = worker(PiDialect(), fake: "fake_pi.py", sessionID: "s-1")
        let log = StreamEvents(pi)
        try await pi.start(brief: "gate git push origin main")
        #expect(try await log.next(StreamPick.session) == "s-1")
        let request = try await log.next(StreamPick.request)
        #expect(request.headline == "Bash: git push origin main")

        // A follow-up mid-turn is steered into the running turn.
        try await pi.steer("also run the tests")
        await pi.resolve(request.id, .allow)
        #expect(try await log.next(StreamPick.turn) == StreamTurn(ok: true, text: "steered: also run the tests"))

        try await pi.steer("ask Sticky nav?")
        let question = try await log.next(StreamPick.request)
        guard case .question(let questions) = question.kind else { Issue.record("not a question"); return }
        #expect(questions == [WorkerQuestion(question: "Sticky nav?", options: ["Sticky", "Scroll away"], multiSelect: false)])
        await pi.resolve(question.id, .reply("sticky"))
        #expect(try await log.next(StreamPick.turn) == StreamTurn(ok: true, text: "picked Sticky"))
        await pi.stop()
    }

    @Test func piWritesAreJudgedFromTheWorktree() async throws {
        let pi = worker(PiDialect(), fake: "fake_pi.py", sessionID: "s-3")
        let log = StreamEvents(pi)
        try await pi.start(brief: "write notes/todo.md")
        #expect(try await log.next(StreamPick.turn) == StreamTurn(ok: true, text: "ran notes/todo.md"))

        try await pi.steer("write ../elsewhere.md")
        let request = try await log.next(StreamPick.request)
        guard case .permission(let tool, _, let rail) = request.kind else { Issue.record("not a permission"); return }
        #expect(tool == "Write" && rail?.hasPrefix("Writes outside the job's worktree") == true)
        await pi.resolve(request.id, .deny("Stay in the worktree."))
        #expect(try await log.next(StreamPick.turn) == StreamTurn(ok: true, text: "blocked: deny: Stay in the worktree."))
        await pi.stop()
    }

    @Test func piStopAbortsTheRunFirst() async throws {
        let pi = worker(PiDialect(), fake: "fake_pi.py", sessionID: "s-2")
        let log = StreamEvents(pi)
        try await pi.start(brief: "hang")
        #expect(try await log.next(StreamPick.activity) == "Running sleep 60")
        await pi.stop()
        #expect(try await log.next(StreamPick.exit) == .some(nil))
        let received = try String(contentsOf: root.appending(path: "fake.log"), encoding: .utf8)
        #expect(received.split(separator: "\n") == ["prompt", "abort"])
    }
}
