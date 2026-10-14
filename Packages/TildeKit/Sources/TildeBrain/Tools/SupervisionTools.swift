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
            schema: AgentTool.object([
                "job": .text("Job id."), "summary": .text("1 to 3 sentences: what changed and anything to check."),
                "repository_revision": .text("Echo the token returned by repository preflight after reading its instructions and reconciling this action."),
            ], required: ["job", "summary"])
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
        guard ["allow", "deny", "answer"].contains(decision) else { return .error("decision must be allow, deny, or answer.") }
        if case .permission = pending.request.kind, decision == "answer" {
            return .error("A permission requires allow or deny; a text answer cannot approve it.")
        }
        if decision == "allow", let reason = approvalBlock(pending.request, job: pending.job) {
            return .error(
                "\(reason) It's \(Owner.firstName)'s to allow. Deny it, or `ask` them, "
                    + "passing request \"\(id)\", with what you'd pick and why.")
        }
        let text = args["text"]?.string ?? ""
        let answer: WorkerAnswer =
            switch decision {
            case "allow": .allow
            case "deny": .deny(text.isEmpty ? "Not allowed." : text)
            default: .reply(text)
            }
        guard resolve(id, answer, by: .tilde) else { return .error("The request cannot be answered: its worker stopped, its job is inactive, or permission is not authorized.") }
        return .ok("Done.")
    }

    private func toolFinish(_ args: JSON) async -> ToolResult {
        guard let id = args["job"]?.string, let job = job(id) else { return .error("No such job.") }
        guard gitGuardFailures[id] == nil, gitCleanups[id] == nil, canFinish(id), let ended = turnEnded[id] else {
            return .error("The job must finish a successful turn with no pending questions before sign-off.")
        }
        let summary = args["summary"]?.string ?? ""
        var diff: DiffStat?
        if job.isolation != .scratch {
            guard let base = job.baseCommit else { return .error("The job's change baseline is unknown.") }
            do {
                diff = try await Git.diffStat(workdir: job.workdir, base: base)
            } catch {
                return .error("Couldn't verify the job's changes: \(error)")
            }
        }
        // Inspection suspends: stop, cancellation, or new feedback invalidates this sign-off.
        guard !Task.isCancelled, canFinish(id), turnEnded[id] == ended else {
            return .error("The job changed while its completion was being checked.")
        }
        let acknowledgement = job.isolation != .worktree || diff?.isEmpty == true
        let status = acknowledgement ? "Complete" : "Ready for review"
        automaticApprovalJobs.remove(id)
        mention(id)
        update(id) {
            $0.phase = .ready
            $0.summary = summary
            $0.diff = diff
            $0.ticker = status
        }
        let signedOffAt = self.job(id)?.updatedAt
        if job.harness.spec?.resumeCommand != nil {
            await stopWorker(id)
        }
        // Stopping a harness can take seconds. New owner feedback during that wait is new work,
        // and must not be followed by a stale completion announcement or outcome record.
        guard gitGuardFailures[id] == nil, deliveriesInFlight[id] == nil,
            self.job(id)?.phase == .ready, self.job(id)?.updatedAt == signedOffAt else {
            return .error("The job received new work while completion was being prepared.")
        }
        guard !Task.isCancelled else {
            update(id) { $0.phase = .stopped; $0.ticker = "Completion interrupted" }
            return .error("Completion was cancelled.")
        }
        log.outcome(id, "\(summary)\n\nChanges: \(diff?.label ?? "not a code job")")
        record(id, .tilde, .event, "\(status): \(summary)")
        log.journal("\(job.title) in \(job.projectName): \(status.lowercased()) (\(id))")
        if acknowledgement { emit(.said("\(job.title) is complete. \(summary)", jobID: id)) }
        await memory.notebook.commitChanges(context: "\(id) complete")
        Task { await scribe.reflect(on: "A job finished. Project: \(job.projectName). Brief: \(job.brief)\nOutcome: \(summary)") }
        return .ok("\(id): \(status.lowercased())." + (acknowledgement ? " Completion was announced; there is nothing to bring in." : ""))
    }

    private func canFinish(_ id: String) -> Bool {
        guard let job = job(id), [.deciding, .needsYou].contains(job.phase), successfulTurns.contains(id),
            deliveriesInFlight[id, default: 0] == 0,
            let ended = turnEnded[id], (handed[id] ?? .distantPast) <= ended else { return false }
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
