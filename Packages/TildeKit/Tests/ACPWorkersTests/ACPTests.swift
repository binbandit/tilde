import Foundation
import Testing
import TildeSupport
import WorkerKit
@testable import ACPWorkers

@Suite(.timeLimit(.minutes(1))) struct ACPTests {
    // MARK: Against the scripted agent (Fixtures/fake_agent.py)

    @Test func streamsTickersMessagesAndOneTurn() async throws {
        let agent = try FakeAgent()
        let worker = agent.worker()
        var events = EventLines(worker)
        try await worker.start(brief: "work")
        #expect(await events.untilTurnEnds() == [
            "session sess-1", "activity Thinking", "message Let me build it.", "activity Running a command",
            "activity Running swift build", "activity Write the summary", "message Built.", "turn ok Built.",
        ])
        // A new session gets the supervision brief ahead of the task.
        #expect(agent.prompts == ["<instructions from=\"tilde\">\nBe careful.\n</instructions>\n\nwork"])
        let hello = agent.log.first { $0["method"] == "initialize" }?["params"]
        #expect(hello?["protocolVersion"] == 1 && hello?["clientCapabilities"]?["fs"]?["writeTextFile"] == true)
        #expect(agent.log.first { $0["method"] == "session/new" }?["params"]?["mcpServers"] == [])
        await worker.stop()
    }

    @Test func railsReachTheManagerAndEverythingElseGoesAhead() async throws {
        let agent = try FakeAgent()
        let worker = agent.worker()
        var events = EventLines(worker)
        try await worker.start(brief: "permissions")
        // `swift test` goes ahead without asking; the push and the outside edit don't.
        let push = await events.nextRequest()
        #expect(push.line == "Shell: git push origin main [Pushes to a remote]")
        await worker.resolve(push.id, .allow)
        let edit = await events.nextRequest()
        #expect(edit.headline == "Edit: \(agent.outside)")
        #expect(edit.rail?.hasPrefix("Writes outside the job's worktree") == true)
        await worker.resolve(edit.id, .deny("Stay in the worktree."))
        #expect(await events.untilTurnEnds().last == "turn ok outcomes: allow, allow, reject")
        // Only ever once: tilde never grants a standing permission.
        let picked = agent.log.compactMap { $0["result"]?["outcome"]?["optionId"]?.string }
        #expect(picked == ["allow", "allow", "reject"])
        await worker.stop()
    }

    @Test func aSilentTurnSaysWhatWasDeclined() async throws {
        let agent = try FakeAgent()
        let worker = agent.worker()
        var events = EventLines(worker)
        try await worker.start(brief: "silent")
        await worker.resolve(await events.nextRequest().id, .deny("No."))
        #expect(await events.untilTurnEnds().last
            == "turn ok Fake ended the turn without a reply after tilde declined: Shell: git push origin main")
        await worker.stop()
    }

    @Test func fileWritesOutsideTheWorktreeNeedApproval() async throws {
        let agent = try FakeAgent()
        let worker = agent.worker()
        var events = EventLines(worker)
        try await worker.start(brief: "files")
        let write = await events.nextRequest()
        #expect(write.headline == "Write: \(agent.outside)" && write.rail != nil)
        await worker.resolve(write.id, .deny("No."))
        #expect(await events.untilTurnEnds().last == "turn ok inside ok; read two; outside refused")
        #expect(try String(contentsOfFile: agent.workdir + "/notes/inside.txt", encoding: .utf8) == "one\ntwo\nthree\n")
        #expect(!FileManager.default.fileExists(atPath: agent.outside))
        await worker.stop()
    }

    @Test func formElicitationsBecomeQuestions() async throws {
        let agent = try FakeAgent()
        let worker = agent.worker()
        var events = EventLines(worker)
        try await worker.start(brief: "question")
        let request = await events.nextRequest()
        guard case .question(let questions) = request.kind else { Issue.record("expected a question"); return }
        #expect(questions == [WorkerQuestion(question: "How should the nav behave?", options: ["Sticky", "Scroll away"], multiSelect: false)])
        await worker.resolve(request.id, .reply("Scroll away"))
        #expect(await events.untilTurnEnds().last == "turn ok nav: scroll")
        await worker.stop()
    }

    @Test func steersMidTurnRunNextAndReportOneTurn() async throws {
        let agent = try FakeAgent()
        let worker = agent.worker()
        var events = EventLines(worker)
        try await worker.start(brief: "hold")
        let hold = await events.nextRequest()
        try await worker.steer("follow up")
        await worker.resolve(hold.id, .allow)
        #expect(await events.untilTurnEnds() == ["message held", "message echo: follow up", "turn ok echo: follow up"])
        // Once idle, a steer is simply the next prompt.
        try await worker.steer("again")
        #expect(await events.untilTurnEnds() == ["message echo: again", "turn ok echo: again"])
        #expect(agent.prompts.dropFirst() == ["follow up", "again"])
        await worker.stop()
    }

    @Test func stopCancelsPendingRequestsThenEndsTheProcess() async throws {
        let agent = try FakeAgent()
        let worker = agent.worker()
        var events = EventLines(worker)
        try await worker.start(brief: "hang")
        _ = await events.nextRequest()
        await worker.stop()
        let rest = await events.until { if case .exited = $0 { true } else { false } }
        #expect(rest.last == "exited cleanly" && !rest.contains { $0.hasPrefix("turn") })
        let log = agent.log
        let cancel = log.firstIndex { $0["method"] == "session/cancel" }
        let cancelled = log.firstIndex { $0["result"]?["outcome"]?["outcome"] == "cancelled" }
        #expect(cancel != nil && cancelled != nil && cancel! < cancelled!)
    }

    @Test func resumeLoadsQuietlyAndPicksTheModel() async throws {
        let agent = try FakeAgent(load: true)
        let worker = agent.worker(resume: "old-1", model: "Smart")
        var events = EventLines(worker)
        try await worker.start(brief: "work")
        let seen = await events.untilTurnEnds()
        #expect(seen.first == "session old-1" && !seen.contains("message old news"))
        #expect(agent.log.first { $0["method"] == "session/load" }?["params"]?["sessionId"] == "old-1")
        #expect(agent.log.first { $0["method"] == "session/set_config_option" }?["params"]?["value"] == "smart")
        // The resumed session already has the brief.
        #expect(agent.prompts == ["work"])
        await worker.stop()
    }

    @Test func aSessionThatCantBeReopenedStartsFresh() async throws {
        let agent = try FakeAgent(load: true)
        let worker = agent.worker(resume: "gone")
        var events = EventLines(worker)
        try await worker.start(brief: "work")
        let seen = await events.untilTurnEnds()
        #expect(seen.prefix(2) == ["notice Couldn't reopen Fake session gone (no such session), so this is a fresh one", "session sess-1"])
        #expect(agent.prompts.first?.hasPrefix("<instructions") == true)
        await worker.stop()
    }

    // MARK: Pure mapping

    @Test func toolCallsAreTriagedByRails() {
        let workdir = "/tmp/tilde-acp/work"
        func verdict(_ update: JSON) -> ACPToolCall.Verdict { ACPToolCall(update).verdict(workdir: workdir) }
        #expect(verdict(["kind": "execute", "rawInput": ["command": "swift build"]]) == .allow)
        #expect(verdict(["kind": "execute", "rawInput": ["command": "git push"]]) == .ask(rail: "Pushes to a remote"))
        #expect(verdict(["kind": "execute", "title": "bash"]) == .ask(rail: nil))
        #expect(verdict(["kind": "execute", "title": "npm publish --access public"]) == .ask(rail: "Publishes a package"))
        #expect(verdict(["kind": "execute", "rawInput": ["command": "make", "cwd": "/tmp/tilde-acp/other"]])
            == .ask(rail: "Runs outside the job's worktree (/tmp/tilde-acp/other)"))
        #expect(verdict(["kind": "edit", "locations": [["path": "/tmp/tilde-acp/work/a.swift"]]]) == .allow)
        #expect(verdict(["kind": "edit", "rawInput": ["filePath": "Sources/a.swift"]]) == .allow)
        #expect(verdict(["kind": "edit", "content": [["type": "diff", "path": "/tmp/tilde-acp/b.swift", "newText": ""]]])
            == .ask(rail: "Writes outside the job's worktree (/tmp/tilde-acp/b.swift)"))
        #expect(verdict(["kind": "edit", "title": "edit"]) == .ask(rail: nil))
        #expect(verdict(["kind": "read", "locations": [["path": "/etc/hosts"]]]) == .allow)
        #expect(verdict(["kind": "other", "title": "github: create_pull_request"]) == .ask(rail: nil))
    }

    @Test func toolCallsDescribeThemselves() {
        var call = ACPToolCall(["kind": "edit", "title": "edit", "status": "pending", "rawInput": [:]])
        #expect(call.activity == "Editing files" && call.tool == "Edit")
        call.merge(["status": "in_progress", "rawInput": ["filePath": "/w/Nav.swift"]])
        #expect(call.activity == "Editing Nav.swift" && call.action == "/w/Nav.swift")
        call.merge(["rawInput": [:]])  // an empty update doesn't erase what we know
        #expect(call.action == "/w/Nav.swift")
        #expect(ACPToolCall(["kind": "fetch", "rawInput": ["url": "https://docs.swift.org/x"]]).activity == "Reading docs.swift.org")
    }

    @Test func formRepliesAreTypedPerField() {
        let form = ACPForm(["message": "Settings?", "requestedSchema": ["type": "object", "required": ["retries"], "properties": [
            "retries": ["type": "integer", "title": "Retries"],
            "dark": ["type": "boolean", "title": "Dark mode"],
            "targets": ["type": "array", "items": ["enum": ["ios", "macos"]]],
        ]]])
        #expect(form.questions.map(\.question) == ["Settings?\nRetries", "Settings?\nDark mode", "Settings?\ntargets"])
        #expect(form.questions[2].multiSelect && form.questions[2].options == ["ios", "macos"])
        #expect(form.content("3")["retries"] == 3)
        #expect(form.content("yes")["dark"] == true)
        #expect(form.content("iOS, macOS")["targets"] == ["ios", "macos"])
    }
}

