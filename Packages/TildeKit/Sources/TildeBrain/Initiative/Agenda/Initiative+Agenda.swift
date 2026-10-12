import Foundation

/// Something tilde committed to that has come due: a follow-up, a routine, or a goal's check-in.
struct Due: Sendable, Equatable {
    enum Kind: String, Sendable {
        case followUp = "Follow-up"
        case routine = "Routine"
        case checkIn = "Goal check-in"
    }

    var kind: Kind
    var text: String
    /// When it was due.
    var at: Date
    /// A routine's rule (`every friday 16:00`).
    var rule: String?
    var job: String?
    /// The goal whose check-in this is; its whole note goes to the manager so it can plan from it.
    var goal: Goal?
    /// A one-off's agenda line, retained until the manager accepts its delivery.
    var agendaLine: String?

    var project: String? { goal?.project }

    /// The `<due>` block the manager acts on.
    static func message(_ items: [Due], now: Date = .now) -> String {
        let body = items.map { due in
            switch due.kind {
            case .followUp: "- Follow-up (due \(LocalTime.describe(due.at, from: now))): \(due.text)"
            case .routine: "- Routine (\(due.rule ?? "")): \(due.text)"
            case .checkIn:
                "- Goal check-in (due \(LocalTime.describe(due.at, from: now))) for \"\(due.text)\":\n"
                    + (due.goal.map { "<note path=\"\($0.path)\">\n\($0.note.render().trimmingCharacters(in: .newlines))\n</note>" } ?? "")
            }
        }.joined(separator: "\n")
        return "<due at=\"\(LocalTime.describe(now, from: now))\">\n\(body)\n</due>"
    }
}

/// The agenda and goals as a schedule: reading and changing `agenda.md` (always through this
/// actor, so concurrent changes don't clobber each other), and noticing what came due.
extension Initiative {
    func agenda(calendar: Calendar = .current) -> Agenda {
        Agenda(text: notebook.read("agenda.md"), calendar: calendar)
    }

    func addToAgenda(_ item: Agenda.Item) async {
        var agenda = agenda()
        agenda.add(item)
        await save(agenda, reason: "agenda: add")
    }

    /// Removes the one item whose line contains `words`. Returns every match; nothing is removed
    /// unless there was exactly one.
    func removeFromAgenda(matching words: String) async -> [Agenda.Item] {
        var agenda = agenda()
        let wanted = words.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = agenda.items.filter { !wanted.isEmpty && $0.line().lowercased().contains(wanted) }
        if matches.count == 1 {
            agenda.remove(matches[0])
            await save(agenda, reason: "agenda: remove")
        }
        return matches
    }

    /// What came due since the last look. One-off follow-ups stay in agenda.md until accepted;
    /// each routine run and each goal check-in is delivered once. A routine first seen now waits for
    /// its next time, and one missed by hours (the Mac was asleep) is skipped rather than delivered late.
    func comingDue(now: Date = .now, calendar: Calendar = .current) async -> [Due] {
        let agenda = agenda(calendar: calendar)
        var found: [Due] = []
        var routines: Set<String> = []
        for item in agenda.items {
            switch item.when {
            case .once(let date):
                let line = item.line(calendar: calendar)
                guard date <= now, pendingFollowUps.insert(line).inserted else { continue }
                found.append(Due(kind: .followUp, text: item.text, at: date, job: item.job, agendaLine: line))
            case .every:
                let key = item.line(calendar: calendar)
                routines.insert(key)
                guard let last = seen.fired[key] else {
                    seen.fired[key] = now
                    continue
                }
                guard let latest = item.latest(atOrBefore: now, calendar: calendar), latest > last else { continue }
                seen.fired[key] = now
                if now.timeIntervalSince(latest) < 6 * 3600 {
                    found.append(Due(kind: .routine, text: item.text, at: latest, rule: item.schedule(calendar: calendar), job: item.job))
                }
            }
        }
        seen.fired = seen.fired.filter { routines.contains($0.key) }

        for goal in Goal.all(in: notebook) where goal.isDue(at: now) {
            guard let checkIn = goal.checkIn else { continue }
            let stamp = LocalTime.format(checkIn, calendar: calendar)
            guard seen.checkIns[goal.path] != stamp else { continue }
            seen.checkIns[goal.path] = stamp
            found.append(Due(kind: .checkIn, text: goal.title, at: checkIn, goal: goal))
        }

        persist()
        return found.sorted { $0.at < $1.at }
    }

    /// Accepted follow-ups leave the notebook. Failed sends become due again at the next look;
    /// a restart also retries, because pending claims only live in memory.
    func delivered(_ items: [Due], accepted: Bool) async {
        let lines = Set(items.compactMap(\.agendaLine)).intersection(pendingFollowUps)
        guard !lines.isEmpty else { return }
        if accepted {
            var agenda = agenda()
            for line in lines {
                if let item = Agenda.Item(line: line) { agenda.remove(item) }
            }
            await save(agenda, reason: "follow-ups handed to tilde")
        }
        pendingFollowUps.subtract(lines)
    }

    /// What's coming after `start` up to `end`: follow-ups, routine runs and goal check-ins, soonest first.
    func plans(from start: Date, until end: Date, calendar: Calendar = .current) -> [String] {
        var plans: [(at: Date, text: String)] = []
        for item in agenda(calendar: calendar).items {
            guard let next = item.next(after: start, calendar: calendar), next <= end else { continue }
            plans.append((next, "\(LocalTime.describe(next, from: start, calendar: calendar)) \(item.isRoutine ? "routine" : "follow-up"): \(item.text)"))
        }
        for goal in Goal.all(in: notebook) where goal.status == .active {
            guard let checkIn = goal.checkIn, checkIn > start, checkIn <= end else { continue }
            plans.append((checkIn, "\(LocalTime.describe(checkIn, from: start, calendar: calendar)) check-in on the goal \"\(goal.title)\""))
        }
        return plans.sorted { $0.at < $1.at }.map(\.text)
    }

    private func save(_ agenda: Agenda, reason: String) async {
        try? agenda.text.write(to: notebook.url.appending(path: "agenda.md"), atomically: true, encoding: .utf8)
        await notebook.commitChanges(context: reason)
    }
}
