import Testing
@testable import TildeBrain

@Suite struct GitHubReadsTests {
    @Test func readsAreAllowed() {
        for args in [
            ["pr", "view", "796", "-R", "binbandit/oh-fx", "--comments"],
            ["search", "prs", "--repo", "binbandit/oh-fx", "--state", "open"],
            ["api", "repos/binbandit/oh-fx/pulls/796/comments"],
            ["api", "repos/binbandit/oh-fx/pulls", "-X", "GET", "--paginate", "--jq", ".[].number"],
            ["api", "graphql", "-f", "query=query { viewer { login } }"],
            ["pr", "list", "--author", "@me"], ["search", "prs", "--review-requested=@me", "--state", "open"],
        ] {
            #expect(GitHubReads.refusal(args) == nil, "\(args)")
        }
    }

    @Test func writesAreRefused() {
        for args in [
            ["pr", "merge", "796"],
            ["pr", "comment", "796", "--body", "hi"],
            ["pr", "view", "796", "--web"],
            ["api", "-X", "POST", "repos/binbandit/oh-fx/issues/1/comments"],
            ["api", "--method=DELETE", "repos/binbandit/oh-fx/git/refs/heads/x"],
            ["api", "repos/binbandit/oh-fx/issues/1/comments", "-f", "body=hi"],
            ["api", "repos/binbandit/oh-fx/issues", "-Ftitle=x"],
            ["api", "graphql", "-f", "query=mutation { addComment(input: {}) { clientMutationId } }"],
            // Ways around a looser filter: another host, a header posing as the endpoint, a query from a file.
            ["api", "--hostname", "example.com", "repos/x/y"],
            ["api", "-H", "graphql", "repos/x/y/issues", "-f", "title=x"],
            ["api", "graphql", "-F", "query=@query.graphql"],
            ["api", "https://example.com/collect"],
            ["pr", "view", "1", "-R", "example.com/x/y"],
            [],
        ] {
            #expect(GitHubReads.refusal(args) != nil, "\(args)")
        }
    }
}