/// `TILDE_REAL_ACP=1 swift test --filter ACP` runs the real OpenCode on a throwaway
/// repo (TILDE_REAL_ACP_MODEL picks the model; OpenCode's default otherwise).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TILDE_REAL_ACP"] == "1"), .timeLimit(.minutes(5)))
struct ACPRealTests {
    let spec = ACPHarnesses.specs.first { $0.id == Harness(rawValue: "opencode") }!

    @Test func openCodeCommitsAFileAndResumes() async throws {
        let launch = try await Self.launch()
        let worker = spec.make(launch)
        var events = EventLines(worker)
        try await worker.start(brief: "Create a file named hello.txt containing exactly the word hi, then commit it with the message 'Add hello'. Do nothing else.")
        let seen = await events.untilTurnEnds(denyingRequests: true)
        print(seen.joined(separator: "\n"))
        #expect(seen.last?.hasPrefix("turn ok") == true)
        #expect(try await Shell.check(["git", "log", "--format=%s"], cwd: launch.workdir).contains("Add hello"))
        let session = try #require(seen.first { $0.hasPrefix("session ") }.map { String($0.dropFirst(8)) })
        await worker.stop()

        // A new process picks the same session back up.
        var resumed = launch
        resumed.sessionID = session
        resumed.resume = true
        let again = spec.make(resumed)
        var more = EventLines(again)
        try await again.start(brief: "What is the name of the file you created? Reply with just the file name.")
        let answer = await more.untilTurnEnds(denyingRequests: true)
        print(answer.joined(separator: "\n"))
        #expect(answer.first == "session \(session)")
        #expect(answer.last?.contains("hello.txt") == true)
        await again.stop()
    }

