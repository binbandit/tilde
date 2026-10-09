import Foundation
import WorkerKit

/// Claude Code, driven through its own control protocol.
public enum ClaudeHarnesses {
    public static let claude = Harness(rawValue: "claude")

    public static let specs: [HarnessSpec] = [
        HarnessSpec(
            id: claude, label: "Claude Code", executable: "claude",
            strengths: "Default. Strongest at product and UI work, ambiguous tasks, and anything needing judgement or conversation.",
            resumeCommand: { "claude --resume \($0)" }, mintsSessionID: true
        ) { launch in
            ClaudeWorker(
                workdir: launch.workdir, sessionID: launch.sessionID ?? UUID().uuidString.lowercased(), resume: launch.resume,
                model: launch.model, instructions: launch.instructions)
        },
    ]
}
