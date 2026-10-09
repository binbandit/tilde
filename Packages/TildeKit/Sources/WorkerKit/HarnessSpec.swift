import TildeSupport

/// Everything tilde needs to run a harness as a supervised worker.
public struct HarnessSpec: Sendable {
    public var id: Harness
    /// User-facing name ("Gemini CLI").
    public var label: String
    /// The binary tilde looks for on the user's PATH.
    public var executable: String
    /// One line for the manager: what this harness is good at, so it can choose.
    public var strengths: String
    /// The terminal command that reopens a session, for "take over".
    public var resumeCommand: (@Sendable (_ sessionID: String) -> String)?
    /// Whether tilde mints the session id before launch (Claude Code) rather than
    /// learning it from the harness once it starts.
    public var mintsSessionID = false
    public var make: @Sendable (WorkerLaunch) -> any Worker

    public init(
        id: Harness, label: String, executable: String, strengths: String,
        resumeCommand: (@Sendable (String) -> String)? = nil, mintsSessionID: Bool = false,
        make: @escaping @Sendable (WorkerLaunch) -> any Worker
    ) {
        self.id = id
        self.label = label
        self.executable = executable
        self.strengths = strengths
        self.resumeCommand = resumeCommand
        self.mintsSessionID = mintsSessionID
        self.make = make
    }

    /// Installed on this Mac (found on the user's login-shell PATH).
    public var isInstalled: Bool {
        (try? ChildProcess.resolve(executable, path: UserEnvironment.shared.variables["PATH"] ?? "")) != nil
    }
}
