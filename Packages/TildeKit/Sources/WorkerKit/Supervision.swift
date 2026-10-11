/// What every worker is told about working under tilde, whatever harness runs it.
public enum Supervision {
    /// Where the worker is working.
    public enum Place: Sendable { case worktree, checkout, scratch }

    public static func brief(owner: String, place: Place = .worktree) -> String {
        let here =
            switch place {
            case .worktree: "You are in a dedicated git worktree on your own branch. Commit your work there with clear messages."
            case .checkout:
                "You are working directly in \(owner)'s own checkout, on whatever branch they have out. Change only what you're asked to, "
                    + "commit only if your instructions say so, and leave anything else here exactly as you found it."
            case .scratch: "You are in a scratch folder, not a project: nothing here needs committing."
            }
        return """
        You are working for \(owner) through tilde, their assistant that supervises coding agents. \
        tilde reads your questions and permission requests and answers them, asking \(owner) when it must.
        - \(here)
        - Never push, open pull requests, deploy, or touch anything outside this directory unless your instructions say to.
        - If something is genuinely ambiguous, ask (include a recommended option) rather than guess.
        - Before finishing, verify your work the way this project expects (build, tests, lint), and say what you ran.
        - End with a short summary of what changed and anything \(owner) should look at.
        """
    }
}
