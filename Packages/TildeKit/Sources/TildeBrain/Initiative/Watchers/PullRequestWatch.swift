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

        var label: String { "\(repoName)#\(number)" }
    }

    struct BrokenMain { var repo: String; var branch: String; var oid: String; var title: String; var url: String }

    static let query = """
        query {
          viewer {
            login
            pullRequests(first: 30, states: [OPEN, MERGED], orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { ...pr } }
          }
          requested: search(query: "is:open is:pr review-requested:@me archived:false", type: ISSUE, first: 15) { nodes { ...pr } }
        }
        fragment pr on PullRequest {
          number title url state headRefName mergeable reviewDecision updatedAt mergedAt
          author { login }
          repository { nameWithOwner name defaultBranchRef { name target { ... on Commit { oid statusCheckRollup { state } } } } }
          comments(last: 1) { totalCount nodes { author { login } bodyText } }
          reviewThreads { totalCount }
          commits(last: 1) { nodes { commit { oid statusCheckRollup { state contexts(first: 30) { nodes {
            ... on CheckRun { name conclusion } ... on StatusContext { context state } } } } } } }
        }
        """

    static func fetch() async -> [Pull]? {
        guard let output = try? await Shell.check(["gh", "api", "graphql", "-f", "query=\(query)"]),
            let json = JSON.parse(output), let data = json["data"]
        else { return nil }
        let me = data["viewer"]?["login"]?.string ?? ""
        let mine = (data["viewer"]?["pullRequests"]?["nodes"]?.array ?? []).compactMap { pull($0, me: me, requested: false) }
        let requested = (data["requested"]?["nodes"]?.array ?? []).compactMap { pull($0, me: me, requested: true) }
        return mine + requested.filter { r in !mine.contains { $0.id == r.id } }
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
            merged: node["state"]?.string == "MERGED")
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
