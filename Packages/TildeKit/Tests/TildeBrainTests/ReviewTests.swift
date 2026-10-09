import Foundation
import Testing
import TildeMemory
import TildeSupport
import TildeWork
@testable import TildeBrain

@Suite struct ReviewTests {
    @Test func turnsTheModelsJSONIntoAtMostThreeNotices() {
        let reply = """
            {"notices": [
              {"key": "Sam pricing call", "urgency": "now", "summary": "Sam commented on paradise#12 an hour ago; your 3pm with Sam is about pricing.",
               "suggestion": "draft a reply to Sam", "url": "https://github.com/acme/paradise/pull/12", "project": "~/Developer/paradise"},
              {"key": "empty", "urgency": "fyi", "summary": "  ", "suggestion": null, "url": null, "project": null},
              {"key": "docs", "urgency": "soon", "summary": "The docs goal has no job running.", "suggestion": " ",
               "url": "linear://issue/42", "project": "relative/path"},
              {"key": "third", "urgency": "fyi", "summary": "Third.", "suggestion": null, "url": null, "project": null},
              {"key": "fourth", "urgency": "fyi", "summary": "Fourth.", "suggestion": null, "url": null, "project": null}
            ]}
            """
        let notices = Review.notices(from: reply)
        #expect(notices.map(\.summary) == [
            "Sam commented on paradise#12 an hour ago; your 3pm with Sam is about pricing.", "The docs goal has no job running.", "Third.",
        ])

        let first = notices[0]
        #expect(first.key == "review:sam-pricing-call" && first.urgency == .now)
        #expect(first.subject == "acme/paradise#12")  // shares the PR watcher's cooldown
        #expect(first.project == "\(NSHomeDirectory())/Developer/paradise" && first.suggestion == "draft a reply to Sam")

        let second = notices[1]
        #expect(second.subject == "review:docs" && second.urgency == .soon)
        #expect(second.url == nil && second.project == nil && second.suggestion == nil)

        #expect(Review.notices(from: #"{"notices": []}"#).isEmpty)
        #expect(Review.notices(from: "Here are some thoughts").isEmpty)
        #expect(Review.notices(from: nil).isEmpty)
    }

    @Test func thePromptCarriesEverySourceAndWhatWasAlreadySaid() {
        var inputs = Review.Inputs(now: TestTime.at("2026-10-09 09:00"))
        inputs.goals = "- Ship checkout [active]"
        inputs.thread = "08:55 tilde: Your nav bar job is ready."
        let prompt = Review.prompt(inputs)
        #expect(prompt.contains("<goals>\n- Ship checkout [active]\n</goals>"))
        #expect(prompt.contains("<said-today>\n08:55 tilde: Your nav bar job is ready.\n</said-today>"))
        #expect(prompt.contains("<schedule>\n(nothing)\n</schedule>"))
        #expect(!Review.instructions(owner: "Brayden").contains("\u{2014}"))
    }

    // MARK: Read-only connectors

    @Test func onlyToolsThatReadLikeReadsAreAllowed() {
        for tool in [
            "list_issues", "get_issue", "search_documentation", "fetch", "read_file", "query_database", "view_page", "getIssue",
            "List issues", "get-diff", "get_commit", "list_comments", "get_workflow_run", "get_app_state",
        ] {
            #expect(ReadOnlyTools.allows(tool), "\(tool)")
        }
        for tool in [
            "save_issue", "create_comment", "delete_event", "update_project", "send_message", "merge_diff", "mark_notification",
            "get_or_create_label", "list_and_archive", "fetchAndUpdate", "click", "js", "extract_images", "mcp__linear__list_issues", "",
        ] {
            #expect(!ReadOnlyTools.allows(tool), "\(tool)")
        }
    }

    @Test func everyConnectorAndPreApprovedToolIsFenced() {
        let config: JSON = [
            "mcp_servers": [
                "linear": ["enabled": false, "tools": ["save_issue": ["approval_mode": "approve"], "save_comment": ["approval_mode": "approve"]]],
                "computer-use": ["enabled": true],
            ],
            "apps": ["github": ["enabled": true]],
        ]
        #expect(ReadOnlyTools.fence(config) == [
            "mcp_servers.linear.default_tools_approval_mode": "writes",
            "mcp_servers.linear.tools.save_issue.approval_mode": "writes",
            "mcp_servers.linear.tools.save_comment.approval_mode": "writes",
            "mcp_servers.computer-use.default_tools_approval_mode": "writes",
            "apps.github.default_tools_approval_mode": "writes",
            "apps.github.destructive_enabled": false,
        ])
        #expect(ReadOnlyTools.fence([:]) == [:])
        // A name that can't be a dotted key can't be fenced: the review goes without connectors.
        #expect(ReadOnlyTools.fence(["mcp_servers": ["my server": [:]]]) == nil)
        #expect(ReadOnlyTools.fence(["mcp_servers": ["ok": ["tools": ["weird.tool": [:]]]]]) == nil)
    }

    // MARK: Running it

    @Test func runsOneReviewAtATimeAndPacesItself() async throws {
        let home = TildeHome(root: FileManager.default.temporaryDirectory.appending(path: "tilde-review-\(UUID().uuidString)"))
        try home.prepare()
        let gate = Gate()
        let reply = #"{"notices": [{"key": "k", "urgency": "soon", "summary": "S.", "suggestion": null, "url": null, "project": null}]}"#
        let initiative = Initiative(home: home, projects: ProjectIndex(roots: []), review: GatedModel(gate: gate, reply: reply))
        #expect(await initiative.reviewDue())

        let first = Task { await initiative.review(Review.Inputs()) }
        while !(await initiative.reviewing) { await Task.yield() }
        #expect(await initiative.review(Review.Inputs()) == nil)
        #expect(!(await initiative.reviewDue()))

        await gate.open()
        #expect(await first.value?.map(\.key) == ["review:k"])
        #expect(!(await initiative.reviewDue()))
        #expect(await initiative.reviewDue(now: .now.addingTimeInterval(91 * 60)))
    }

    @Test func whatTheReviewFindsGoesThroughTheDeliveryPolicy() async throws {
        let home = TildeHome(root: FileManager.default.temporaryDirectory.appending(path: "tilde-review-\(UUID().uuidString)"))
        try home.prepare()
        let reply = #"{"notices": [{"key": "k", "urgency": "fyi", "summary": "S.", "suggestion": null, "url": null, "project": null}]}"#
        let initiative = Initiative(home: home, projects: ProjectIndex(roots: []), review: CannedModel(reply: reply))
        let found = try #require(await initiative.review(Review.Inputs()))
        #expect(await initiative.due(found, typing: false, looking: false).isEmpty)  // fyi waits for a look
        #expect(await initiative.due([], typing: false, looking: true).map(\.key) == ["review:k"])
        #expect(await initiative.due(found, typing: false, looking: true).isEmpty)  // and is said once
    }
}

