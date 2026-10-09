import Foundation
import TildeSupport
import WorkerKit

/// Harnesses whose best machine interface is a headless JSON stream rather than ACP,
/// each run by `StreamWorker` with its own dialect. See docs/harnesses/stream.md.
public enum StreamHarnesses {
    public static let specs: [HarnessSpec] = [
        HarnessSpec(
            id: Harness(rawValue: "amp"), label: "Amp", executable: "amp",
            strengths: "Sourcegraph's agent with oracle and librarian subagents: strong at deep debugging, unfamiliar code, and large multi-file changes.",
            resumeCommand: { "amp threads continue \($0)" }
        ) { launch in
            StreamWorker(
                AmpDialect(userSettings: AmpDialect.userSettings(in: UserEnvironment.shared.variables)), launch: launch,
                executable: "amp")
        },
        HarnessSpec(
            id: Harness(rawValue: "pi"), label: "Pi", executable: "pi",
            strengths: "Minimal, fast agent on whichever model provider the user has set up: good for focused, well-specified changes or a specific model.",
            resumeCommand: { "pi --session \($0)" }, mintsSessionID: true
        ) { launch in
            var launch = launch
            launch.sessionID = launch.sessionID ?? UUID().uuidString.lowercased()
            return StreamWorker(PiDialect(), launch: launch, executable: "pi")
        },
    ]
}
