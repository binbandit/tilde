import Harnesses
import TildeWork

extension Job {
    /// The command that reopens this job's agent session in a terminal.
    public var takeOverCommand: String? {
        guard let sessionID else { return nil }
        return harness.spec?.resumeCommand?(sessionID)
    }
}
