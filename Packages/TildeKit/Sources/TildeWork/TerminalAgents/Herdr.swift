import Foundation
import TildeSupport
import WorkerKit

/// herdr, the terminal workspace manager for coding agents, through its CLI. It knows the agents in
/// its panes and how each is doing, and it's where tilde hands a session back to the owner. Every call
/// goes to the session the owner's shell would use: `HERDR_SESSION`, else the default.
public enum Herdr {
    public enum Failure: Error, CustomStringConvertible {
        case noServer
        case refused(String)

        public var description: String {
            switch self {
            case .noServer: "herdr's server didn't start."
            case .refused(let reason): "herdr said: \(reason)"
            }
        }
    }

    /// On the owner's PATH.
    public static var isInstalled: Bool {
        (try? ChildProcess.resolve("herdr", path: UserEnvironment.shared.variables["PATH"] ?? "")) != nil
    }

    // MARK: Seeing

    /// The agents in herdr's panes: none when herdr isn't installed or its server isn't running.
    static func agents() async -> [TerminalAgent] {
        guard let listed = try? await run(["agent", "list"]), listed.ok else { return [] }
        return agents(from: Data(listed.stdout.utf8))
    }

    /// `herdr agent list`'s answer, leaving out panes with no agent in them.
    static func agents(from json: Data) -> [TerminalAgent] {
        guard let listing = try? decoder.decode(Response<AgentList>.self, from: json) else { return [] }
        return listing.result.agents.compactMap { info in
            guard let kind = info.agent, let cwd = info.foregroundCwd ?? info.cwd else { return nil }
            return TerminalAgent(
                harness: Harness(rawValue: kind), cwd: cwd, state: TerminalAgent.State(rawValue: info.agentStatus) ?? .unknown,
                place: .herdr(pane: info.paneId), name: info.name,
                session: info.agentSession.flatMap { $0.kind == "id" ? $0.value : nil }, changes: info.stateChangeSeq ?? 0)
        }
    }

    // MARK: Showing

    public static func focus(pane: String) async {
        _ = try? await run(["agent", "focus", pane])
    }

    /// The app showing a herdr client of tilde's session, if one is open. Async so the process table
    /// is read off the caller's actor.
    public static func clientApp() async -> String? {
        let tree = ProcessTree.snapshot()
        let session = UserEnvironment.shared.variables["HERDR_SESSION"] ?? "default"
        return tree.processes.values
            .first { $0.interactive && $0.program == "herdr" && attachedSession($0.arguments) == session }
            .flatMap(tree.app(of:))
    }

    /// The session a herdr command line runs a client of: `herdr`, `herdr --session <name>` or
    /// `herdr session attach <name>`. Nil for the server, one-offs like `herdr agent list`, and remotes.
    static func attachedSession(_ arguments: [String]) -> String? {
        var session = "default"
        var rest = arguments.dropFirst()
        while let flag = rest.first, flag.hasPrefix("-") {
            rest = rest.dropFirst()
            switch flag {
            case "--remote", "--machine": return nil
            case "--session":
                session = rest.first ?? session
                rest = rest.dropFirst()
            case "--remote-keybindings": rest = rest.dropFirst()
            default: continue
            }
        }
        if rest.isEmpty { return session }
        return rest.count == 3 && rest.starts(with: ["session", "attach"]) ? rest.last : nil
    }

    // MARK: Taking over

    /// Resumes a session the owner is taking over, in a workspace of its own labelled `label` and opened
    /// at `cwd`, as the agent herdr knows as `name`; when that agent is already running it's brought
    /// forward instead. Waits for the server first, in case a client was just opened to start it.
    public static func resume(_ command: String, in cwd: String, label: String, name: String) async throws {
        try await resume(command, in: cwd, label: label, name: name, environment: UserEnvironment.shared.variables)
    }

    static func resume(_ command: String, in cwd: String, label: String, name: String, environment: [String: String]) async throws {
        // Resume commands are tilde's own (`claude --resume <id>`): a program and plain words.
        let words = command.split(separator: " ").map(String.init)
        guard let program = words.first else { return }
        try await waitForServer(environment: environment)
        if try await run(["agent", "focus", name], environment: environment).ok { return }
        let workspace = try await check(["workspace", "create", "--cwd", cwd, "--label", label, "--focus"], environment: environment)
        let pane = try decoder.decode(Response<WorkspaceCreated>.self, from: Data(workspace.utf8)).result.rootPane.paneId
        let started = try await run(["agent", "start", name, "--kind", program, "--pane", pane, "--"] + words.dropFirst(),
                                    timeout: .seconds(45), environment: environment)
        // herdr turns down an agent kind it doesn't know before running anything (exit 2), so then it's a plain
        // command. Other errors can happen before launch or leave a live agent at a startup prompt.
        if started.status == 2, !started.timedOut {
            try await check(["pane", "run", pane, command], environment: environment)
        } else if !started.ok {
            // Keep a live session in its pane instead of resuming it twice through the terminal fallback.
            let focused = try? await run(["agent", "focus", name], environment: environment)
            guard focused?.ok == true else { throw refusal(started) }
        }
    }

    private static func waitForServer(environment: [String: String]) async throws {
        for _ in 0..<60 {
            if let status = try? await run(["status", "server", "--json"], environment: environment),
                (try? decoder.decode(ServerStatus.self, from: Data(status.stdout.utf8)))?.running == true
            { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure.noServer
    }

    // MARK: The CLI

    @discardableResult
    private static func run(_ arguments: [String], timeout: Duration = .seconds(10),
                            environment: [String: String] = UserEnvironment.shared.variables) async throws -> Shell.Output {
        try await Shell.run(["herdr"] + arguments, environment: environment, timeout: timeout)
    }

    /// Runs a command that has to work, returning what it printed.
    @discardableResult
    private static func check(_ arguments: [String], environment: [String: String] = UserEnvironment.shared.variables) async throws -> String {
        let output = try await run(arguments, environment: environment)
        guard output.ok else { throw refusal(output) }
        return output.stdout
    }

    private static func refusal(_ output: Shell.Output) -> Failure {
        Failure.refused((output.stderr.isEmpty ? output.stdout : output.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private struct Response<Result: Decodable>: Decodable { var result: Result }
    private struct AgentList: Decodable { var agents: [AgentInfo] }
    private struct WorkspaceCreated: Decodable {
        struct Pane: Decodable { var paneId: String }
        var rootPane: Pane
    }
    private struct ServerStatus: Decodable { var running: Bool }

    private struct AgentInfo: Decodable {
        struct Session: Decodable {
            /// `id`, or `path` for agents whose session is a file.
            var kind: String
            var value: String
        }

        var agent: String?
        var agentStatus: String
        var agentSession: Session?
        var cwd: String?
        /// The cwd of what runs in the pane (the agent), rather than of its shell.
        var foregroundCwd: String?
        var paneId: String
        var name: String?
        var stateChangeSeq: Int?
    }
}
