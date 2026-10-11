import Harnesses
import TildeSupport
import TildeWork
import WorkerKit

/// Deciding what workers ask, signing off their work, and keeping track of every job.
extension Conductor {
    var respondTool: AgentTool {
        AgentTool(
            "respond",
            "Decide a worker's request (allow/deny) or answer its question.",
            schema: AgentTool.object([
                "request": .text("Request id from <worker-request> or <worker-question>."),
                "decision": ["type": "string", "enum": ["allow", "deny", "answer"]],
                "text": .text("For deny: the reason, shown to the worker. For answer: the answer."),
            ], required: ["request", "decision"])
        ) { args in await self.toolRespond(args) }
    }

    var finishTool: AgentTool {
        AgentTool(
            "finish",
            "Sign off a job as complete and ready for \(Owner.firstName) to review.",
            schema: AgentTool.object(["job": .text("Job id."), "summary": .text("1 to 3 sentences: what changed and anything to check.")], required: ["job", "summary"])
        ) { args in await self.toolFinish(args) }
    }

    var jobsTool: AgentTool {
        AgentTool(
            "jobs",
            "List jobs: open ones plus the last few finished, with status and pending requests.",
            schema: AgentTool.object([:])
        ) { _ in await self.toolJobs() }
    }

    // MARK: Implementations

    private func toolRespond(_ args: JSON) async -> ToolResult {
        guard let id = args["request"]?.string, let decision = args["decision"]?.string else {
            return .error("request and decision are required.")
        }
        guard let pending = requests[id] else { return .error("Request \(id) is no longer open.") }
        if decision == "allow", let rail = unallowedRail(pending.request, job: pending.job) {
            return .error(
                "That crosses a rail (\(rail)), so it's \(Owner.firstName)'s to allow, not yours. Deny it, or `ask` them, "
                    + "passing request \"\(id)\", with what you'd pick and why.")
        }
        let text = args["text"]?.string ?? ""
        let answer: WorkerAnswer =
            switch decision {
            case "allow": .allow
            case "deny": .deny(text.isEmpty ? "Not allowed." : text)
            default: .reply(text)
            }
        resolve(id, answer, by: .tilde)
        return .ok("Done.")
    }

    private func toolFinish(_ args: JSON) async -> ToolResult {
        guard let id = args["job"]?.string, let job = job(id) else { return .error("No such job.") }
        let summary = args["summary"]?.string ?? ""
        var diff = job.diff
        if let base = job.baseCommit { diff = await Git.diffStat(workdir: job.workdir, base: base) }
        mention(id)
        update(id) {
            $0.phase = .ready
            $0.summary = summary
            $0.diff = diff
            $0.ticker = "Ready for review"
        }
        // Its agent can rest (a message to the job picks its session back up), unless it was handed words
        // since its last turn ended, which it may still be working through.
        if (handed[id] ?? .distantPast) <= (turnEnded[id] ?? .distantPast) { await stopWorker(id) }
        log.outcome(id, "\(summary)\n\nChanges: \(diff?.label ?? "unknown")")
        record(id, .tilde, .event, "Ready for review: \(summary)")
        log.journal("\(job.title) in \(job.projectName) is ready for review (\(id))")
        await memory.notebook.commitChanges(context: "\(id) ready")
        Task { await scribe.reflect(on: "A job finished. Project: \(job.projectName). Brief: \(job.brief)\nOutcome: \(summary)") }
        return .ok("\(id) is ready for review.")
    }

    private func toolJobs() async -> ToolResult {
        let recentClosed = jobs.filter { !$0.phase.isOpen }.sorted { $0.updatedAt > $1.updatedAt }.prefix(5)
        let shown = jobs.filter(\.phase.isOpen) + recentClosed
        guard !shown.isEmpty else { return .ok("No jobs.") }
        return .ok(shown.map { job in
            var line = "\(job.id) \"\(job.title)\" in \(job.projectName) (\(job.harness.label)): \(job.phase.rawValue), \(job.ticker)"
            if let diff = job.diff { line += ", \(diff.label)" }
            if let branch = job.branch { line += ", branch \(branch)" }
            if let pr = job.pullRequest { line += ", PR #\(pr.number) \(pr.state.lowercased()) \(pr.url)" }
            line += ", workdir \(job.workdir)"
            let open = attention.filter { $0.jobID == job.id }.map { "waiting on \(Owner.firstName): \($0.question)" }
            if !open.isEmpty { line += "; " + open.joined(separator: "; ") }
            return line
        }.joined(separator: "\n"))
    }
}
