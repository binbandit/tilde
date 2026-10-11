import Foundation
import Testing
import TildeSupport
import WorkerKit
@testable import ClaudeWorkers

@Suite struct ClaudeTests {
    @Test func claudeLaunchSpeaksTheControlProtocol() {
        var launch = ClaudeLaunch(cwd: "/tmp", sessionID: "abc")
        launch.hostedServers = ["tilde"]
        launch.permissionMode = "auto"
        let args = launch.arguments
        #expect(args.contains("--permission-prompt-tool") && args.contains("stdio"))
        #expect(args.contains("--session-id") && args.contains("abc"))
        let mcp = args[args.firstIndex(of: "--mcp-config")! + 1]
        #expect(JSON.parse(mcp)?["mcpServers"]?["tilde"]?["type"] == "sdk")

        launch.resume = true
        #expect(launch.arguments.contains("--resume") && !launch.arguments.contains("--session-id"))
    }

    @Test func workersAreSandboxedToTheirJob() {
        let sandbox = ClaudeSandbox.settings(writable: ["/repo/.git"])["sandbox"]
        #expect(sandbox?["enabled"] == true)
        #expect(sandbox?["filesystem"]?["allowWrite"]?.array?.first == "/repo/.git")
        // Commits land, but nothing that makes git run code can be written.
        let denied = sandbox?["filesystem"]?["denyWrite"]?.array?.compactMap(\.string) ?? []
        #expect(denied.contains("/repo/.git/config") && denied.contains("/repo/.git/hooks"))
        #expect(sandbox?["network"]?["allowedDomains"]?.array?.contains("registry.npmjs.org") == true)
        #expect(ClaudeSandbox.newHosts(["command": "curl x", "allowed_domains": ["example.com"]]) == ["example.com"])
        #expect(ClaudeSandbox.newHosts(["command": "swift test"]) == nil)
    }

    @Test func askUserQuestionAnswersMatchOptionLabels() {
        let input: JSON = ["questions": [["question": "Sticky?", "header": "Nav", "options": [["label": "Sticky"], ["label": "Scroll away"]]]]]
        let questions = [WorkerQuestion(question: "Sticky?", options: ["Sticky", "Scroll away"], multiSelect: false)]
        let answered = ClaudeWorker.answering(input, questions: questions, with: "sticky")
        #expect(answered["answers"]?["Sticky?"] == "Sticky")
        #expect(answered["questions"] != nil)
        let free = ClaudeWorker.answering(input, questions: questions, with: "Only on mobile")
        #expect(free["answers"]?["Sticky?"] == "Only on mobile")
    }
}

@Suite struct ClaudeSessionTests {
    /// Stands in for `claude` with the fixture script.
    private func fakeClaude() throws -> String {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/fake_claude.py").path
        let path = FileManager.default.temporaryDirectory.appending(path: "fake-claude-\(UUID().uuidString)").path
        try "#!/bin/sh\nexec /usr/bin/python3 -I '\(fixture)'\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private struct NoHost: ClaudeHost {
        func canUseTool(_ request: ClaudePermissionRequest) async -> ClaudePermissionDecision { .deny("No.") }
    }

    @Test func aTurnEndsOnItsOwnResultNotAStartupCommands() async throws {
        var launch = ClaudeLaunch(cwd: FileManager.default.temporaryDirectory.path)
        launch.executable = try fakeClaude()
        let session = ClaudeSession(launch, host: NoHost())
        try await session.start()
        try await session.send("Add a CONTRIBUTING.md")

        var said: [String] = []
        for await event in session.events {
            switch event {
            case .text(let text): said.append(text)
            case .turnDone(let turn):
                #expect(turn.text == "done")
                #expect(said == ["done"])
                await session.stop()
                return
            default: continue
            }
        }
        Issue.record("The session ended without finishing the turn")
    }
}

@Suite struct ClaudeWorkerQueueTests {
    /// What you send mid-turn runs as a turn of its own; the job's turn ends when that one has.
    @Test(.timeLimit(.minutes(1))) func aTurnEndsAfterEverythingSentToIt() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/fake_claude_queue.py").path
        let claude = FileManager.default.temporaryDirectory.appending(path: "fake-claude-queue-\(UUID().uuidString)").path
        try "#!/bin/sh\nexec /usr/bin/python3 -I '\(fixture)'\n".write(toFile: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude)
        let worker = ClaudeWorker(workdir: FileManager.default.temporaryDirectory.path, sessionID: UUID().uuidString.lowercased(), executable: claude)
        try await worker.start(brief: "add the nav")
        try await worker.steer("and make it sticky")

        var ended: [String] = []
        for await event in worker.events {
            if case .turnEnded(_, let text) = event {
                ended.append(text)
                break
            }
        }
        #expect(ended == ["did: and make it sticky"])
        await worker.stop()
    }
}
