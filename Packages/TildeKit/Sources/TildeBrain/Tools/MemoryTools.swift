import TildeMemory
import TildeSupport
import WorkerKit

/// The notebook on demand: recall beyond the automatic briefing, and remembering or
/// forgetting when the owner asks.
extension Conductor {
    var recallTool: AgentTool {
        AgentTool(
            "recall",
            "Search your notebook (notes, past jobs, journal) for anything relevant.",
            schema: AgentTool.object(["query": .text("What you want to know.")], required: ["query"])
        ) { args in await self.toolRecall(args) }
    }

    var rememberTool: AgentTool {
        AgentTool(
            "remember",
            "Save a lasting fact right away (a preference, correction, alias, project fact).",
            schema: AgentTool.object([
                "about": .text("'me', a project name or path, or a topic."),
                "fact": .text("One standalone sentence."),
                "kind": ["type": "string", "enum": ["me", "project", "topic"]],
                "section": .text("Heading to file it under, e.g. Preferences, Facts, How to build."),
            ], required: ["about", "fact"])
        ) { args in await self.toolRemember(args) }
    }

    var forgetTool: AgentTool {
        AgentTool(
            "forget",
            "Remove a fact from your notebook.",
            schema: AgentTool.object(["about": .text("Who or what it's about."), "fact": .text("The fact, roughly.")], required: ["about", "fact"])
        ) { args in await self.toolForget(args) }
    }

    // MARK: Implementations

    private func toolRecall(_ args: JSON) async -> ToolResult {
        let hits = await memory.recall(args["query"]?.string ?? "")
        guard !hits.isEmpty else { return .ok("Nothing in the notebook about that.") }
        return .ok(hits.map { "[\($0.path) › \($0.heading)]\n\($0.text)" }.joined(separator: "\n\n"))
    }

    private func toolRemember(_ args: JSON) async -> ToolResult {
        guard let about = args["about"]?.string, let fact = args["fact"]?.string else { return .error("about and fact are required.") }
        do {
            let written = try await memory.remember(
                fact, about: about, kind: args["kind"]?.string.flatMap(Memory.Kind.init),
                section: args["section"]?.string ?? "Facts", source: "told")
            emit(.noted([written]))
            // Told mid-conversation, it shows under the reply.
            if replying != nil { appendNoted(written.fact) }
            return .ok(written.replaced.map { "Updated \(written.path) (replaced: \($0))." } ?? "Saved to \(written.path).")
        } catch {
            return .error("\(error)")
        }
    }

    private func toolForget(_ args: JSON) async -> ToolResult {
        guard let about = args["about"]?.string, let fact = args["fact"]?.string else { return .error("about and fact are required.") }
        let removed = try? await memory.forget(fact, about: about)
        return .ok(removed.map { "Forgot: \($0)" } ?? "Nothing matching to forget.")
    }
}
