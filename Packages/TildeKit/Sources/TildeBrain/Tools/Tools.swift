import TildeSupport
import WorkerKit

/// The manager's hands. Each tool returns a short, plain-text result the model can act on.
///
/// Tools are defined by group (delegation, supervision, conversation, GitHub, memory, agenda), one
/// file each; this list is the toolbox and the order the manager sees it in.
extension Conductor {
    func makeTools() -> Toolset {
        Toolset(name: "tilde", instructions: "tilde's orchestration tools.", tools: [
            projectsTool,
            delegateTool,
            steerTool,
            respondTool,
            askTool,
            sayTool,
            finishTool,
            jobsTool,
            stopTool,
            lookTool,
            pullRequestsTool,
            githubTool,
            recallTool,
            rememberTool,
            forgetTool,
            setGoalTool,
            updateGoalTool,
            closeGoalTool,
            goalsTool,
            addToAgendaTool,
            removeFromAgendaTool,
            agendaTool,
        ])
    }
}

extension JSON {
    /// A string parameter in a tool's schema.
    static func text(_ description: String) -> JSON { ["type": "string", "description": .string(description)] }
}