    @Test func openCodeAsksBeforeAPush() async throws {
        let launch = try await Self.launch()
        // A local bare remote: even a push that got through would stay on this Mac.
        let remote = launch.workdir + "-remote.git"
        try await Shell.check(["git", "init", "-q", "--bare", remote])
        try await Shell.check(["git", "remote", "add", "origin", remote], cwd: launch.workdir)
        let worker = spec.make(launch)
        var events = EventLines(worker)
        try await worker.start(brief: "Run exactly this shell command and nothing else: git push origin HEAD. Then say in one sentence what happened.")
        let push = await events.nextRequest()
        print(push.line)
        #expect(push.headline.hasPrefix("Shell: git push") && push.rail == "Pushes to a remote")
        await worker.resolve(push.id, .deny("Not now."))
        let rest = await events.untilTurnEnds(denyingRequests: true)
        print(rest.joined(separator: "\n"))
        #expect(rest.last?.hasPrefix("turn") == true)
        #expect(try await Shell.check(["git", "for-each-ref"], cwd: remote).isEmpty)
        await worker.stop()
    }

    /// A throwaway repo with one commit.
    static func launch() async throws -> WorkerLaunch {
        let repo = FileManager.default.temporaryDirectory.appending(path: "tilde-acp-real-\(UUID().uuidString.prefix(8))").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        for command in [["git", "init", "-q"], ["git", "config", "user.email", "tilde@example.com"], ["git", "config", "user.name", "tilde"],
                        ["git", "commit", "-q", "--allow-empty", "-m", "Start"]] {
            try await Shell.check(command, cwd: repo)
        }
        return WorkerLaunch(
            workdir: repo, model: ProcessInfo.processInfo.environment["TILDE_REAL_ACP_MODEL"],
            instructions: Supervision.brief(owner: "Tester"))
    }
}

