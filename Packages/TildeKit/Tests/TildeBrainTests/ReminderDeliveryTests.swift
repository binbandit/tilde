import Foundation
import Testing
import TildeSupport
@testable import TildeBrain

@MainActor
@Suite struct ReminderDeliveryTests {
    let home = TildeHome(root: FileManager.default.temporaryDirectory.appending(path: "tilde-reminder-\(UUID().uuidString)"))
    var agenda: URL { home.notebook.appending(path: "agenda.md") }

    private func conductor(codex: String) throws -> Conductor {
        var config = Conductor.Config()
        config.projectRoots = []
        config.initiative = false
        config.manager.executable = codex
        config.scribe.executable = "/usr/bin/false"
        config.dream.executable = "/usr/bin/false"
        config.review.executable = "/usr/bin/false"
        return try Conductor(home: home, config: config)
    }

    @Test(.timeLimit(.minutes(1))) func aFollowUpCodexCouldntTakeComesDueAgainAfterAWait() async throws {
        let conductor = try conductor(codex: home.root.appending(path: "missing-codex").path)
        try "- 2026-10-09 17:00 check on the nav bar\n".write(to: agenda, atomically: true, encoding: .utf8)
        let now = TestTime.at("2026-10-09 17:01")
        let due = await conductor.initiative.comingDue(now: now, calendar: TestTime.calendar)
        #expect(due.map(\.text) == ["check on the nav bar"])
        conductor.remind(due)
        for await output in conductor.manager.outputs {
            conductor.handle(output)
            if case .undelivered(let taps, _) = output {
                #expect(taps.isEmpty)
                break
            }
        }
        #expect(conductor.trouble != nil)
        #expect(conductor.thread.isEmpty)
        try await waitFor { await conductor.initiative.failedHandOvers == 1 }
        #expect(try String(contentsOf: agenda, encoding: .utf8).contains("check on the nav bar"))

        // Not at the very next look, while Codex is down...
        #expect(await conductor.initiative.comingDue(now: now.addingTimeInterval(60), calendar: TestTime.calendar).isEmpty)
        // ...but once the wait is over, and straight away after a restart.
        let later = await conductor.initiative.comingDue(now: .now.addingTimeInterval(61), calendar: TestTime.calendar)
        #expect(later.map(\.text) == ["check on the nav bar"])
        let restarted = Initiative(home: home, review: CannedModel())
        #expect(await restarted.comingDue(now: now, calendar: TestTime.calendar).map(\.text) == ["check on the nav bar"])
        await conductor.manager.shutdown()
    }

    @Test(.timeLimit(.minutes(1))) func aFollowUpTheManagerTookLeavesTheAgendaAndIsntHandedOverAgain() async throws {
        let codex = try FakeCodex(in: home.root, scenario: "answer")
        let conductor = try conductor(codex: codex.executable)
        try "- 2026-10-09 17:00 check on the nav bar\n- 2026-10-09 18:00 another follow-up\n"
            .write(to: agenda, atomically: true, encoding: .utf8)
        let now = TestTime.at("2026-10-09 17:01")
        let due = await conductor.initiative.comingDue(now: now, calendar: TestTime.calendar)
        // Handed over isn't taken: it stays in the agenda, but the next look can't hand it over twice.
        #expect(await conductor.initiative.comingDue(now: now, calendar: TestTime.calendar).isEmpty)
        #expect(try String(contentsOf: agenda, encoding: .utf8).contains("check on the nav bar"))

        conductor.remind(due)
        try await waitFor { (try? String(contentsOf: agenda, encoding: .utf8).contains("check on the nav bar")) == false }
        #expect(try String(contentsOf: agenda, encoding: .utf8).contains("another follow-up"))
        #expect(await conductor.initiative.comingDue(now: now, calendar: TestTime.calendar).isEmpty)
        let restarted = Initiative(home: home, review: CannedModel())
        #expect(await restarted.comingDue(now: now, calendar: TestTime.calendar).isEmpty)
        #expect(codex.requests("turn/start").count == 1)
        await conductor.manager.shutdown()
    }

    private func waitFor(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 where !(await condition()) { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await condition())
    }
}
