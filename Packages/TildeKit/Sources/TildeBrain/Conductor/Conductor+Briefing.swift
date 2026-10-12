import Foundation
import TildeSupport
import TildeWork

/// What tilde gathers to look across everything: the background review's inputs, and the
/// morning brief built from them.
extension Conductor {
    /// The morning brief: the review's findings, today's calendar, what changed overnight and
    /// what's due today, for the manager to turn into a few lines at the first sit-down of the
    /// day. A quiet tap, so nothing shows if there's nothing worth saying.
    func brief(since: Date) {
        Task {
            let now = Date.now
            let endOfDay = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400)
            let inputs = await reviewInputs(scheduleHours: max(2, endOfDay.timeIntervalSince(now) / 3600))
            let found = await initiative.review(inputs) ?? []
            // Everything held back for when they look, plus the review, goes into the brief.
            let noticed = await initiative.due(found, typing: false, looking: true)
            let overnight = jobs.filter { $0.updatedAt > since }.map { "- \($0.digest)" } + (await initiative.changes(since: since))
            let today = await initiative.plans(from: now, until: endOfDay)
            await untilQuiet()

            let id = IDs.make("t")
            quietTaps.insert(id)
            if replying == nil { replying = id }
            // What's waiting on them leads: it's the one thing nobody else can do.
            let waiting = attention.map { "- \($0.question)" + ($0.jobID.flatMap { self.job($0) }.map { " (\($0.title))" } ?? "") }
            let sections = [
                ("waiting", waiting.joined(separator: "\n")),
                ("schedule", inputs.schedule), ("overnight", overnight.joined(separator: "\n")),
                ("today", today.map { "- \($0)" }.joined(separator: "\n")), ("noticed", Self.describe(noticed)),
            ]
            let body = sections.filter { !$0.1.isEmpty }.map { "<\($0.0)>\n\($0.1)\n</\($0.0)>" }.joined(separator: "\n")
            await manager.post(.init(
                "<brief at=\"\(LocalTime.describe(now, from: now))\">\n\(Owner.firstName) just sat down at the Mac for the first time "
                    + "today. Give them the morning brief in your voice, or reply with an empty message if nothing deserves a word.\n"
                    + (body.isEmpty ? "(Nothing new.)" : body) + "\n</brief>",
                tap: id, paths: noticed.compactMap(\.project)))
        }
    }

    /// Runs the background review now and returns what it found without saying any of it.
    public func reviewNow() async -> [Notice] {
        await initiative.review(await reviewInputs()) ?? []
    }

    /// Waits (up to two minutes) for the manager to finish what it's doing, so the brief gets a
    /// turn, and a reply, of its own.
    private func untilQuiet() async {
        for _ in 0..<60 {
            let busy = await manager.isBusy
            guard replying != nil || busy else { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Everything the background review looks across, gathered now.
    func reviewInputs(scheduleHours: Double = 8) async -> Review.Inputs {
        let now = Date.now
        var inputs = Review.Inputs(now: now)
        inputs.core = await memory.core()
        inputs.goals = Goal.all(in: memory.notebook).filter { $0.status != .done }.map { "- \($0.digest)" }.joined(separator: "\n")
        inputs.openLoops = await openLoops(now: now)
        inputs.schedule = await perception?.schedule(hours: scheduleHours) ?? ""
        inputs.focus = perception?.recentActivity(hours: 3) ?? ""
        inputs.watchers = await initiative.watching()
        inputs.thread = String(threads.transcript(now).suffix(6_000))
        return inputs
    }

    /// Questions waiting on the owner, work in flight or waiting to land, worktrees left behind,
    /// and what's due in the next few hours.
    func openLoops(now: Date) async -> String {
        var lines = attention.map { item in
            "- Waiting on \(Owner.firstName) since \(item.createdAt.formatted(date: .omitted, time: .shortened)): \(item.question)"
                + (item.jobID.map { " (\($0))" } ?? "")
        }
        lines += jobs.filter(\.phase.isOpen).map { "- \($0.digest)" }
        lines += staleWorktrees(now: now).map { "- Worktree left behind: \($0)" }
        lines += await initiative.plans(from: now, until: now.addingTimeInterval(3 * 3600)).map { "- Coming up: \($0)" }
        return lines.joined(separator: "\n")
    }

    /// tilde's worktrees that no open job is using and nobody has touched for a day.
    func staleWorktrees(now: Date) -> [String] {
        let fm = FileManager.default
        let open = Set(jobs.filter(\.phase.isOpen).map { ($0.workdir as NSString).standardizingPath })
        let projects = (try? fm.contentsOfDirectory(atPath: home.worktrees.path)) ?? []
        return projects.sorted().flatMap { project -> [String] in
            let dir = home.worktrees.appending(path: project)
            let trees = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            return trees.compactMap { tree -> String? in
                let modified = (try? tree.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
                guard !open.contains(tree.standardizedFileURL.path), now.timeIntervalSince(modified) > 86_400 else { return nil }
                let owner = jobs.first { ($0.workdir as NSString).standardizingPath == tree.standardizedFileURL.path }
                return "\((tree.path as NSString).abbreviatingWithTildeInPath), untouched \(modified.formatted(.relative(presentation: .named)))"
                    + (owner.map { " (\($0.id) \"\($0.title)\", \($0.phase.rawValue))" } ?? "")
            }
        }
    }
}

extension Job {
    /// One line for the review and the brief.
    var digest: String {
        var line = "\(id) \"\(title)\" in \(projectName): \(phase.rawValue)"
        switch phase {
        case .ready:
            let status = reviewAction == .acknowledge ? "complete, awaiting acknowledgement" : "ready for review"
            line += ", \(status) since \(updatedAt.formatted(.relative(presentation: .named)))"
        case .landed, .failed, .stopped: line += " \(updatedAt.formatted(.relative(presentation: .named)))"
        default: line += ", \(ticker)"
        }
        if let summary, !summary.isEmpty { line += ". \(summary.clipped(to: 200))" }
        return line
    }
}
