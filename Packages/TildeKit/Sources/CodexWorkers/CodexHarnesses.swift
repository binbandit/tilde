import WorkerKit

/// Codex, driven through its app-server, and Codex's computer use as a harness of its own.
public enum CodexHarnesses {
    public static let codex = Harness(rawValue: "codex")
    public static let computerUse = Harness(rawValue: "codex-computer")

    public static let specs: [HarnessSpec] = [
        HarnessSpec(
            id: codex, label: "Codex", executable: "codex",
            strengths: "Tightly specified refactors, test writing, and careful mechanical changes. Sandboxed by default.",
            resumeCommand: { "codex resume \($0)" }
        ) { launch in
            CodexWorker(workdir: launch.workdir, threadID: launch.resume ? launch.sessionID : nil, model: launch.model,
                        instructions: launch.instructions, writable: launch.writable)
        },
        HarnessSpec(
            id: computerUse, label: "Codex Computer Use", executable: "codex",
            strengths: "Operates the Mac's apps through the GUI: checking how a change looks or behaves in an app, browser or simulator, clicking through flows, tasks with no CLI or API. Slower, and shares the user's screen while it works.",
            resumeCommand: { "codex resume \($0)" }
        ) { launch in
            CodexWorker(
                workdir: launch.workdir, threadID: launch.resume ? launch.sessionID : nil, model: launch.model,
                instructions: launch.instructions + "\n\n" + ComputerUse.brief, config: ComputerUse.config,
                writable: launch.writable)
        },
    ]
}
