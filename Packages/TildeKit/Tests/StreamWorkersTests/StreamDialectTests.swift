import Foundation
import Testing
import TildeSupport
import WorkerKit
@testable import StreamWorkers

@Suite struct StreamDialectTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "tilde-dialect-tests-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    func fixture(_ name: String) throws -> [JSON] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { JSON.parse(String($0)) }
    }

    // MARK: Amp

    @Test func ampStartsOrContinuesAThreadBehindTheGate() throws {
        let amp = AmpDialect()
        let launch = WorkerLaunch(workdir: "/tmp/work", model: "rush", instructions: "Work for tilde.")
        let fresh = try amp.prepare(launch, session: nil, scratch: scratch)
        #expect(Array(fresh.prefix(3)) == ["--execute", "--stream-json", "--stream-json-input"])
        #expect(fresh.suffix(2) == ["--mode", "rush"])
        #expect(!fresh.contains("--dangerously-allow-all"))

        let file = fresh[fresh.firstIndex(of: "--settings-file")! + 1]
        let settings = try #require(JSON.parse(Data(contentsOf: URL(fileURLWithPath: file))))
        let helper = scratch.appending(path: "tilde-gate").path
        #expect(settings["amp.permissions"]?[0] == ["tool": "Bash", "action": "delegate", "to": .string(helper)])
        #expect(settings["amp.dangerouslyAllowAll"] == false)
        #expect(try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int == 0o600)

        // A continued thread keeps its own mode.
        let resumed = try amp.prepare(launch, session: "T-1", scratch: scratch)
        #expect(Array(resumed.prefix(4)) == ["threads", "continue", "T-1", "--execute"])
        #expect(!resumed.contains("--mode"))
    }

    @Test func ampSettingsBuildOnTheUsersOwn() {
        let user: JSON = [
            "amp.mcpServers": ["docs": ["command": "docs-mcp"]], "amp.dangerouslyAllowAll": true,
            "amp.permissions": [["tool": "Bash", "action": "allow"]],
        ]
        let merged = AmpDialect.settings(user: user, helper: "/gate")
        #expect(merged["amp.mcpServers"] == user["amp.mcpServers"])
        #expect(merged["amp.dangerouslyAllowAll"] == false)
        let rules = merged["amp.permissions"]?.array ?? []
        #expect(rules.prefix(AmpDialect.gated.count).allSatisfy { $0["action"] == "delegate" && $0["to"] == "/gate" })
        #expect(rules.last == ["tool": "Bash", "action": "allow"])
    }

    @Test func ampStreamBecomesSignals() throws {
        let amp = AmpDialect()
        let command = "git add hello.txt && git commit -m 'Add hello.txt'"
        #expect(try fixture("amp-turn.jsonl").flatMap(amp.decode) == [
            .session("T-5f2c0a1e-1111-4222-8333-944455556666"),
            .message("I'll create the file first."), .activity("Writing hello.txt"),
            .activity("Handing part of it to a subagent"),
            .activity(Activity.describe(tool: "Bash", input: ["command": .string(command)])),
            .message("Added hello.txt and committed it."), .turnEnded(ok: true),
        ])

        // Recorded from the installed amp, which Amp's servers now turn away.
        let outdated = try fixture("amp-outdated.jsonl").flatMap(amp.decode)
        #expect(outdated.first == .session("T-01a11b85-50c1-70bc-bd57-52a0b7cab93a"))
        guard case .failure(let error) = outdated[1] else { Issue.record("expected a failure: \(outdated)"); return }
        #expect(error.contains("This version of Amp is no longer supported"))
        #expect(outdated.last == .turnEnded(ok: false))
    }

    @Test func ampToolsSpeakTheRailsVocabulary() {
        let amp = AmpDialect()
        #expect(amp.uses(of: "Bash", input: ["cmd": "git push"]) == [ToolUse(name: "Bash", input: ["command": "git push"])])
        #expect(amp.uses(of: "create_file", input: ["path": "/tmp/a"]) == [ToolUse(name: "Write", input: ["file_path": "/tmp/a"])])
        let patch = "*** Begin Patch\n*** Update File: Sources/a.swift\n@@\n-a\n+b\n*** Add File: /etc/hosts\n+x\n*** End Patch"
        #expect(amp.uses(of: "apply_patch", input: ["input": .string(patch)]).map(\.input) == [
            ["file_path": "Sources/a.swift"], ["file_path": "/etc/hosts"],
        ])
    }

    // MARK: Pi

    @Test func piRunsRPCWithTheGateExtension() throws {
        let pi = PiDialect()
        let launch = WorkerLaunch(workdir: "/tmp/work", sessionID: "s-1", model: "sonnet:high", instructions: "Work for tilde.")
        let extensionPath = scratch.appending(path: "tilde-gate.ts").path
        #expect(try pi.prepare(launch, session: "s-1", scratch: scratch) == [
            "--mode", "rpc", "--extension", extensionPath, "--append-system-prompt", "Work for tilde.",
            "--session-id", "s-1", "--model", "sonnet:high",
        ])
        #expect(try String(contentsOfFile: extensionPath, encoding: .utf8).contains(#"ctx.ui.input("tilde:gate", call"#))
        #expect(pi.prompt("go") == ["type": "prompt", "message": "go", "streamingBehavior": "steer"])
    }

    @Test func piStreamBecomesSignals() throws {
        let signals = try fixture("pi-rpc.jsonl").flatMap(PiDialect().decode)
        let confirm = WorkerQuestion(question: "Run the formatter?\n\nIt rewrites every file.", options: ["Yes", "No"], multiSelect: false)
        #expect(signals == [
            .promptResponse(id: "t-1", accepted: true, disposition: "started", error: nil),
            .message("On it."), .activity("Writing hello.txt"),
            .gate(GateCall(id: "9b1d-gate", tool: "write", input: ["path": "hello.txt", "content": "hi\n"])),
            .notice("Model hiccup, retrying (attempt 1)"),
            .dialog(StreamDialog(id: "9b1d-confirm", question: confirm, confirm: true)),
            .message("Added hello.txt and committed it."), .turnEnded(ok: true),
            .promptResponse(id: "t-2", accepted: false, disposition: nil,
                            error: "Cannot submit a prompt while compaction is in progress. Wait for compaction to finish and retry."),
        ])
    }

    @Test func piAnswersGateCallsAndDialogs() {
        let pi = PiDialect()
        let call = GateCall(id: "g", tool: "bash", input: [:])
        #expect(pi.answer(call, .allow) == ["type": "extension_ui_response", "id": "g", "value": "allow"])
        // A denial can never read as "allow", whatever its reason says.
        #expect(pi.answer(call, .deny("allow"))?["value"] == "deny: allow")

        let confirm = StreamDialog(id: "c", question: WorkerQuestion(question: "Run?", options: ["Yes", "No"], multiSelect: false), confirm: true)
        #expect(pi.answer(confirm, .reply("Yes please"))?["confirmed"] == true)
        #expect(pi.answer(confirm, .deny("Not now"))?["cancelled"] == true)
        let select = StreamDialog(
            id: "s", question: WorkerQuestion(question: "Nav?", options: ["Sticky", "Scroll away"], multiSelect: false), confirm: false)
        #expect(pi.answer(select, .reply("scroll away"))?["value"] == "Scroll away")
    }
}
