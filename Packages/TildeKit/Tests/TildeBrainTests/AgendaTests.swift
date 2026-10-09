import Foundation
import Testing
import TildeMemory
import TildeSupport
import TildeWork
@testable import TildeBrain

/// A fixed calendar, so weekdays and times don't depend on where the tests run.
/// 2026-10-09 is a Friday.
enum TestTime {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    static func at(_ text: String) -> Date { LocalTime.parse(text, calendar: calendar)! }
}

/// A review model that answers at once, with the same reply every time.
struct CannedModel: MemoryModel {
    var reply: String? = #"{"notices": []}"#
    func run(_ pass: ModelPass) async throws -> ModelReply { ModelReply(ok: true, text: reply) }
}

@Suite struct AgendaTests {
    let calendar = TestTime.calendar
    func at(_ text: String) -> Date { TestTime.at(text) }

    @Test func readsFollowUpsAndRoutinesAndIgnoresEverythingElse() {
        let agenda = Agenda(text: """
            # Agenda

            Notes about how I like reminders.

            ## Follow-ups

            - 2026-10-09 17:00 check on the nav bar (j-n8v3)
            - someday, maybe, look at the docs

            ## Routines

            - every weekday 09:00 morning brief
            - Every Fridays at 16:00 what shipped this week
            """, calendar: calendar)
        #expect(agenda.items.map { $0.line(calendar: calendar) } == [
            "- 2026-10-09 17:00 check on the nav bar (j-n8v3)",
            "- every weekday 09:00 morning brief",
            "- every friday 16:00 what shipped this week",
        ])
        #expect(agenda.items.map(\.job) == ["j-n8v3", nil, nil])
        #expect(Agenda.Item(line: "- 2026-02-30 09:00 a day that doesn't exist", calendar: calendar) == nil)
        #expect(Agenda.Item(line: "- every fortnight 09:00 not a rule", calendar: calendar) == nil)
        #expect(Agenda.Item(line: "- 2026-10-09 17:00", calendar: calendar) == nil)
        #expect(Agenda.Item.When("every weekday 09:00", calendar: calendar) == .every(.weekday, hour: 9, minute: 0))
        #expect(Agenda.Item.When("every weekday 09:00 and more", calendar: calendar) == nil)
        #expect(Agenda.Item.When("tomorrow at 5", calendar: calendar) == nil)
    }

    @Test func routinesKeepToTheirDays() {
        let weekdays = Agenda.Item(when: .every(.weekday, hour: 9, minute: 0), text: "morning brief")
        let saturday = at("2026-10-10 10:00")
        #expect(weekdays.latest(atOrBefore: saturday, calendar: calendar) == at("2026-10-09 09:00"))
        #expect(weekdays.next(after: saturday, calendar: calendar) == at("2026-10-12 09:00"))

        let fridays = Agenda.Item(when: .every(.friday, hour: 16, minute: 0), text: "what shipped")
        #expect(fridays.latest(atOrBefore: at("2026-10-09 15:59"), calendar: calendar) == at("2026-10-02 16:00"))
        #expect(fridays.latest(atOrBefore: at("2026-10-09 16:00"), calendar: calendar) == at("2026-10-09 16:00"))
        #expect(fridays.next(after: at("2026-10-09 16:00"), calendar: calendar) == at("2026-10-16 16:00"))

        let weekends = Agenda.Item(when: .every(.weekend, hour: 10, minute: 30), text: "nightly test run")
        #expect(weekends.next(after: at("2026-10-09 12:00"), calendar: calendar) == at("2026-10-10 10:30"))

        let once = Agenda.Item(when: .once(at("2026-10-09 17:00")), text: "check on the nav bar")
        #expect(once.latest(atOrBefore: at("2026-10-09 16:59"), calendar: calendar) == nil)
        #expect(once.next(after: at("2026-10-09 17:00"), calendar: calendar) == nil)
    }

    @Test func addsUnderItsHeadingAndRemovesJustThatLine() {
        var agenda = Agenda(calendar: calendar)
        agenda.add(Agenda.Item(when: .once(at("2026-10-09 17:00")), text: "check on the nav bar"))
        agenda.add(Agenda.Item(when: .every(.friday, hour: 16, minute: 0), text: "what shipped this week"))
        agenda.add(Agenda.Item(when: .once(at("2026-10-10 09:00")), text: "review Sam's PR"))
        #expect(agenda.text.hasPrefix("# Agenda\n"))
        #expect(agenda.text.hasSuffix("""
            ## Follow-ups

            - 2026-10-09 17:00 check on the nav bar
            - 2026-10-10 09:00 review Sam's PR

            ## Routines

            - every friday 16:00 what shipped this week

            """))

        let removed = agenda.remove(agenda.items[0])
        #expect(removed && !agenda.text.contains("nav bar") && agenda.text.contains("review Sam's PR"))
        let again = agenda.remove(Agenda.Item(when: .once(at("2026-10-09 17:00")), text: "check on the nav bar"))
        #expect(!again)
    }

    // MARK: Coming due

    let home = TildeHome(root: FileManager.default.temporaryDirectory.appending(path: "tilde-agenda-\(UUID().uuidString)"))

    func initiative(agenda: String = "") throws -> Initiative {
        try home.prepare()
        try agenda.write(to: home.notebook.appending(path: "agenda.md"), atomically: true, encoding: .utf8)
        return Initiative(home: home, projects: ProjectIndex(roots: []), review: CannedModel())
    }

    func due(_ initiative: Initiative, _ now: String) async -> [String] {
        await initiative.comingDue(now: at(now), calendar: calendar).map(\.text)
    }

    var agendaFile: String { (try? String(contentsOf: home.notebook.appending(path: "agenda.md"), encoding: .utf8)) ?? "" }

    @Test func followUpsComeDueOnceAndLeaveTheAgenda() async throws {
        let initiative = try initiative(agenda: """
            ## Follow-ups

            - 2026-10-09 17:00 check on the nav bar (j-n8v3)
            - 2026-10-09 18:00 ask Sam about pricing
            """)
        #expect(await due(initiative, "2026-10-09 16:59").isEmpty)

        let first = await initiative.comingDue(now: at("2026-10-09 17:01"), calendar: calendar)
        #expect(first.map(\.text) == ["check on the nav bar (j-n8v3)"])
        #expect(first.map(\.kind) == [.followUp] && first.first?.job == "j-n8v3")
        #expect(!agendaFile.contains("nav bar") && agendaFile.contains("ask Sam about pricing"))

        #expect(await due(initiative, "2026-10-09 17:02").isEmpty)
        #expect(await due(initiative, "2026-10-09 18:30") == ["ask Sam about pricing"])
    }

    @Test func routinesComeDueOncePerRunFromWhenTheyWereFirstSeen() async throws {
        let initiative = try initiative(agenda: """
            ## Routines

            - every weekday 09:00 morning brief
            - every friday 16:00 what shipped this week
            """)
        // First sighting only learns them: nothing that was due earlier is delivered late.
        #expect(await due(initiative, "2026-10-09 08:00").isEmpty)
        #expect(await due(initiative, "2026-10-09 09:01") == ["morning brief"])
        #expect(await due(initiative, "2026-10-09 09:30").isEmpty)
        #expect(await due(initiative, "2026-10-09 16:00") == ["what shipped this week"])
        #expect(await due(initiative, "2026-10-10 09:05").isEmpty)  // Saturday
        #expect(await due(initiative, "2026-10-12 09:00") == ["morning brief"])  // Monday
        #expect(agendaFile.contains("- every weekday 09:00 morning brief"))
    }

    @Test func routinesMissedByHoursAreSkippedNotDeliveredLate() async throws {
        let initiative = try initiative(agenda: """
            - every weekday 09:00 morning brief
            - every friday 16:00 what shipped this week
            """)
        #expect(await due(initiative, "2026-10-08 20:00").isEmpty)
        // The Mac slept until Friday 17:00: the 09:00 brief is stale, the 16:00 routine isn't.
        #expect(await due(initiative, "2026-10-09 17:00") == ["what shipped this week"])
        #expect(await due(initiative, "2026-10-09 17:30").isEmpty)
    }

    @Test func goalCheckInsComeDueOncePerCheckIn() async throws {
        let initiative = try initiative()
        var goal = Goal(title: "Ship checkout", objective: "Ship the checkout flow.", doneWhen: "Merged to main.", checkIn: at("2026-10-09 10:00"))
        func save() throws {
            try FileManager.default.createDirectory(at: home.notebook.appending(path: "goals"), withIntermediateDirectories: true)
            try goal.note.render().write(to: home.notebook.appending(path: goal.path), atomically: true, encoding: .utf8)
        }
        try save()
        #expect(await due(initiative, "2026-10-09 09:59").isEmpty)

        let checkIn = await initiative.comingDue(now: at("2026-10-09 10:00"), calendar: calendar)
        #expect(checkIn.map(\.kind) == [.checkIn] && checkIn.first?.goal?.path == "goals/ship-checkout.md")
        let message = Due.message(checkIn, now: at("2026-10-09 10:00"))
        #expect(message.hasPrefix("<due") && message.contains("<note path=\"goals/ship-checkout.md\">") && message.contains("Merged to main."))
        #expect(await due(initiative, "2026-10-09 10:05").isEmpty)

        // The manager moved the check-in: it comes back then.
        goal.checkIn = at("2026-10-09 15:00")
        try save()
        #expect(await due(initiative, "2026-10-09 14:00").isEmpty)
        #expect(await due(initiative, "2026-10-09 15:00") == ["Ship checkout"])

        goal.checkIn = at("2026-10-10 09:00")
        goal.status = .paused
        try save()
        #expect(await due(initiative, "2026-10-10 09:30").isEmpty)
    }

    @Test func plansListWhatsComingSoonestFirst() async throws {
        let initiative = try initiative(agenda: """
            - 2026-10-09 17:00 check on the nav bar
            - every friday 16:00 what shipped this week
            - 2026-10-10 09:00 tomorrow's thing
            """)
        let plans = await initiative.plans(from: at("2026-10-09 12:00"), until: at("2026-10-09 23:59"), calendar: calendar)
        #expect(plans.count == 2)
        #expect(plans[0].contains("routine: what shipped this week") && plans[1].contains("follow-up: check on the nav bar"))
    }

    @Test func theMorningBriefIsClaimedOnceADayAfterSix() async throws {
        let initiative = try initiative()
        #expect(!(await initiative.claimBrief(now: at("2026-10-09 05:30"), calendar: calendar)))
        #expect(await initiative.claimBrief(now: at("2026-10-09 08:10"), calendar: calendar))
        #expect(!(await initiative.claimBrief(now: at("2026-10-09 13:00"), calendar: calendar)))
        #expect(await initiative.briefedRecently(now: at("2026-10-09 08:25")))
        #expect(!(await initiative.briefedRecently(now: at("2026-10-09 09:00"))))
        #expect(await initiative.claimBrief(now: at("2026-10-10 06:00"), calendar: calendar))
    }
}
