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

/// Which `gh` commands only read. An allowlist: anything it doesn't know is refused.
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
        // Never another host, a browser, a header, or a request body from a file or stdin.
        let banned = ["--hostname", "--web", "-w", "--input", "-H", "--header"]
        if let arg = args.first(where: { arg in banned.contains { arg == $0 || arg.hasPrefix("\($0)=") } }) {
            return "\(arg) isn't allowed: only reading GitHub, from GitHub."
        }
        // `@file` and `@-` read a file or stdin; `@me` is just you.
        if args.contains(where: { ($0.hasPrefix("@") || $0.contains("=@")) && !$0.hasSuffix("@me") }) {
            return "Values can't come from files or stdin."
        }
        // A repo named with a host ([HOST/]OWNER/REPO) would send the request somewhere else.
        for (i, arg) in args.enumerated() where arg == "-R" || arg == "--repo" || arg.hasPrefix("--repo=") {
            let repo = arg.hasPrefix("--repo=") ? String(arg.dropFirst(7)) : args.indices.contains(i + 1) ? args[i + 1] : ""
            if repo.split(separator: "/").count != 2 { return "Name repos as owner/repo." }
        }
        if command == "api" { return apiRefusal(Array(args.dropFirst())) }
        guard let reads = commands[command], let sub = args.dropFirst().first, reads.contains(sub) else {
            return "Only reading commands: " + commands.keys.sorted().map { "\($0) \(commands[$0]!.sorted().joined(separator: "|"))" }
                .joined(separator: ", ") + ", and api (GET, or a graphql query)."
        }
        return nil
    }

    /// `gh api <endpoint>`, then only flags that read: GET, paging and shaping the output, and for
    /// GraphQL the query itself, which mustn't be a mutation.
    private static func apiRefusal(_ args: [String]) -> String? {
        guard let endpoint = args.first, !endpoint.hasPrefix("-") else {
            return "Put the endpoint right after api, e.g. [\"api\", \"repos/owner/repo/pulls/12/comments\"]."
        }
        if endpoint.contains("://") { return "Only GitHub's API, by path." }
        let graphql = endpoint == "graphql"
        let rest = Array(args.dropFirst())
        var i = 0
        while i < rest.count {
            let arg = rest[i], value = rest.indices.contains(i + 1) ? rest[i + 1] : nil
            switch arg {
            case "--paginate", "--slurp", "--include", "-i", "--silent":
                i += 1
            case "--jq", "-q", "--template", "-t", "--cache":
                guard value != nil else { return "\(arg) needs a value." }
                i += 2
            case "-X", "--method":
                guard value?.uppercased() == "GET" else { return "Only GET requests." }
                i += 2
            case "-f", "-F", "--field", "--raw-field":
                guard graphql else { return "Fields turn a request into a write; only a GraphQL query has them." }
                guard let value, !value.localizedCaseInsensitiveContains("mutation") else { return "Only GraphQL queries, no mutations." }
                i += 2
            default:
                return "\(arg) isn't a flag tilde passes to gh api."
            }
        }
        return nil
    }
}
