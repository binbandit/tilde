/// How to start (or resume) one worker.
public struct WorkerLaunch: Sendable {
    public var workdir: String
    /// The session to resume, or (for harnesses that mint ids) the id to use.
    public var sessionID: String?
    public var resume: Bool
    public var model: String?
    /// The supervision brief every worker gets alongside its task.
    public var instructions: String
    /// Directories outside `workdir` the worker may also write to: the repo's git directory,
    /// so a worktree's commits land. Harnesses that sandbox their workers open these.
    public var writable: [String]

    public init(
        workdir: String, sessionID: String? = nil, resume: Bool = false, model: String? = nil, instructions: String,
        writable: [String] = []
    ) {
        self.workdir = workdir
        self.sessionID = sessionID
        self.resume = resume
        self.model = model
        self.instructions = instructions
        self.writable = writable
    }
}
