import Foundation
import Harnesses
import TildeSupport
import TildeWork
import WorkerKit

/// Finding the project, starting workers, and steering or stopping them.
extension Conductor {
    var projectsTool: AgentTool {
        AgentTool(
            "projects",
            "Find git repos on this Mac by name, alias or stack. Returns paths, stacks and recency.",
            schema: AgentTool.object(["query": .text("Words to match, e.g. 'paradise'. Empty for most recent.")], required: ["query"])
        ) { args in await self.toolProjects(args) }
    }

    var delegateTool: AgentTool {
        AgentTool(
            "delegate",
            "Start a worker. With a project it works in its own git worktree; without one (GUI work, research) it gets a scratch folder. Returns the job id.",
            schema: AgentTool.object([
                "project_path": .text("Absolute path of the project's git repo. Omit for work that isn't about a repo."),
                "title": .text("2 to 5 words naming the job the way a person would, e.g. 'Navigation bar', 'oh-fx#799 conflicts'. Not 'Fix PRs 796 799'."),
                "brief": .text("The full brief for the worker."),
                "harness": [
                    "type": "string", "enum": .array(HarnessCatalog.installed().map { .string($0.id.rawValue) }),
                    "description": "Which installed harness runs it. Default claude.",
                ],
                "model": .text("Only when a specific model is wanted: its name as the harness knows it. Omit for the harness's default."),
                "in_place": ["type": "boolean", "description": "Work directly in the checkout instead of a worktree. Only when asked."],
            ], required: ["title", "brief"])
        ) { args in await self.toolDelegate(args) }
    }

    var steerTool: AgentTool {
        AgentTool(
            "steer",
            "Send a follow-up instruction or feedback to a job's worker.",
            schema: AgentTool.object(["job": .text("Job id."), "message": .text("What to tell the worker.")], required: ["job", "message"])
        ) { args in await self.toolSteer(args) }
    }

    var stopTool: AgentTool {
        AgentTool(
            "stop",
            "Stop a job's worker.",
            schema: AgentTool.object(["job": .text("Job id.")], required: ["job"])
        ) { args in await self.toolStop(args) }
    }

    // MARK: Implementations

    private func toolProjects(_ args: JSON) async -> ToolResult {
        let found = await projects.search(args["query"]?.string ?? "")
        guard !found.isEmpty else { return .ok("No matching repos under \(ProjectIndex.defaultRoots.joined(separator: ", ")).") }
        return .ok(found.map { p in
            "\(p.name)  \(p.path)\(p.remotes.isEmpty ? "" : "  (remotes \(p.remotes.joined(separator: ", ")))")  [\(p.stack.joined(separator: ", "))]  active \(p.lastActive.formatted(.relative(presentation: .named)))"
        }.joined(separator: "\n"))
    }

    private func toolDelegate(_ args: JSON) async -> ToolResult {
        guard let brief = args["brief"]?.string, !brief.isEmpty else { return .error("brief is required.") }
        let path = args["project_path"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let title = args["title"]?.string ?? brief.clipped(to: 32)
        let harness = args["harness"]?.string.map(Harness.init) ?? .claude
        guard let spec = harness.spec, spec.isInstalled else {
            return .error("\(harness) isn't available. Installed: \(HarnessCatalog.installed().map(\.id.rawValue).joined(separator: ", ")).")
        }
        let model = args["model"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let inPlace = args["in_place"]?.bool ?? false
        do {
            let id = IDs.make("j")
            var job: Job
            guard let path else {
                let workdir = home.scratch.appending(path: id).path
                try FileManager.default.createDirectory(atPath: workdir, withIntermediateDirectories: true)
                job = Job(id: id, title: title, brief: brief, projectName: "No project", repoPath: workdir, workdir: workdir,
                          harness: harness, isolation: .scratch)
                job.model = model
                return try await launch(job, spec: spec, brief: brief, place: "a scratch folder (\(workdir))")
            }
            let repo = try await Git.root(of: (path as NSString).expandingTildeInPath)
            let projectName = (repo as NSString).lastPathComponent
            if inPlace {
                job = Job(id: id, title: title, brief: brief, projectName: projectName, repoPath: repo, workdir: repo,
                          harness: harness, isolation: .inPlace)
                job.baseCommit = try await Git.head(repo)
                job.baseBranch = try await Git.currentBranch(repo)
            } else {
                let slug = IDs.slug(title)
                let branch = await Git.freeBranch(repo: repo, slug: slug)
                let workdir = home.worktrees.appending(path: projectName).appending(path: branch.replacingOccurrences(of: "tilde/", with: "")).path
                let (base, commit) = try await Git.addWorktree(repo: repo, path: workdir, branch: branch)
                job = Job(id: id, title: title, brief: brief, projectName: projectName, repoPath: repo, workdir: workdir,
                          harness: harness, isolation: .worktree)
                job.branch = branch
                job.baseBranch = base
                job.baseCommit = commit
            }
            job.model = model
            let place = job.branch.map { "a worktree on \($0) (\(job.workdir))" } ?? "the checkout at \(repo)"
            return try await launch(job, spec: spec, brief: brief, place: place)
        } catch {
            return .error("Couldn't start the job: \(error)")
        }
    }

    private func launch(_ job: Job, spec: HarnessSpec, brief: String, place: String) async throws -> ToolResult {
        var job = job
        if spec.mintsSessionID { job.sessionID = UUID().uuidString.lowercased() }
        addJob(job)
        mention(job.id)
        log.open(job)
        record(job.id, .tilde, .message, brief)
        log.journal("Started \(job.title) in \(job.projectName) with \(spec.label) (\(job.id))")
        try await spawn(job, brief: brief, resume: false)
        return .ok("Started \(job.id) with \(spec.label) in \(place).")
    }

    private func toolSteer(_ args: JSON) async -> ToolResult {
        guard let id = args["job"]?.string, let message = args["message"]?.string else { return .error("job and message are required.") }
        guard job(id) != nil else { return .error("No job \(id).") }
        do {
            try await deliver(message, to: id, from: .tilde)
            mention(id)
            log.append(id, "Steered: \(message)")
            return .ok("Sent to \(id).")
        } catch {
            return .error("Couldn't reach the worker: \(error)")
        }
    }

    private func toolStop(_ args: JSON) async -> ToolResult {
        guard let id = args["job"]?.string, job(id) != nil else { return .error("No such job.") }
        await stopWorker(id)
        update(id) { $0.phase = .stopped; $0.ticker = "Stopped" }
        record(id, .tilde, .event, "Stopped")
        log.append(id, "Stopped by the manager")
        return .ok("Stopped \(id).")
    }
}
