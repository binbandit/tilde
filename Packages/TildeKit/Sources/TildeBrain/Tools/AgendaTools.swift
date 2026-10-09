import Foundation
import TildeSupport
import WorkerKit

/// Goals, follow-ups and routines: what tilde has taken on, and when it comes back to it.
/// Times are always explicit local times; turning "after lunch" into one is the manager's job.
extension Conductor {
    var setGoalTool: AgentTool {
        AgentTool(
            "set_goal",
            "Take on a standing objective \(Owner.firstName) hands you. Saved as goals/<slug>.md; at each check-in it comes back to you as <due>.",
            schema: AgentTool.object([
                "title": .text("A few words naming it, e.g. 'Ship paradise checkout'."),
                "objective": .text("What and why, in a sentence or two."),
                "done_when": .text("How you'll know it's done: concrete and checkable."),
                "plan": .text("The next steps, as markdown bullets."),
                "project": .text("Absolute path of the repo it's about, if any."),
                "check_in": .text("When to next look at it, local time 'YYYY-MM-DD HH:MM'."),
            ], required: ["title", "objective", "done_when", "check_in"])
        ) { args in await self.toolSetGoal(args) }
    }

    var updateGoalTool: AgentTool {
        AgentTool(
            "update_goal",
            "Change a goal: log progress, move its check-in, revise the plan, or pause and resume it. Only what you pass changes.",
            schema: AgentTool.object([
                "goal": .text("The goal's title or slug."),
                "log": .text("One line for its log: what happened or what you did."),
                "check_in": .text("Next check-in, local time 'YYYY-MM-DD HH:MM'. Empty clears it."),
                "plan": .text("The whole new plan, as markdown bullets."),
                "objective": .text("A revised objective."),
                "done_when": .text("A revised definition of done."),
                "project": .text("Absolute path of the repo it's about."),
                "status": ["type": "string", "enum": ["active", "paused"]],
            ], required: ["goal"])
        ) { args in await self.toolUpdateGoal(args) }
    }

    var closeGoalTool: AgentTool {
        AgentTool(
            "close_goal",
            "Mark a goal done (its done-when is met, or \(Owner.firstName) dropped it).",
            schema: AgentTool.object([
                "goal": .text("The goal's title or slug."), "outcome": .text("One or two sentences: how it ended."),
            ], required: ["goal", "outcome"])
        ) { args in await self.toolCloseGoal(args) }
    }

    var goalsTool: AgentTool {
        AgentTool(
            "goals",
            "List the goals you're working toward, or read one in full.",
            schema: AgentTool.object(["goal": .text("A title or slug to read in full. Omit to list them all.")])
        ) { args in await self.toolGoals(args) }
    }

    var addToAgendaTool: AgentTool {
        AgentTool(
            "add_to_agenda",
            "Put a follow-up (once) or a routine (repeating) on your agenda. When it comes due you get it as <due>.",
            schema: AgentTool.object([
                "when": .text("Local time 'YYYY-MM-DD HH:MM' for a follow-up, or 'every <day|weekday|weekend|monday..sunday> HH:MM' for a routine."),
                "what": .text("What to do then, in a few words, e.g. 'check on the nav bar'."),
                "job": .text("The job it's about, if any."),
            ], required: ["when", "what"])
        ) { args in await self.toolAddToAgenda(args) }
    }

    var removeFromAgendaTool: AgentTool {
        AgentTool(
            "remove_from_agenda",
            "Take a follow-up or routine off your agenda.",
            schema: AgentTool.object(["item": .text("Words from the item, enough to pick out just one.")], required: ["item"])
        ) { args in await self.toolRemoveFromAgenda(args) }
    }

    var agendaTool: AgentTool {
        AgentTool(
            "agenda",
            "Your follow-ups and routines, with when each is next due.",
            schema: AgentTool.object([:])
        ) { _ in await self.toolAgenda() }
    }

    // MARK: Implementations

