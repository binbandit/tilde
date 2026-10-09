import Foundation
import Testing
import TildeMemory
import TildeSupport
import WorkerKit
@testable import TildeBrain

/// The manager's goal and agenda tools, called the way the manager calls them.
@MainActor
@Suite(.serialized) struct AgendaToolsTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "tilde-agenda-tools-\(UUID().uuidString)")

    func makeConductor() async throws -> Conductor {
        var config = Conductor.Config()
        config.projectRoots = []
        config.manager.executable = "/usr/bin/false"  // no model in these tests
        config.scribe.executable = "/usr/bin/false"
        config.dream.executable = "/usr/bin/false"
        config.review.executable = "/usr/bin/false"
        let conductor = try Conductor(home: TildeHome(root: root), config: config)
        try await conductor.memory.prepare()
        return conductor
    }

    func call(_ conductor: Conductor, _ tool: String, _ args: JSON) async -> ToolResult {
        await conductor.makeTools().call(tool, args)
    }

    @Test func goalsAreSetUpdatedAndClosed() async throws {
        let conductor = try await makeConductor()
        let goal: JSON = [
            "title": "Ship checkout", "objective": "Ship the checkout flow this week.", "done_when": "Merged to main.",
            "plan": "- Cart summary", "check_in": "2026-10-09 17:00", "project": .string(root.path),
        ]
        let set = await call(conductor, "set_goal", goal)
        #expect(!set.isError, "\(set.text)")
        let path = "goals/ship-checkout.md"
        var note = try #require(conductor.memory.notebook.read(path))
        #expect(note.contains("status: active") && note.contains("check-in: 2026-10-09 17:00") && note.contains("project: \(root.path)"))
        #expect(note.contains("## Done when\n\nMerged to main.") && note.contains("Took this on."))

        #expect(await call(conductor, "set_goal", goal).isError)  // already there
        #expect(await call(conductor, "set_goal", goal.merging(["title": "Other", "check_in": "tomorrow at 5"])).isError)

        let updated = await call(conductor, "update_goal", [
            "goal": "checkout", "log": "Delegated the cart summary (j-abc1).", "check_in": "2026-10-10 09:00", "status": "paused",
        ])
        #expect(!updated.isError, "\(updated.text)")
        note = try #require(conductor.memory.notebook.read(path))
        #expect(note.contains("status: paused") && note.contains("check-in: 2026-10-10 09:00") && note.contains("Delegated the cart summary"))
        #expect(await call(conductor, "update_goal", ["goal": "checkout", "status": "done"]).isError)  // that's close_goal's job
        #expect(await call(conductor, "update_goal", ["goal": "nonexistent"]).text.contains("Ship checkout"))

        let closed = await call(conductor, "close_goal", ["goal": "ship-checkout", "outcome": "Merged as #12."])
        #expect(!closed.isError)
        note = try #require(conductor.memory.notebook.read(path))
        #expect(note.contains("status: done") && !note.contains("check-in") && note.contains("Done. Merged as #12."))
        #expect(await call(conductor, "goals", [:]).text == "No goals yet (1 done).")
        #expect(await call(conductor, "goals", ["goal": "checkout"]).text.contains("## Objective"))
        #expect(conductor.memory.notebook.read(Notebook.journalName())?.contains("Goal done: Ship checkout") == true)
    }

    @Test func theAgendaTakesExplicitTimesOnly() async throws {
        let conductor = try await makeConductor()
        let later = LocalTime.format(.now.addingTimeInterval(2 * 3600))
        let added = await call(conductor, "add_to_agenda", ["when": .string(later), "what": "check on the nav bar", "job": "j-n8v3"])
        #expect(!added.isError, "\(added.text)")
        #expect(!(await call(conductor, "add_to_agenda", ["when": "every friday 16:00", "what": "what shipped this week"])).isError)
        #expect(!(await call(conductor, "add_to_agenda", ["when": .string(later), "what": "check on the build"])).isError)

        #expect(await call(conductor, "add_to_agenda", ["when": "at 5pm", "what": "natural language is the manager's job"]).isError)
        #expect(await call(conductor, "add_to_agenda", ["when": "2020-01-01 09:00", "what": "already passed"]).isError)
        #expect(await call(conductor, "add_to_agenda", ["when": .string(later), "what": " "]).isError)

        let file = try #require(conductor.memory.notebook.read("agenda.md"))
        #expect(file.contains("## Follow-ups\n\n- \(later) check on the nav bar (j-n8v3)\n- \(later) check on the build\n"))
        #expect(file.contains("## Routines\n\n- every friday 16:00 what shipped this week\n"))
        let listing = await call(conductor, "agenda", [:]).text
        #expect(listing.contains("check on the nav bar (j-n8v3)") && listing.contains("every friday 16:00 what shipped this week (next "))

        #expect(await call(conductor, "remove_from_agenda", ["item": "water the plants"]).isError)
        let ambiguous = await call(conductor, "remove_from_agenda", ["item": "check on"])
        #expect(ambiguous.isError && ambiguous.text.contains("nav bar") && ambiguous.text.contains("build"))
        #expect(!(await call(conductor, "remove_from_agenda", ["item": "nav bar"])).isError)
        let after = try #require(conductor.memory.notebook.read("agenda.md"))
        #expect(!after.contains("nav bar") && after.contains("check on the build") && after.contains("what shipped"))
    }
}
