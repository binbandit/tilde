import Foundation
import Testing
import TildeMemory
@testable import TildeBrain

@Suite struct GoalTests {
    let checkIn = TestTime.at("2026-10-09 17:00")

    @Test func roundTripsThroughItsNoteAndKeepsWhatElseIsWritten() throws {
        var goal = Goal(
            title: "Ship paradise's checkout", objective: "Ship the checkout flow this week.", doneWhen: "Merged to main and on staging.",
            plan: "- Cart summary\n- Payment sheet", project: "~/Developer/frontend/paradise", checkIn: checkIn)
        goal.log("Delegated the cart summary (j-abc1).", at: checkIn)
        #expect(goal.path == "goals/ship-paradise-s-checkout.md")

        let text = goal.note.render()
        #expect(text.hasPrefix("---\nkind: goal\nstatus: active\ncheck-in: "))
        #expect(text.contains("project: \(NSHomeDirectory())/Developer/frontend/paradise"))
        #expect(text.contains("## Objective\n\nShip the checkout flow this week.\n\n## Done when\n\nMerged to main and on staging.\n\n## Plan\n\n- Cart summary"))

        // The owner added a section by hand; tilde's edits keep it.
        var read = try #require(Goal(note: Note(path: goal.path, parsing: text + "\n## Notes\n\nSam owns pricing.\n")))
        #expect(read.title == "Ship paradise's checkout" && read.status == .active && read.checkIn == checkIn)
        #expect(read.plan == "- Cart summary\n- Payment sheet" && read.doneWhen == "Merged to main and on staging.")
        #expect(read.log == ["\(LocalTime.format(checkIn)) Delegated the cart summary (j-abc1)."])

        read.status = .paused
        read.checkIn = nil
        read.log("Paused until the design is settled.")
        let again = read.note.render()
        #expect(again.contains("status: paused") && !again.contains("check-in"))
        #expect(again.contains("## Notes\n\nSam owns pricing.") && again.contains("Paused until the design is settled."))
        #expect(Goal(note: Note(path: read.path, parsing: again)) == read)
    }

    @Test func isDueOnlyWhileActiveAndPastItsCheckIn() {
        var goal = Goal(title: "Keep my PRs green", objective: "Fix red CI fast.", doneWhen: "Never; it's standing.", checkIn: checkIn)
        #expect(!goal.isDue(at: checkIn.addingTimeInterval(-60)))
        #expect(goal.isDue(at: checkIn))
        goal.status = .paused
        #expect(!goal.isDue(at: checkIn.addingTimeInterval(3600)))
        goal.status = .active
        goal.checkIn = nil
        #expect(!goal.isDue(at: checkIn.addingTimeInterval(3600)))
    }

    @Test func isFoundBySlugTitleOrAUniquePartOfItsTitle() throws {
        let notebook = Notebook(url: FileManager.default.temporaryDirectory.appending(path: "tilde-goals-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: notebook.url.appending(path: "goals"), withIntermediateDirectories: true)
        for title in ["Ship paradise checkout", "Keep my PRs green", "Ship the docs site"] {
            let goal = Goal(title: title, objective: "o", doneWhen: "d")
            try goal.note.render().write(to: notebook.url.appending(path: goal.path), atomically: true, encoding: .utf8)
        }
        #expect(Goal.all(in: notebook).count == 3)
        #expect(Goal.find("keep-my-prs-green", in: notebook)?.title == "Keep my PRs green")
        #expect(Goal.find("goals/keep-my-prs-green.md", in: notebook)?.title == "Keep my PRs green")
        #expect(Goal.find("ship paradise checkout", in: notebook)?.title == "Ship paradise checkout")
        #expect(Goal.find("docs", in: notebook)?.title == "Ship the docs site")
        #expect(Goal.find("ship", in: notebook) == nil)  // ambiguous
    }
}
