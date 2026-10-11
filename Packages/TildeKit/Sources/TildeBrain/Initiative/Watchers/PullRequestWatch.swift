import Foundation
import TildeSupport

/// Reads PR state from GitHub through the user's `gh` login. Read-only.
enum PullRequestWatch {
    struct Pull: Sendable {
        var id: String
        var repo: String
        var repoName: String
        var number: Int
        var title: String
        var url: String
        var branch: String
        var headOID: String
        var author: String
        var isMine: Bool
        var reviewRequested: Bool
        var checks: String?
        var failingChecks: [String]
        var review: String?
        var mergeable: String?
        /// Comments plus review threads: grows when someone says something.
        var conversation: Int
        var lastComment: String?
        var lastCommentIsMine: Bool
        var defaultBranch: String?
        var defaultBranchChecks: String?
        var defaultBranchOID: String?
        var merged: Bool
        /// Closed without merging.
        var closed = false
        /// A bot opened it (dependabot, renovate, github-actions, any `[bot]`).
        var authorIsBot = false
        /// The last comment is a bot's (a merge queue's status, a CI summary).
        var lastCommentIsBot = false
        var updatedAt: Date?
        var mergedAt: Date?

        var label: String { "\(repoName)#\(number)" }
    }

    struct BrokenMain { var repo: String; var branch: String; var oid: String; var title: String; var url: String }

    /// Open and merged PRs are separate connections: a busy merger's recent merges would
    /// otherwise crowd the open ones out of a single list.
    static let query = """
        query {
          viewer {
            login
            open: pullRequests(first: 30, states: [OPEN], orderBy: {field: UPDATED_AT, direction: DESC}) { totalCount nodes { ...pr } }
            merged: pullRequests(first: 15, states: [MERGED], orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { ...pr } }
          }
          requested: search(query: "is:open is:pr review-requested:@me archived:false", type: ISSUE, first: 15) { nodes { ...pr } }
        }
        """ + fragment

    static let fragment = """
        fragment pr on PullRequest {
          number title url state headRefName mergeable reviewDecision updatedAt mergedAt
          author { login __typename }
          repository { nameWithOwner name defaultBranchRef { name target { ... on Commit { oid statusCheckRollup { state } } } } }
          comments(last: 1) { totalCount nodes { author { login __typename } bodyText } }
          reviewThreads { totalCount }
          commits(last: 1) { nodes { commit { oid statusCheckRollup { state contexts(first: 30) { nodes {
            ... on CheckRun { name conclusion } ... on StatusContext { context state } } } } } } }
        }
        """

    static func fetch() async -> (pulls: [Pull], open: Int)? {
        guard let output = await graphql(query), let pulls = pulls(from: output) else { return nil }
        return (pulls, output["data"]?["viewer"]?["open"]?["totalCount"]?.int ?? pulls.count { $0.isMine && !$0.merged })
    }

