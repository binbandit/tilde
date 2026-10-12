import Foundation
import Synchronization
import Testing
import WorkerKit
@testable import CodexWorkers

@Suite struct CodexWorkerTests {
    @Test func commandsAreDescribedByWhatTheShellRuns() {
        #expect(CodexWorker.describe(["type": "commandExecution", "command": "/bin/zsh -lc 'swift build'"]) == "Running swift build")
    }

    @Test(.timeLimit(.minutes(1))) func submissionOrdersBufferedOldCompletionAndNewCompletionBeforeTheRPCReply() async throws {
        let fixture = try SubmissionFixture()
        defer { fixture.clean() }
        let worker = CodexWorker(workdir: fixture.root.path, executable: fixture.executable.path)
        let log = SubmissionEvents()
        let reader = Task { for await event in worker.events { log.record(event) } }
        defer { reader.cancel() }
        let submission = UUID()
        let sending = Task {
            try await worker.start(brief: "hold", submission: submission)
            log.accepted.withLock { $0 = true }
        }

        // The fixture withholds its RPC reply until the test releases it. This completion is
        // real adapter output while start() is still suspended, not a hand-built WorkerEvent.
        for _ in 0..<250 where !log.lines.contains("turn finished: hold") {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(log.lines == ["turn previous completion", "submitted \(submission)", "turn finished: hold"])
        #expect(!log.accepted.withLock { $0 })
        try Data().write(to: fixture.release)
        try await sending.value
        #expect(log.accepted.withLock { $0 })

        // A completed notification that beat the RPC response must leave the session idle.
        // The fixture rejects turn/steer here, proving the late response did not resurrect it.
        let next = UUID()
        try await worker.steer("second", submission: next)
        for _ in 0..<250 where !log.lines.contains("turn finished: second") {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Array(log.lines.suffix(2)) == ["submitted \(next)", "turn finished: second"])
        let requests = try String(contentsOf: fixture.log, encoding: .utf8).split(separator: "\n")
        #expect(requests.filter { $0 == "turn/start" }.count == 2)
        #expect(!requests.contains("turn/steer"))
        await worker.stop()

        // steer() on a stopped session restarts it and preserves the caller's submission id.
        let resumed = UUID()
        try await worker.steer("resumed", submission: resumed)
        for _ in 0..<250 where !log.lines.contains("turn finished: resumed") {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Array(log.lines.suffix(2)) == ["submitted \(resumed)", "turn finished: resumed"])
        await worker.stop()
    }
}

private final class SubmissionEvents: Sendable {
    private let stored = Mutex<[String]>([])
    let accepted = Mutex(false)
    var lines: [String] { stored.withLock { $0 } }
    func record(_ event: WorkerEvent) {
        switch event {
        case .submitted(let id): stored.withLock { $0.append("submitted \(id)") }
        case .turnEnded(_, let text): stored.withLock { $0.append("turn \(text)") }
        default: break
        }
    }
}

private struct SubmissionFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "tilde-codex-submission-\(UUID().uuidString)")
    var executable: URL { root.appending(path: "codex") }
    var release: URL { root.appending(path: "release") }
    var log: URL { root.appending(path: "requests") }

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/fake_submission_server.py")
        try "#!/bin/sh\nexport FAKE_RELEASE='\(release.path)'\nexport FAKE_LOG='\(log.path)'\nexec /usr/bin/python3 -I '\(script.path)'\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
