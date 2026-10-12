import Darwin
import Foundation
import Testing
import TildeSupport
@testable import TildeWork

@Suite struct TerminalAgentTests {
    private func fixture() throws -> (URL, URL, TerminalAgentRegistry) {
        let root = FileManager.default.temporaryDirectory.appending(path: "tilde-hooks-\(UUID().uuidString)")
        let project = root.appending(path: "project's repo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return (root, project, TerminalAgentRegistry(home: TildeHome(root: root.appending(path: "home"))))
    }

    private func event(_ name: String, project: URL, session: String = "session_1", extras: [String: JSON] = [:]) -> Data {
        JSON.object(["session_id": .string(session), "cwd": .string(project.path), "hook_event_name": .string(name)]
            .merging(extras) { _, new in new }).line()
    }

    @Test func noRegistrationMeansNoDiscoveryOrImplicitFiles() throws {
        let (root, project, registry) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try registry.registrations().isEmpty)
        #expect(try registry.sessions().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: registry.home.root.path))
        #expect(throws: TerminalAgentError.self) {
            try registry.receive(event("Stop", project: project), registrationID: UUID())
        }
        #expect(!FileManager.default.fileExists(atPath: registry.home.root.path))
    }

    @Test(arguments: TerminalAgentAdapter.allCases)
    func registersIdempotentlyPreservingOtherSettingsAndHooks(adapter: TerminalAgentAdapter) throws {
        let (root, project, registry) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = project.appending(path: adapter.configPath)
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original: JSON = ["permissions": ["deny": ["Bash(rm)"]], "features": ["hooks": false],
            "hooks": ["SessionStart": [["matcher": "resume", "hooks": [["type": "command", "command": "existing-hook"]]]],
                      "PreToolUse": [["hooks": [["type": "command", "command": "guard"]]]]]]
        try original.line().write(to: config)
        let first = try registry.register(project: project.path, adapter: adapter, executable: "/usr/bin/true")
        let second = try registry.register(project: project.path, adapter: adapter, executable: "/usr/bin/true")
        #expect(first.id == second.id)
        #expect(try registry.registrations().count == 1)
        let merged = try #require(JSON.parse(Data(contentsOf: config)))
        #expect(merged["permissions"] == original["permissions"])
        #expect(merged["features"] == original["features"])
        #expect(merged["hooks"]?["PreToolUse"] == original["hooks"]?["PreToolUse"])
        #expect(merged["hooks"]?["SessionStart"]?.array?.count == 2)
        #expect(merged["hooks"]?["SessionStart"]?[0] == original["hooks"]?["SessionStart"]?[0])
        #expect(merged["hooks"]?["SessionStart"]?[1]?["hooks"]?[0]?["timeout"]?.int == (adapter == .gemini ? 2000 : 2))
        try registry.unregister(id: first.id)
        #expect(try JSON.parse(Data(contentsOf: config)) == original)
        #expect(try registry.registrations().isEmpty)
    }

    @Test func unregisterRemovesOnlyItsHandlerFromMixedGroups() throws {
        let (root, project, registry) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = try registry.register(project: project.path, adapter: .codex, executable: "/usr/bin/true")
        let config = URL(fileURLWithPath: registration.configPath)
        var data = try #require(JSON.parse(Data(contentsOf: config))?.object)
        var hooks = try #require(data["hooks"]?.object)
        let observer = try #require(hooks["Stop"]?[0]?["hooks"]?[0])
        hooks["Stop"] = [["matcher": "other", "hooks": [observer, ["type": "command", "command": "user-added"]]]]
        data["hooks"] = .object(hooks)
        try JSON.object(data).line().write(to: config)
        try registry.unregister(id: registration.id)
        let remaining = try #require(JSON.parse(Data(contentsOf: config)))
        #expect(remaining["hooks"]?["Stop"]?[0]?["hooks"]?.array?.count == 1)
        #expect(remaining["hooks"]?["Stop"]?[0]?["hooks"]?[0]?["command"]?.string == "user-added")
    }

    @Test func geminiAcceptsCommentedSettingsWithoutChangingTheirValues() throws {
        let (root, project, registry) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = project.appending(path: TerminalAgentAdapter.gemini.configPath)
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = #"""
            {
                // Gemini settings support comments.
                "example": "https://example.test/a/*literal*/\"//still-string",
                /* This is not a setting: "hooks": false */
                "hooks": { "SessionStart": [{"hooks": [{"type": "command", "command": "keep-me"}]}] }
            }
            """#
        try Data(original.utf8).write(to: config)
        let registration = try registry.register(project: project.path, adapter: .gemini, executable: "/usr/bin/true")
        let installed = try #require(JSON.parse(Data(contentsOf: config)))
        #expect(installed["example"]?.string == #"https://example.test/a/*literal*/"//still-string"#)
        #expect(installed["hooks"]?["SessionStart"]?.array?.count == 2)
        try registry.unregister(id: registration.id)
        let remaining = try #require(JSON.parse(Data(contentsOf: config)))
        #expect(remaining["example"] == installed["example"])
        #expect(remaining["hooks"]?["SessionStart"]?[0]?["hooks"]?[0]?["command"] == "keep-me")
        let malformed = Data("{ /* unclosed comment".utf8)
        try malformed.write(to: config)
        #expect(throws: TerminalAgentError.self) {
            try registry.register(project: project.path, adapter: .gemini, executable: "/usr/bin/true")
        }
        #expect(try Data(contentsOf: config) == malformed)
    }

    @Test func projectAndHarnessRegistrationsStayIsolated() throws {
        let (root, project, registry) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let another = root.appending(path: "another")
        try FileManager.default.createDirectory(at: another, withIntermediateDirectories: true)
        let claude = try registry.register(project: project.path, adapter: .claude, executable: "/usr/bin/true")
        let codex = try registry.register(project: project.path, adapter: .codex, executable: "/usr/bin/true")
        let other = try registry.register(project: another.path, adapter: .claude, executable: "/usr/bin/true")
        let now = Date.now
        for registration in [claude, codex, other] {
            try registry.receive(event("Stop", project: URL(fileURLWithPath: registration.project)), registrationID: registration.id, now: now)
        }
        #expect(Set(try registry.sessions(now: now).map(\.id)).count == 3)
        #expect(throws: TerminalAgentError.self) { try registry.receive(event("Stop", project: another), registrationID: claude.id) }
        try registry.unregister(id: claude.id)
        #expect(try registry.registrations().count == 2)
        #expect(try registry.sessions(now: now).count == 2)
        let updated = try registry.register(project: project.path, adapter: .codex, executable: "/usr/bin/false")
        #expect(updated.id == codex.id)
        let config = try #require(JSON.parse(Data(contentsOf: URL(fileURLWithPath: updated.configPath))))
        #expect(config["hooks"]?["Stop"]?.array?.count == 1)
        #expect(config["hooks"]?["Stop"]?[0]?["hooks"]?[0]?["command"]?.string?.contains("/usr/bin/false") == true)
    }

    @Test(arguments: TerminalAgentAdapter.allCases)
    func recordsLifecycleMetadataOnly(adapter: TerminalAgentAdapter) throws {
        let (root, project, registry) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = try registry.register(project: project.path, adapter: adapter, executable: "/usr/bin/true")
        let now = Date(timeIntervalSince1970: 12345)
        let events: [(String, TerminalAgentSession.State)] = [
            ("SessionStart", .started), (adapter == .gemini ? "BeforeAgent" : "UserPromptSubmit", .working),
            (adapter == .gemini ? "AfterAgent" : "Stop", .waiting), ("SessionEnd", .ended),
        ]
        for (name, expected) in events {
            try registry.receive(event(name, project: project, extras: ["prompt": "secret-prompt", "last_assistant_message": "secret-output",
                "transcript_path": "/must/not/open", "tool_input": ["token": "secret-token"], "timestamp": "2099-01-01T00:00:00Z"]),
                registrationID: registration.id, now: now)
            let session = try #require(registry.sessions(now: now).first)
            #expect(session.state == expected)
            #expect(session.updatedAt == now)
            #expect(session.adapter == adapter)
            #expect(try registry.sessions(now: now).count == 1)
        }
        let inbox = try String(contentsOf: registry.home.state.appending(path: "terminal-agents/inbox.json"), encoding: .utf8)
        #expect(!inbox.contains("secret"))
        #expect(!inbox.contains("transcript"))
        #expect(!inbox.contains("2099"))
        #expect(try registry.sessions(now: now.addingTimeInterval(31 * 60)).first?.isStale(now: now.addingTimeInterval(31 * 60)) == true)
        #expect(try registry.sessions(now: now.addingTimeInterval(TerminalAgentRegistry.retention + 1)).isEmpty)
        try registry.unregister(id: registration.id)
        #expect(try registry.sessions(now: now).isEmpty)
        #expect(throws: TerminalAgentError.self) { try registry.receive(event("SessionStart", project: project), registrationID: registration.id) }
    }

    @Test func rejectsMalformedForeignSubagentAndOversizedEvents() throws {
        let (root, project, registry) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = try registry.register(project: project.path, adapter: .claude, executable: "/usr/bin/true")
        let rejected = [
            Data("[]".utf8), Data("{}".utf8), Data(repeating: 65, count: 65 * 1024),
            event("Stop", project: project, session: "../escape"),
            event("Stop", project: project, session: "line\nbreak"),
            event("Stop", project: project, session: String(repeating: "x", count: 129)),
            event("Stop", project: project, extras: ["cwd": "relative"]),
            event("Stop", project: project, extras: ["session_id": 12]),
            event("Stop", project: project, extras: ["agent_id": "child"]),
            event("BeforeAgent", project: project), event("PreToolUse", project: project),
            event("Stop", project: URL(fileURLWithPath: project.path + "-other")),
        ]
        for data in rejected { #expect(throws: TerminalAgentError.self) { try registry.receive(data, registrationID: registration.id) } }
        try FileManager.default.createSymbolicLink(at: project.appending(path: "escape"), withDestinationURL: root)
        #expect(throws: TerminalAgentError.self) {
            try registry.receive(event("Stop", project: project.appending(path: "escape")), registrationID: registration.id)
        }
        #expect(try registry.sessions().isEmpty)
    }

    @Test func invalidConfigIsUnchangedAndDoesNotOptIn() throws {
        let (root, project, registry) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = project.appending(path: ".codex/hooks.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        for text in ["not JSON", "[]", "{\"hooks\":[]}", "{\"hooks\":{\"Stop\":{}}}", "{\"hooks\":{\"Stop\":[{}]}}"] {
            let original = Data(text.utf8)
            try original.write(to: config)
            #expect(throws: TerminalAgentError.self) { try registry.register(project: project.path, adapter: .codex, executable: "/usr/bin/true") }
            #expect(try Data(contentsOf: config) == original)
            #expect(try registry.registrations().isEmpty)
        }
    }

    @Test func configAndStateSymlinksAreNeverFollowed() throws {
        let (root, project, registry) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appending(path: "untouched.json")
        try Data("{}".utf8).write(to: outside)
        let directory = project.appending(path: ".claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appending(path: "settings.local.json"), withDestinationURL: outside)
        #expect(throws: TerminalAgentError.self) { try registry.register(project: project.path, adapter: .claude, executable: "/usr/bin/true") }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "{}")
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: root)
        #expect(throws: TerminalAgentError.self) { try registry.register(project: project.path, adapter: .claude, executable: "/usr/bin/true") }
        let registration = try registry.register(project: project.path, adapter: .codex, executable: "/usr/bin/true")
        let inbox = registry.home.state.appending(path: "terminal-agents/inbox.json")
        try FileManager.default.createSymbolicLink(at: inbox, withDestinationURL: outside)
        #expect(throws: TerminalAgentError.self) { try registry.receive(event("Stop", project: project), registrationID: registration.id) }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "{}")
    }

    @Test func revocationSurvivesDamagedConfiguration() throws {
        let (root, project, registry) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = try registry.register(project: project.path, adapter: .codex, executable: "/usr/bin/true")
        try Data("broken".utf8).write(to: URL(fileURLWithPath: registration.configPath))
        #expect(throws: TerminalAgentError.self) { try registry.unregister(id: registration.id) }
        #expect(try registry.registrations().isEmpty)
        #expect(throws: TerminalAgentError.self) { try registry.receive(event("Stop", project: project), registrationID: registration.id) }
    }

    @Test func refusesGlobalOptInAndQuotesShellArguments() throws {
        let (root, _, registry) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for project in [NSHomeDirectory(), "/", "relative"] {
            #expect(throws: TerminalAgentError.self) { try registry.register(project: project, adapter: .claude, executable: "/usr/bin/true") }
        }
        #expect(TerminalAgentHooks.quote("a'$(echo nope) `cmd`") == "'a'\"'\"'$(echo nope) `cmd`'")
    }
}