    /// One PR by id (`owner/repo#12`), wherever it stands: for the ones that dropped off the lists above.
    static func fetch(_ id: String) async -> Pull? {
        guard let match = id.firstMatch(of: /^([^\/]+)\/([^#]+)#(\d+)$/) else { return nil }
        let query = "query { viewer { login } repository(owner: \"\(match.1)\", name: \"\(match.2)\") "
            + "{ pullRequest(number: \(match.3)) { ...pr } } }\n" + fragment
        guard let json = await graphql(query), let node = json["data"]?["repository"]?["pullRequest"]
        else { return nil }
        return pull(node, me: json["data"]?["viewer"]?["login"]?.string ?? "", requested: false)
    }

    /// One GraphQL read, given up on after 45 seconds: a hung `gh` mustn't stall everything that waits on the watchers.
    private static func graphql(_ query: String) async -> JSON? {
        guard let output = try? await Shell.run(["gh", "api", "graphql", "-f", "query=\(query)"], timeout: .seconds(45)), output.ok
        else { return nil }
        return JSON.parse(output.stdout)
    }

    /// Your open PRs, the ones you merged in the last day, and PRs waiting on your review.
    static func pulls(from json: JSON, now: Date = .now) -> [Pull]? {
        guard let data = json["data"], let viewer = data["viewer"] else { return nil }
        let me = viewer["login"]?.string ?? ""
        let nodes = { (connection: JSON?) in connection?["nodes"]?.array ?? [] }
        let open = nodes(viewer["open"]).compactMap { pull($0, me: me, requested: false) }
        let merged = nodes(viewer["merged"]).compactMap { pull($0, me: me, requested: false) }
            .filter { $0.merged && ($0.mergedAt.map { now.timeIntervalSince($0) < 86_400 } ?? false) }
        let requested = nodes(data["requested"]).compactMap { pull($0, me: me, requested: true) }
        return open + merged + requested.filter { r in !open.contains { $0.id == r.id } }
    }

    static func isBot(login: String, type: String?) -> Bool {
        if type == "Bot" { return true }
        let name = login.lowercased().replacingOccurrences(of: "app/", with: "")
        return name.hasSuffix("[bot]") || ["dependabot", "dependabot-preview", "renovate", "renovate-bot", "github-actions"].contains(name)
    }

    private static func pull(_ node: JSON, me: String, requested: Bool) -> Pull? {
        guard let number = node["number"]?.int, let repo = node["repository"]?["nameWithOwner"]?.string else { return nil }
        let commit = node["commits"]?["nodes"]?[0]?["commit"]
        let contexts = commit?["statusCheckRollup"]?["contexts"]?["nodes"]?.array ?? []
        let failing = contexts.compactMap { context -> String? in
            let verdict = context["conclusion"]?.string ?? context["state"]?.string ?? ""
            return ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED"].contains(verdict) ? (context["name"]?.string ?? context["context"]?.string) : nil
        }
        let lastComment = node["comments"]?["nodes"]?[0]
        let author = node["author"]?["login"]?.string ?? ""
        let defaultTarget = node["repository"]?["defaultBranchRef"]?["target"]
        return Pull(
            id: "\(repo)#\(number)", repo: repo, repoName: node["repository"]?["name"]?.string ?? repo, number: number,
            title: node["title"]?.string ?? "", url: node["url"]?.string ?? "", branch: node["headRefName"]?.string ?? "",
            headOID: String((commit?["oid"]?.string ?? "").prefix(10)), author: author, isMine: author == me && !requested,
            reviewRequested: requested, checks: commit?["statusCheckRollup"]?["state"]?.string, failingChecks: failing,
            review: node["reviewDecision"]?.string, mergeable: node["mergeable"]?.string,
            conversation: (node["comments"]?["totalCount"]?.int ?? 0) + (node["reviewThreads"]?["totalCount"]?.int ?? 0),
            lastComment: lastComment?["bodyText"]?.string.map { $0.clipped(to: 160) },
            lastCommentIsMine: lastComment?["author"]?["login"]?.string == me,
            defaultBranch: node["repository"]?["defaultBranchRef"]?["name"]?.string,
            defaultBranchChecks: defaultTarget?["statusCheckRollup"]?["state"]?.string,
            defaultBranchOID: defaultTarget?["oid"]?.string.map { String($0.prefix(10)) },
            merged: node["state"]?.string == "MERGED", closed: node["state"]?.string == "CLOSED",
            authorIsBot: isBot(login: author, type: node["author"]?["__typename"]?.string),
            lastCommentIsBot: isBot(
                login: lastComment?["author"]?["login"]?.string ?? "", type: lastComment?["author"]?["__typename"]?.string),
            updatedAt: node["updatedAt"]?.string.flatMap { try? Date($0, strategy: .iso8601) },
            mergedAt: node["mergedAt"]?.string.flatMap { try? Date($0, strategy: .iso8601) })
    }

    /// Default branches failing after one of your merges in the last day.
    static func brokenMains(_ pulls: [Pull]) -> [BrokenMain] {
        var seen = Set<String>()
        return pulls.compactMap { pull in
            guard pull.isMine, pull.merged, pull.defaultBranchChecks == "FAILURE", let branch = pull.defaultBranch,
                let oid = pull.defaultBranchOID, seen.insert(pull.repo).inserted
            else { return nil }
            return BrokenMain(repo: pull.repoName, branch: branch, oid: oid, title: pull.title, url: pull.url)
        }
    }
}

extension PullRequestWatch.Pull {
    /// What's wrong with it that someone could fix.
    enum Trouble: String, Codable, Sendable { case checks, conflict, changes }

    /// A check that's a gate waiting on a person (an approval, a merge protection), not code that's broken.
    static func isGate(_ check: String) -> Bool {
        check.range(of: "approv|merge protection|mergify|merge queue|required review|codeowner", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Checks failing for a reason a change could fix: not just gates waiting on someone's approval.
    var checksFailing: Bool {
        ["FAILURE", "ERROR"].contains(checks) && (failingChecks.isEmpty || failingChecks.contains { !Self.isGate($0) })
    }

    var troubles: Set<Trouble> {
        var troubles: Set<Trouble> = []
        if checksFailing { troubles.insert(.checks) }
        if mergeable == "CONFLICTING" { troubles.insert(.conflict) }
        if review == "CHANGES_REQUESTED" { troubles.insert(.changes) }
        return troubles
    }

    /// Whether a trouble is over, not just quiet: checks that are running again haven't passed yet.
    func isPast(_ trouble: Trouble) -> Bool {
        switch trouble {
        case .checks: !checksFailing && checks != "PENDING" && checks != "EXPECTED"
        case .conflict: mergeable == "MERGEABLE"
        case .changes: review != "CHANGES_REQUESTED"
        }
    }

    /// Where it stands, plainly: "merged", or "checks failing (lint), changes requested, conflicts".
    var standing: String {
        if merged {
            return defaultBranchChecks == "FAILURE" ? "merged, and \(defaultBranch ?? "the default branch") is failing since" : "merged"
        }
        var parts: [String] = []
        switch checks {
        case "FAILURE", "ERROR":
            let broken = failingChecks.filter { !Self.isGate($0) }
            if checksFailing {
                parts.append("checks failing" + (broken.isEmpty ? "" : " (\(broken.prefix(3).joined(separator: ", ")))"))
            } else {
                parts.append("waiting on approval checks (\(failingChecks.prefix(3).joined(separator: ", ")))")
            }
        case "PENDING", "EXPECTED": parts.append("checks running")
        case "SUCCESS": parts.append("checks green")
        default: break
        }
        switch review {
        case "APPROVED": parts.append("approved")
        case "CHANGES_REQUESTED": parts.append("changes requested")
        case "REVIEW_REQUIRED": parts.append("awaiting review")
        default: break
        }
        if mergeable == "CONFLICTING" { parts.append("conflicts with its base") }
        if let lastComment, !lastCommentIsMine { parts.append("last comment: \"\(lastComment.clipped(to: 100))\"") }
        return parts.isEmpty ? "open" : parts.joined(separator: ", ")
    }

    /// One bullet for the review and the brief.
    var line: String {
        var line = "- \(label) \"\(title)\""
        if !isMine { line += " by \(author)\(authorIsBot ? " (a bot)" : "")" }
        line += ": \(standing)"
        if let updatedAt { line += ", updated \(updatedAt.formatted(.relative(presentation: .named)))" }
        return line + " \(url)"
    }
}
