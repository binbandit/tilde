import Foundation
import Testing
import WorkerKit
@testable import CodexWorkers

@Suite(.timeLimit(.minutes(1))) struct CodexWorkerTests {
    @Test func commandsAreDescribedByWhatTheShellRuns() {
        #expect(CodexWorker.describe(["type": "commandExecution", "command": "/bin/zsh -lc 'swift build'"]) == "Running swift build")
    }

    @Test func anEarlierCompletionComesBeforeTheSubmissionMarker() async throws {
        let fixture = try SubmissionFixture()
        defer { fixture.clean() }
        let worker = fixture.worker()
        var events = worker.events.makeAsyncIterator()
        let submission = UUID()
        try await worker.start(brief: "first", submission: submission)
        #expect(await events.lines(through: "turn finished: first") == [
            "turn previous completion", "submitted \(submission)", "turn finished: first",
        ])
        await worker.stop()
    }

    @Test func aTurnCompletedBeforeItsStartReplyLeavesTheSessionIdle() async throws {
        let fixture = try SubmissionFixture()
        defer { fixture.clean() }
        let worker = fixture.worker()
        var events = worker.events.makeAsyncIterator()
        try await worker.start(brief: "first", submission: UUID())
        _ = await events.lines(through: "turn finished: first")

        // Idle, the next message starts a turn. Steering the finished one would throw: the fake rejects it.
        let next = UUID()
        try await worker.steer("second", submission: next)
        #expect(await events.lines(through: "turn finished: second") == ["submitted \(next)", "turn finished: second"])
        #expect(try fixture.requests().filter { $0.hasPrefix("turn/") } == ["turn/start", "turn/start"])
        await worker.stop()
    }

    @Test func steeringAStoppedWorkerStartsItAgainWithTheCallersSubmission() async throws {
        let fixture = try SubmissionFixture()
        defer { fixture.clean() }
        let worker = fixture.worker()
        var events = worker.events.makeAsyncIterator()
        try await worker.start(brief: "first", submission: UUID())
        _ = await events.lines(through: "turn finished: first")
        await worker.stop()

        let resumed = UUID()
        try await worker.steer("resumed", submission: resumed)
        #expect(await events.lines(through: "turn finished: resumed").suffix(2) == ["submitted \(resumed)", "turn finished: resumed"])
        await worker.stop()
    }
}

private extension AsyncStream.Iterator where Element == WorkerEvent {
    /// Submission markers and turn ends as lines, up to and including `last`.
    mutating func lines(through last: String) async -> [String] {
        var lines: [String] = []
        while lines.last != last, let event = await next() {
            switch event {
            case .submitted(let id): lines.append("submitted \(id)")
            case .turnEnded(_, let text): lines.append("turn \(text)")
            default: break
            }
        }
        return lines
    }
}

private struct SubmissionFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "tilde-codex-submission-\(UUID().uuidString)")
    var executable: URL { root.appending(path: "codex") }
    var log: URL { root.appending(path: "requests") }

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/fake_submission_server.py")
        try "#!/bin/sh\nexport FAKE_LOG='\(log.path)'\nexec /usr/bin/python3 -I '\(script.path)'\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func worker() -> CodexWorker { CodexWorker(workdir: root.path, executable: executable.path) }
    /// The methods the fake was asked to run, in order.
    func requests() throws -> [String] { try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init) }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
