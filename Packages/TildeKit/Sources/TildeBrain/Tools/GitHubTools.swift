import Foundation
import TildeSupport
import WorkerKit

/// Reading GitHub for the manager, whose own shell has no network: what tilde already watches,
/// instantly, and live read-only `gh` for the rest. Nothing here can change anything on GitHub;
/// that stays with workers, behind the rails.
extension Conductor {
    var pullRequestsTool: AgentTool {
        AgentTool(
            "pull_requests",
            "\(Owner.firstName)'s open PRs (the 30 most recently updated), the ones merged in the last day, and PRs waiting on "
                + "their review, with checks, reviews and conflicts, as of tilde's last look at GitHub (a few minutes ago at most). "
                + "Instant: try it first for anything about PRs.",
            schema: AgentTool.object([:])
        ) { _ in await self.toolPullRequests() }
    }

    var githubTool: AgentTool {
        AgentTool(
            "github",
            "Runs a read-only `gh` command and returns its output, for anything `pull_requests` doesn't cover: "
                + "[\"pr\", \"view\", \"796\", \"-R\", \"owner/repo\", \"--comments\"], "
                + "[\"search\", \"prs\", \"--repo\", \"owner/repo\", \"--state\", \"open\"], [\"api\", \"repos/owner/repo/pulls/796/comments\"]. "
                + "Reading only: anything that would change GitHub is refused.",
            schema: AgentTool.object(
                ["args": ["type": "array", "items": ["type": "string"], "description": "The arguments after `gh`."]],
                required: ["args"])
        ) { args in await self.toolGitHub(args) }
    }

    private func toolPullRequests() async -> ToolResult {
        let watching = await initiative.watchingNow()
        return .ok(watching.isEmpty ? "Nothing yet: tilde hasn't reached GitHub this session. Try `github`." : watching)
    }

    private func toolGitHub(_ args: JSON) async -> ToolResult {
        let argv = (args["args"]?.array ?? []).compactMap(\.string)
        if let refusal = GitHubReads.refusal(argv) { return .error(refusal) }
        guard let output = try? await Shell.run(["gh"] + argv, timeout: .seconds(30)) else {
            return .error("Couldn't run gh.")
        }
        if output.timedOut { return .error("GitHub didn't answer within 30 seconds.") }
        let text = (output.ok ? output.stdout : output.stderr + output.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.ok ? .ok(text.isEmpty ? "(no output)" : text.clipped(to: 20_000, keepLines: true)) : .error(text.clipped(to: 2_000))
    }
}

/// Which `gh` commands only read.
enum GitHubReads {
    static let commands: [String: Set<String>] = [
        "pr": ["view", "list", "checks", "diff", "status"],
        "issue": ["view", "list", "status"],
        "search": ["prs", "issues", "repos", "commits", "code"],
        "run": ["view", "list"],
        "workflow": ["view", "list"],
        "repo": ["view", "list"],
        "release": ["view", "list"],
    ]

    /// Why `gh <args>` isn't allowed, or nil when it only reads.
    static func refusal(_ args: [String]) -> String? {
        guard let command = args.first else { return "Say what to run, e.g. [\"pr\", \"list\"]." }
        if args.contains(where: { ["--web", "-w"].contains($0) }) { return "Opening a browser isn't reading." }
        if command == "api" { return apiRefusal(Array(args.dropFirst())) }
        guard let reads = commands[command], let sub = args.dropFirst().first, reads.contains(sub) else {
            return "Only reading commands: " + commands.keys.sorted().map { "\($0) \(commands[$0]!.sorted().joined(separator: "|"))" }
                .joined(separator: ", ") + ", and api (GET, or a graphql query)."
        }
        return nil
    }

    /// `gh api` reads with GET; GraphQL is sent as POST but only reads when it holds no mutation.
    private static func apiRefusal(_ args: [String]) -> String? {
        let endpoint = args.first { !$0.hasPrefix("-") }
        for (i, arg) in args.enumerated() {
            let method: String? =
                if arg == "-X" || arg == "--method" { args.dropFirst(i + 1).first }
                else if arg.hasPrefix("--method=") { String(arg.dropFirst(9)) }
                else if arg.hasPrefix("-X") { String(arg.dropFirst(2)) }
                else { nil }
            if let method, method.uppercased() != "GET" { return "Only GET requests." }
        }
        let sendsFields = args.contains { arg in
            ["-f", "-F", "--field", "--raw-field", "--input"].contains(arg)
                || ["--field=", "--raw-field=", "--input="].contains { arg.hasPrefix($0) }
                || (arg.count > 2 && (arg.hasPrefix("-f") || arg.hasPrefix("-F")))
        }
        if endpoint == "graphql" {
            return args.contains { $0.localizedCaseInsensitiveContains("mutation") } ? "Only GraphQL queries, no mutations." : nil
        }
        return sendsFields ? "Fields turn a request into a write; only GET requests." : nil
    }
}
