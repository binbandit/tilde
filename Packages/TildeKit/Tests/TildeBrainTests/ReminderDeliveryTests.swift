import Foundation
import Testing
import TildeSupport
@testable import TildeBrain

@MainActor
@Suite struct ReminderDeliveryTests {
    let home = TildeHome(root: FileManager.default.temporaryDirectory.appending(path: "tilde-reminder-\(UUID().uuidString)"))

    private func config(executable: String) -> Conductor.Config {
        var config = Conductor.Config()
        config.projectRoots = []
        config.initiative = false
        config.manager.executable = executable
        config.scribe.executable = "/usr/bin/false"
        config.dream.executable = "/usr/bin/false"
        config.review.executable = "/usr/bin/false"
        return config
    }

    @Test(.timeLimit(.minutes(1))) func anUnavailableManagerKeepsTheFollowUpForRetryAndRestart() async throws {
        let conductor = try Conductor(home: home, config: config(executable: home.root.appending(path: "missing-codex").path))
        let agendaURL = home.notebook.appending(path: "agenda.md")
        try "- 2026-10-09 17:00 check on the nav bar\n".write(to: agendaURL, atomically: true, encoding: .utf8)
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
        #expect(try String(contentsOf: agendaURL, encoding: .utf8).contains("check on the nav bar"))
        let retried = await conductor.initiative.comingDue(now: now.addingTimeInterval(60), calendar: TestTime.calendar)
        #expect(retried.map(\.text) == ["check on the nav bar"])
        let restarted = Initiative(home: home, review: CannedModel())
        #expect(await restarted.comingDue(now: now.addingTimeInterval(120), calendar: TestTime.calendar).map(\.text) == ["check on the nav bar"])
        await conductor.manager.shutdown()
    }

    @Test(.timeLimit(.minutes(1))) func acceptedFollowUpsLeaveTheAgendaAndAreNotDeliveredAgain() async throws {
        let conductor = try Conductor(home: home, config: config(executable: try fakeManager()))
        let agendaURL = home.notebook.appending(path: "agenda.md")
        try "- 2026-10-09 17:00 check on the nav bar\n- 2026-10-09 18:00 another follow-up\n"
            .write(to: agendaURL, atomically: true, encoding: .utf8)
        let now = TestTime.at("2026-10-09 17:01")
        let due = await conductor.initiative.comingDue(now: now, calendar: TestTime.calendar)
        // Pending means claimed, not delivered: the next poll cannot queue a duplicate.
        #expect(await conductor.initiative.comingDue(now: now, calendar: TestTime.calendar).isEmpty)
        #expect(try String(contentsOf: agendaURL, encoding: .utf8).contains("check on the nav bar"))
        conductor.remind(due)
        for await output in conductor.manager.outputs {
            conductor.handle(output)
            if case .undelivered(_, let reason) = output { Issue.record("\(reason)"); break }
            if case .read = output { break }
        }
        let saved = try String(contentsOf: agendaURL, encoding: .utf8)
        #expect(!saved.contains("check on the nav bar"))
        #expect(saved.contains("another follow-up"))
        #expect(await conductor.initiative.comingDue(now: now, calendar: TestTime.calendar).isEmpty)
        let restarted = Initiative(home: home, review: CannedModel())
        #expect(await restarted.comingDue(now: now, calendar: TestTime.calendar).isEmpty)
        let requests = try String(contentsOf: home.root.appending(path: "requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").compactMap { JSON.parse(String($0)) }
        #expect(requests.filter { $0["method"]?.string == "turn/start" }.count == 1)
        await conductor.manager.shutdown()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func theManagerReportsAcceptanceExactlyOnce(_ accepted: Bool) async throws {
        let executable = accepted ? try fakeManager() : home.root.appending(path: "missing-codex").path
        let conductor = try Conductor(home: home, config: config(executable: executable))
        let deliveries = Deliveries()
        var message = Manager.Message("<due>check on the nav bar</due>")
        message.onDelivery = { accepted in await deliveries.record(accepted) }
        await conductor.manager.post(message)
        for await output in conductor.manager.outputs {
            if case .read = output { break }
            if case .undelivered = output { break }
        }
        #expect(await deliveries.values == [accepted])
        await conductor.manager.shutdown()
        #expect(await deliveries.values == [accepted])
    }

    private func fakeManager() throws -> String {
        try home.prepare()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/fake_gateway_session.py")
        let executable = home.root.appending(path: "fake-codex")
        try "#!/bin/sh\nFAKE_SCENARIO=success FAKE_OUT='\(home.root.appending(path: "requests.jsonl").path)' exec /usr/bin/python3 -I '\(fixture.path)'\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable.path
    }
}

private actor Deliveries {
    var values: [Bool] = []
    func record(_ accepted: Bool) { values.append(accepted) }
}
