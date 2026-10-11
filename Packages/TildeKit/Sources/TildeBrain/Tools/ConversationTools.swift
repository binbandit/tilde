import TildeSupport
import WorkerKit

/// Talking with the owner: asking what only they can decide, telling them things, and
/// seeing what they're doing.
extension Conductor {
    var askTool: AgentTool {
        AgentTool(
            "ask",
            "Ask \(Owner.firstName) something only they can decide. Non-blocking: their answer arrives later as <answer>.",
            schema: AgentTool.object([
                "question": .text("One short question."),
                "options": ["type": "array", "items": ["type": "string"], "description": "2 to 4 short options."],
                "recommended": ["type": "integer", "description": "Index of the option you recommend."],
                "detail": .text("Optional: the exact command or context at stake."),
                "job": .text("The job this is about, if any."),
                "request": .text("A worker request id: their answer goes straight to that worker."),
            ], required: ["question", "options"])
        ) { args in await self.toolAsk(args) }
    }

    var sayTool: AgentTool {
        AgentTool(
            "say",
            "Tell \(Owner.firstName) something short (a finished job, a heads-up). Shown as a notification.",
            schema: AgentTool.object(["text": .text("One short line."), "job": .text("Related job id, if any.")], required: ["text"])
        ) { args in await self.toolSay(args) }
    }

    var lookTool: AgentTool {
        AgentTool(
            "look",
            "What \(Owner.firstName) is doing right now (frontmost app, window, terminal directory, recent activity) and what's on their calendar.",
            schema: AgentTool.object([:])
        ) { _ in await self.toolLook() }
    }

    // MARK: Implementations

    private func toolAsk(_ args: JSON) async -> ToolResult {
        guard let question = args["question"]?.string else { return .error("question is required.") }
        let options = (args["options"]?.array ?? []).compactMap(\.string)
        let requestID = args["request"]?.string
        let pending = requestID.flatMap { requests[$0] }
        let jobID = args["job"]?.string ?? pending?.job
        var isApproval = false
        if case .permission = pending?.request.kind { isApproval = true }
        let item = Attention(
            id: IDs.make("a"), jobID: jobID, question: question,
            // A permission is a yes or a no, so its answers are exactly that, whatever labels the manager offered.
            options: isApproval ? ["Allow", "Don't allow"] : options,
            recommended: args["recommended"]?.int, detail: args["detail"]?.string, requestID: pending == nil ? nil : requestID,
            isApproval: isApproval)
        raise(item)
        // Questions about PRs withdraw themselves once the PRs merge or recover.
        await initiative.link(item)
        if let jobID {
            log.append(jobID, "Asked \(Owner.firstName): \(question)")
            record(jobID, .tilde, .request, question)
        }
        return .ok("Asked (\(item.id)). The answer will arrive as <answer to=\"\(item.id)\">\(pending != nil ? " and goes straight to the worker" : "").")
    }

    private func toolSay(_ args: JSON) async -> ToolResult {
        guard let text = args["text"]?.string else { return .error("text is required.") }
        emit(.said(text, jobID: args["job"]?.string))
        return .ok("Said.")
    }

    private func toolLook() async -> ToolResult {
        guard let perception else { return .ok("No live context available.") }
        let context = perception.currentContext()
        let now = context.attributes.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        let schedule = await perception.schedule(hours: 12)
        return .ok("Now:\n\(now.isEmpty ? "(nothing in focus)" : now)\n\nRecently:\n\(perception.recentActivity(hours: 3))"
            + "\n\nComing up:\n\(schedule.isEmpty ? "(nothing on the calendar, or no access)" : schedule)")
    }
}
