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
        guard resolve(id, answer, by: .tilde) else {
            return .error("Its worker has stopped, or that isn't an answer it takes: a permission takes allow or deny, a question an answer.")
        }
        return .ok("Done.")
    }

    private func toolFinish(_ args: JSON) async -> ToolResult {
        guard let id = args["job"]?.string, job(id) != nil else { return .error("No such job.") }
        let summary = args["summary"]?.string ?? ""
        do {
            // On the job's queue, so no new turn starts while its work is checked and signed off.
            return .ok(try await enqueue(id) { [self] in try await finish(id, summary: summary) }.value)
        } catch {
            return .error("\(error)")
        }
    }

    /// Signs the job off, and says how it went.
    private func finish(_ id: String, summary: String) async throws -> String {
        guard canFinish(id), let job = job(id) else {
            throw ActionRefused(description: "The job must finish a successful turn with no pending questions before sign-off.")
        }
        var diff: DiffStat?
        if job.isolation != .scratch {
            guard let base = job.baseCommit else { throw ActionRefused(description: "The job's change baseline is unknown.") }
            do {
                diff = try await Git.diffStat(workdir: job.workdir, base: base)
            } catch {
                throw ActionRefused(description: "Couldn't verify the job's changes: \(error)")
            }
        }
        // Stopped, exited or asking something by now: not done after all.
        guard canFinish(id) else { throw ActionRefused(description: "The job changed while its completion was being checked.") }
        // With nothing to bring in, it's announced here, and the owner only acknowledges it.
        let complete = job.isolation != .worktree || diff?.isEmpty == true
        let status = complete ? "Complete" : "Ready for review"
        mention(id)
        update(id) {
            $0.phase = .ready
            $0.summary = summary
            $0.diff = diff
            $0.ticker = status
        }
        log.outcome(id, "\(summary)\n\nChanges: \(diff?.label ?? "not a code job")")
        record(id, .tilde, .event, "\(status): \(summary)")
        log.journal("\(job.title) in \(job.projectName): \(status.lowercased()) (\(id))")
        if complete { emit(.said("\(job.title) is complete. \(summary)", jobID: id)) }
        // Its agent can rest, if a message to the job can pick its session back up (otherwise it would
        // start over knowing nothing).
        if job.harness.spec?.resumeCommand != nil { await retire(id)?.stop() }
        await memory.notebook.commitChanges(context: "\(id) complete")
        Task { await scribe.reflect(on: "A job finished. Project: \(job.projectName). Brief: \(job.brief)\nOutcome: \(summary)") }
        return "\(id): \(status.lowercased())." + (complete ? " Completion was announced; there is nothing to bring in." : "")
    }

    /// Its worker's latest turn went well, and nothing it or tilde asked is still open.
    private func canFinish(_ id: String) -> Bool {
        guard let job = job(id), [.deciding, .needsYou].contains(job.phase), job.lastTurn == .succeeded else { return false }
        return !requests.values.contains { $0.job == id } && !attention.contains { $0.jobID == id }
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
