import Darwin
import Foundation
import WorkerKit

/// The coding agents the owner has running in terminals, found with no setup: what herdr sees in its
/// panes, then the agent CLIs running in any other terminal.
public enum TerminalAgents {
    /// `executables` names each agent CLI's program and its harness. `own` are the sessions tilde's
    /// workers are running right now.
    public static func observe(executables: [String: Harness], own: Set<String> = []) async -> [TerminalAgent] {
        let inHerdr = await Herdr.agents().filter { $0.session.map { !own.contains($0) } ?? true }
        return inHerdr + scan(ProcessTree.snapshot(), executables: executables, root: getpid())
    }

    /// The agents among the processes outside herdr: an interactive process running a known agent CLI.
    /// What runs in a herdr pane is herdr's to report, whatever runs under `root` is tilde and its workers,
    /// and an agent started by another agent (a subagent, or the native binary behind a node wrapper)
    /// is part of that one.
    static func scan(_ tree: ProcessTree, executables: [String: Harness], root: Int32) -> [TerminalAgent] {
        let found = tree.processes.values.compactMap { process in harness(of: process, in: executables).map { (process, $0) } }
        let agents = Set(found.map(\.0.pid))
        return found.sorted { $0.0.pid < $1.0.pid }.compactMap { process, harness in
            let lineage = tree.ancestors(of: process)
            guard process.pid != root, let cwd = process.cwd,
                !lineage.contains(where: { $0.pid == root || agents.contains($0.pid) || $0.program == "herdr" })
            else { return nil }
            return TerminalAgent(harness: harness, cwd: cwd, state: .unknown, place: .terminal(pid: process.pid, app: tree.app(of: process)))
        }
    }

    /// The agent CLI an interactive process is: its program, or the script an interpreter runs (`node gemini`).
    private static func harness(of process: RunningProcess, in executables: [String: Harness]) -> Harness? {
        guard process.interactive else { return nil }
        let names = process.arguments.prefix(2).map { ($0 as NSString).lastPathComponent }
        guard let program = names.first else { return nil }
        if let harness = executables[program] { return harness }
        guard names.count == 2, ["node", "bun", "deno", "python"].contains(where: program.hasPrefix) else { return nil }
        return executables[names[1]]
    }
}