/// Holds a model's reply until the test lets it go.
actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

struct GatedModel: MemoryModel {
    let gate: Gate
    let reply: String
    func run(_ pass: ModelPass) async throws -> ModelReply {
        await gate.wait()
        return ModelReply(ok: true, text: reply)
    }
}

/// Opt-in: `TILDE_REAL_REVIEW=1 swift test --filter ReviewRealTests` runs the review's Codex thread
/// for real, against a fake MCP server (never your connectors), and checks that only reads ran,
/// even a write tool that config pre-approves.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TILDE_REAL_REVIEW"] == "1"))
struct ReviewRealTests {
    @Test(.timeLimit(.minutes(5))) func onlyReadingToolsRunEvenWhenAWriteIsPreApproved() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "tilde-review-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let calls = dir.appending(path: "calls.log").path
        let server = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/fake_mcp.py").path
        let model = CodexReviewModel(effort: "low", overrides: [
            #"mcp_servers={fake={command="python3",args=["\#(server)"],env={FAKE_MCP_LOG="\#(calls)"},tools={save_note={approval_mode="approve"}}}}"#,
        ])
        let reply = try await model.run(ModelPass(
            instructions: "You are checking which tools work. Don't run shell commands.",
            prompt: "Call each of the fake MCP server's tools exactly once, in order: list_notes, get_note (id 'a'), create_note "
                + "(text 'x'), save_note (text 'y'). Then reply with one line per tool saying whether it worked.",
            workdir: dir.path))
        #expect(reply.ok, "\(reply.text ?? "")")
        let ran = Set(((try? String(contentsOfFile: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
        #expect(ran == ["list_notes", "get_note"])
    }
}