    private func toolSetGoal(_ args: JSON) async -> ToolResult {
        guard let title = args["title"]?.string, !title.isEmpty, let objective = args["objective"]?.string,
            let doneWhen = args["done_when"]?.string
        else { return .error("title, objective and done_when are required.") }
        guard let checkIn = args["check_in"]?.string.flatMap({ LocalTime.parse($0) }) else { return Self.badTime("check_in") }
        let project = args["project"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        var goal = Goal(title: title, objective: objective, doneWhen: doneWhen, plan: args["plan"]?.string ?? "", project: project, checkIn: checkIn)
        if memory.notebook.read(goal.path) != nil {
            return .error("There's already a goal at \(goal.path). Use update_goal (status active reopens a finished one).")
        }
        goal.log("Took this on.")
        return await save(goal, reason: "new goal", journal: "New goal: \(title)")
    }

    private func toolUpdateGoal(_ args: JSON) async -> ToolResult {
        guard var goal = findGoal(args["goal"]?.string) else { return noGoal(args["goal"]?.string) }
        if let checkIn = args["check_in"]?.string {
            if checkIn.trimmingCharacters(in: .whitespaces).isEmpty {
                goal.checkIn = nil
            } else {
                guard let date = LocalTime.parse(checkIn) else { return Self.badTime("check_in") }
                goal.checkIn = date
            }
        }
        if let status = args["status"]?.string {
            guard let status = Goal.Status(rawValue: status), status != .done else { return .error("status is active or paused; use close_goal to finish it.") }
            goal.status = status
        }
        if let objective = args["objective"]?.string { goal.objective = objective }
        if let doneWhen = args["done_when"]?.string { goal.doneWhen = doneWhen }
        if let plan = args["plan"]?.string { goal.plan = plan }
        if let project = args["project"]?.string { goal.project = project.isEmpty ? nil : project }
        if let entry = args["log"]?.string, !entry.isEmpty { goal.log(entry) }
        return await save(goal, reason: "goal update", journal: nil)
    }

    private func toolCloseGoal(_ args: JSON) async -> ToolResult {
        guard var goal = findGoal(args["goal"]?.string) else { return noGoal(args["goal"]?.string) }
        let outcome = args["outcome"]?.string ?? ""
        goal.status = .done
        goal.checkIn = nil
        goal.log("Done. \(outcome)")
        return await save(goal, reason: "goal done", journal: "Goal done: \(goal.title). \(outcome)")
    }

    private func toolGoals(_ args: JSON) async -> ToolResult {
        if let query = args["goal"]?.string, !query.isEmpty {
            guard let goal = findGoal(query) else { return noGoal(query) }
            return .ok(goal.note.render())
        }
        let goals = Goal.all(in: memory.notebook)
        let open = goals.filter { $0.status != .done }
        guard !open.isEmpty else { return .ok("No goals yet\(goals.isEmpty ? "" : " (\(goals.count) done)").") }
        let done = goals.count - open.count
        return .ok(open.map { "- \($0.digest)" }.joined(separator: "\n") + (done > 0 ? "\n(\(done) done)" : ""))
    }

    private func toolAddToAgenda(_ args: JSON) async -> ToolResult {
        guard let when = args["when"]?.string.flatMap({ Agenda.Item.When($0) }) else { return Self.badTime("when") }
        guard var what = args["what"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !what.isEmpty else {
            return .error("what is required.")
        }
        if case .once(let date) = when, date < .now.addingTimeInterval(-60) {
            return .error("\(LocalTime.format(date)) has already passed. It's \(LocalTime.format(.now)).")
        }
        if let job = args["job"]?.string, !job.isEmpty, !what.contains(job) { what += " (\(job))" }
        let item = Agenda.Item(when: when, text: what.replacingOccurrences(of: "\n", with: " "))
        await initiative.addToAgenda(item)
        let next = item.next(after: .now).map { " Next due \(LocalTime.describe($0))." } ?? ""
        return .ok("Added \(item.line()).\(next)")
    }

    private func toolRemoveFromAgenda(_ args: JSON) async -> ToolResult {
        let words = args["item"]?.string ?? ""
        let matches = await initiative.removeFromAgenda(matching: words)
        switch matches.count {
        case 0: return .error("Nothing on the agenda matches \"\(words)\". \(await agendaListing())")
        case 1: return .ok("Removed \(matches[0].line()).")
        default: return .error("Several items match; say which:\n" + matches.map { $0.line() }.joined(separator: "\n"))
        }
    }

    private func toolAgenda() async -> ToolResult {
        .ok(await agendaListing())
    }

    // MARK: Helpers

    private func agendaListing() async -> String {
        let items = await initiative.agenda().items
        guard !items.isEmpty else { return "The agenda is empty." }
        return items.map { item in
            item.line() + (item.isRoutine ? item.next(after: .now).map { " (next \(LocalTime.describe($0)))" } ?? "" : "")
        }.joined(separator: "\n")
    }

    private func findGoal(_ query: String?) -> Goal? {
        query.flatMap { $0.isEmpty ? nil : Goal.find($0, in: memory.notebook) }
    }

    private func noGoal(_ query: String?) -> ToolResult {
        let titles = Goal.all(in: memory.notebook).filter { $0.status != .done }.map(\.title)
        return .error("No goal matches \"\(query ?? "")\".\(titles.isEmpty ? "" : " Goals: \(titles.joined(separator: "; ")).")")
    }

    private func save(_ goal: Goal, reason: String, journal: String?) async -> ToolResult {
        do {
            try await memory.rewrite(goal.path, goal.note.render(), reason: reason)
            if let journal { log.journal(journal) }
            return .ok("Saved \(goal.path): \(goal.digest)")
        } catch {
            return .error("Couldn't save \(goal.path): \(error)")
        }
    }

    private static func badTime(_ field: String) -> ToolResult {
        let example = LocalTime.format(Date.now.addingTimeInterval(3600))
        return .error("\(field) must be a local time like '\(example)'\(field == "when" ? " or a routine like 'every weekday 09:00'" : ""). It's \(LocalTime.format(.now)) now.")
    }
}