/// A throwaway worktree, and workers on the scripted agent, which logs everything tilde sends it.
private struct FakeAgent {
    static let script = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/fake_agent.py").path
    let workdir: String
    let outside: String
    let logPath: String
    let load: Bool

    init(load: Bool = false) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "tilde-acp-\(UUID().uuidString.prefix(8))")
        workdir = root.appending(path: "work").path
        outside = root.appending(path: "outside.txt").path
        logPath = root.appending(path: "agent.log").path
        self.load = load
        try FileManager.default.createDirectory(atPath: workdir, withIntermediateDirectories: true)
    }

    func worker(resume: String? = nil, model: String? = nil) -> ACPWorker {
        var environment = ["PATH": "/usr/bin:/bin", "FAKE_LOG": logPath]
        if load { environment["FAKE_LOAD"] = "1" }
        return ACPWorker(
            ACPCommand(label: "Fake", executable: "/usr/bin/python3", arguments: ["-I", Self.script], environment: environment),
            launch: WorkerLaunch(workdir: workdir, sessionID: resume, resume: resume != nil, model: model, instructions: "Be careful."))
    }

    /// Every message tilde sent the agent, in order.
    var log: [JSON] {
        ((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { JSON.parse(String($0)) }
    }

    var prompts: [String] {
        log.filter { $0["method"] == "session/prompt" }.compactMap { $0["params"]?["prompt"]?[0]?["text"]?.string }
    }
}

/// A worker's events as readable lines.
private struct EventLines {
    let worker: any Worker
    var iterator: AsyncStream<WorkerEvent>.Iterator

    init(_ worker: any Worker) {
        self.worker = worker
        iterator = worker.events.makeAsyncIterator()
    }

    mutating func until(_ done: (WorkerEvent) -> Bool) async -> [String] {
        var lines: [String] = []
        while let event = await iterator.next() {
            lines.append(event.line)
            if done(event) { break }
        }
        return lines
    }

    /// Events up to the end of the turn. A real agent's unexpected requests are denied and logged.
    mutating func untilTurnEnds(denyingRequests: Bool = false) async -> [String] {
        var lines: [String] = []
        while let event = await iterator.next() {
            lines.append(event.line)
            if case .turnEnded = event { break }
            if denyingRequests, case .request(let request) = event {
                Issue.record("Unexpected request: \(event.line)")
                await worker.resolve(request.id, .deny("Not in this test."))
            }
            if case .exited = event { break }
        }
        return lines
    }

    mutating func nextRequest() async -> WorkerRequest {
        while let event = await iterator.next() {
            if case .request(let request) = event { return request }
        }
        fatalError("The worker's events ended before a request")
    }
}

extension WorkerEvent {
    fileprivate var line: String {
        switch self {
        case .session(let id): "session \(id)"
        case .activity(let text): "activity \(text)"
        case .message(let text): "message \(text)"
        case .request(let request): "request \(request.line)"
        case .turnEnded(let ok, let text): "turn \(ok ? "ok" : "failed") \(text)"
        case .notice(let text): "notice \(text)"
        case .exited(let detail): "exited \(detail ?? "cleanly")"
        }
    }
}

extension WorkerRequest {
    fileprivate var rail: String? {
        if case .permission(_, _, let rail) = kind { rail } else { nil }
    }

    fileprivate var line: String { headline + (rail.map { " [\($0)]" } ?? "") }
}
