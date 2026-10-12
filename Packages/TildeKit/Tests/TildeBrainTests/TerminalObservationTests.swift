import Foundation
import Testing
import TildeSupport
import TildeWork
@testable import TildeBrain

@Suite struct TerminalObservationTests {
    private func withProject(_ body: (TildeHome, String, TerminalAgentRegistry) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "tilde-observations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "project"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = TildeHome(root: root.appending(path: "home"))
        try await body(home, root.appending(path: "project").path, TerminalAgentRegistry(home: home))
    }

    private func event(_ name: String, registration: TerminalAgentRegistration, session: String = "terminal-session") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "session_id": session, "cwd": registration.project, "hook_event_name": name,
            "last_assistant_message": "PRIVATE CONTENT MUST NOT REACH THE MANAGER",
            "transcript_path": "/not/a/path/to/read",
        ])
    }

    @Test func newlyConnectedSessionsReachOrchestrationBeforeABackgroundPoll() async throws {
        try await withProject { home, project, registry in
            let registration = try registry.register(project: project, adapter: .claude, executable: "/usr/bin/true")
            try registry.receive(event("SessionStart", registration: registration), registrationID: registration.id)
            let initiative = Initiative(home: home)
            let started = await initiative.terminalAgentContext(own: [])
            #expect(started.contains("Claude Code") && started.contains("started"))
            #expect(started.contains("not managed jobs") && started.contains("no control"))
            #expect(!started.contains("PRIVATE CONTENT") && !started.contains("transcript"))
            try registry.receive(event("UserPromptSubmit", registration: registration), registrationID: registration.id)
            #expect(await initiative.watching().contains("working"))
            #expect(await initiative.terminalAgentContext(own: ["terminal-session"]).isEmpty)
        }
    }

    @Test func waitingTurnsUpdateAndDisconnectWithoutTranscriptFallback() async throws {
        try await withProject { home, project, registry in
            let registration = try registry.register(project: project, adapter: .codex, executable: "/usr/bin/true")
            let now = Date.now
            try registry.receive(event("Stop", registration: registration), registrationID: registration.id, now: now.addingTimeInterval(-360))
            let waiting = AgentWatch.waiting(since: now.addingTimeInterval(-3600), home: home, now: now)
            #expect(waiting.count == 1)
            #expect(waiting.first?.notice.summary.contains("reported a completed turn") == true)
            #expect(AgentWatch.waiting(since: .distantPast, own: ["terminal-session"], home: home, now: now).isEmpty)
            try registry.receive(event("UserPromptSubmit", registration: registration), registrationID: registration.id, now: now)
            #expect(AgentWatch.waiting(since: .distantPast, home: home, now: now).isEmpty)
            try registry.unregister(id: registration.id)
            #expect(await Initiative(home: home).terminalAgentContext(own: []).isEmpty)
        }
    }

    @Test func staleEventsRemainObservationsAndFreshHomesAreOff() async throws {
        try await withProject { home, project, registry in
            #expect(await Initiative(home: home).terminalAgentContext(own: []).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: home.root.path))
            let registration = try registry.register(project: project, adapter: .gemini, executable: "/usr/bin/true")
            try registry.receive(event("BeforeAgent", registration: registration), registrationID: registration.id,
                                 now: .now.addingTimeInterval(-40 * 60))
            let context = await Initiative(home: home).terminalAgentContext(own: [])
            #expect(context.contains("stale, current state unknown"))
            #expect(AgentWatch.waiting(since: .distantPast, home: home).isEmpty)
        }
    }

    @Test(arguments: ["UserPromptSubmit", "SessionEnd", "disconnect"])
    func heldWaitingNoticeWithdrawsWhenTheSessionChanges(_ next: String) async throws {
        try await withProject { home, project, registry in
            let registration = try registry.register(project: project, adapter: .claude, executable: "/usr/bin/true")
            try registry.receive(event("Stop", registration: registration), registrationID: registration.id,
                                 now: .now.addingTimeInterval(-360))
            let initiative = Initiative(home: home)
            let notices = AgentWatch.waiting(since: .distantPast, home: home).map(\.notice)
            #expect(notices.count == 1)
            #expect(await initiative.due(notices, typing: false, looking: false).isEmpty)
            if next == "disconnect" { try registry.unregister(id: registration.id) }
            else { try registry.receive(event(next, registration: registration), registrationID: registration.id) }
            _ = await initiative.terminalAgentContext(own: [])
            #expect(await initiative.due([], typing: false, looking: true).isEmpty)
        }
    }
}
