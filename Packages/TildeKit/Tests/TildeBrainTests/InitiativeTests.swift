import Foundation
import Testing
import TildeSupport
import TildeWork
@testable import TildeBrain

@Suite struct InitiativeTests {
    let home = TildeHome(root: FileManager.default.temporaryDirectory.appending(path: "tilde-initiative-\(UUID().uuidString)"))

    func initiative() throws -> Initiative {
        try home.prepare()
        return Initiative(home: home)
    }

    func notice(_ key: String, _ urgency: Notice.Urgency, subject: String? = nil) -> Notice {
        Notice(key: key, subject: subject ?? key, urgency: urgency, summary: key, url: nil, project: nil, suggestion: nil)
    }

    @Test func urgentNewsInterruptsEvenMidTyping() async throws {
        let due = try await initiative().due([notice("main-red", .now)], typing: true, looking: false)
        #expect(due.map(\.key) == ["main-red"])
    }

    @Test func softNewsWaitsForABreakAndFYIWaitsForALook() async throws {
        let initiative = try initiative()
        #expect(await initiative.due([notice("ci", .soon), notice("ready", .fyi)], typing: true, looking: false).isEmpty)
        #expect(await initiative.due([], typing: false, looking: false).map(\.key) == ["ci"])
        #expect(await initiative.due([], typing: false, looking: true).map(\.key) == ["ready"])
    }

    @Test func neverSaysTheSameThingTwice() async throws {
        let initiative = try initiative()
        #expect(await initiative.due([notice("ci", .soon)], typing: false, looking: false).count == 1)
        #expect(await initiative.due([notice("ci", .soon)], typing: false, looking: false).isEmpty)
    }

    @Test func coolsDownPerSubject() async throws {
        let initiative = try initiative()
        _ = await initiative.due([notice("pr:checks", .soon, subject: "pr")], typing: false, looking: false)
        #expect(await initiative.due([notice("pr:comment", .soon, subject: "pr")], typing: false, looking: false).isEmpty)
    }

    @Test func capsInterruptionsPerHour() async throws {
        let initiative = try initiative()
        for i in 0..<4 { _ = await initiative.due([notice("n\(i)", .soon)], typing: false, looking: false) }
        #expect(await initiative.due([notice("n5", .soon)], typing: false, looking: false).isEmpty)
        #expect(await initiative.due([notice("urgent", .now)], typing: false, looking: false).count == 1)
    }

    func pull(checks: String? = "SUCCESS", review: String? = nil, mergeable: String? = "MERGEABLE", conversation: Int = 0,
              comment: String? = nil, mine: Bool = true, oid: String = "abc") -> PullRequestWatch.Pull {
        PullRequestWatch.Pull(
            id: "me/app#7", repo: "me/app", repoName: "app", number: 7, title: "Nav bar", url: "https://x/7", branch: "nav",
            headOID: oid, author: "me", isMine: mine, reviewRequested: false, checks: checks, failingChecks: ["lint"],
            review: review, mergeable: mergeable, conversation: conversation, lastComment: comment, lastCommentIsMine: false,
            defaultBranch: "main", defaultBranchChecks: "SUCCESS", defaultBranchOID: "def", merged: false)
    }

    @Test func noticesPullRequestTransitionsNotStates() async throws {
        let initiative = try initiative()
        #expect(await initiative.transitions([pull()]).isEmpty)  // first sighting just learns the state
        #expect(await initiative.transitions([pull()]).isEmpty)  // nothing changed

        let failed = await initiative.transitions([pull(checks: "FAILURE", oid: "def")])
        #expect(failed.count == 1 && failed[0].summary.contains("lint") && failed[0].suggestion?.contains("nav") == true)

        let reviewed = await initiative.transitions([pull(checks: "FAILURE", review: "CHANGES_REQUESTED", conversation: 2, comment: "Use the shared Button.", oid: "def")])
        #expect(reviewed.map(\.urgency) == [.now])
        #expect(reviewed[0].summary.contains("shared Button"))

        let green = await initiative.transitions([pull(checks: "SUCCESS", review: "APPROVED", conversation: 2, oid: "ghi")])
        #expect(green.contains { $0.summary.contains("approved and green") })
    }

    @Test func reviewRequestsFromBotsWaitUntilYouLook() async throws {
        let initiative = try initiative()
        var bump = pull(mine: false)
        bump.id = "me/app#8"
        bump.author = "dependabot"
        bump.authorIsBot = true
        bump.reviewRequested = true
        var human = pull(mine: false)
        human.author = "sam"
        human.reviewRequested = true
        let requests = await initiative.transitions([bump, human]).filter { $0.key.hasSuffix(":review-requested") }
        #expect(requests.map(\.urgency) == [.fyi, .soon])
    }

    @Test func recognisesBotAuthors() {
        #expect(PullRequestWatch.isBot(login: "dependabot", type: "Bot"))
        #expect(PullRequestWatch.isBot(login: "renovate[bot]", type: nil))
        #expect(PullRequestWatch.isBot(login: "app/github-actions", type: nil))
        #expect(PullRequestWatch.isBot(login: "acme-release", type: "Bot"))
        #expect(!PullRequestWatch.isBot(login: "sam", type: "User"))
    }

    /// A GraphQL PR node as `gh api graphql` returns it.
    func node(_ number: Int, state: String = "OPEN", author: String = "me", type: String = "User", merged: String? = nil, main: String = "SUCCESS") -> JSON {
        [
            "number": .number(Double(number)), "title": .string("PR \(number)"), "url": .string("https://github.com/me/app/pull/\(number)"),
            "state": .string(state), "headRefName": .string("branch-\(number)"), "mergeable": "MERGEABLE", "reviewDecision": nil,
            "updatedAt": "2026-10-09T08:00:00Z", "mergedAt": merged.map(JSON.string) ?? .null,
            "author": ["login": .string(author), "__typename": .string(type)],
            "repository": [
                "nameWithOwner": "me/app", "name": "app",
                "defaultBranchRef": ["name": "main", "target": ["oid": "mainsha", "statusCheckRollup": ["state": .string(main)]]],
            ],
            "comments": ["totalCount": 0, "nodes": []], "reviewThreads": ["totalCount": 0],
            "commits": ["nodes": [["commit": ["oid": .string("head\(number)"), "statusCheckRollup": ["state": "FAILURE", "contexts": ["nodes": []]]]]]],
        ]
    }

    @Test func readsOpenAndMergedPullRequestsSeparately() throws {
        // However many merges there are, they come in their own list and can't push the open PR out.
        let json: JSON = ["data": [
            "viewer": [
                "login": "me",
                "open": ["nodes": [node(7)]],
                "merged": ["nodes": [node(6, state: "MERGED", merged: "2026-10-09T07:00:00Z"), node(2, state: "MERGED", merged: "2026-10-01T07:00:00Z")]],
            ],
            "requested": ["nodes": [node(9, author: "renovate", type: "Bot"), node(7)]],
        ]]
        let pulls = try #require(PullRequestWatch.pulls(from: json, now: TestTime.at("2026-10-09 12:00")))
        #expect(pulls.map(\.id) == ["me/app#7", "me/app#6", "me/app#9"])
        #expect(pulls.map(\.merged) == [false, true, false])
        #expect(pulls[1].mergedAt != nil && pulls[0].updatedAt != nil)
        #expect(pulls[2].reviewRequested && pulls[2].authorIsBot && !pulls[2].isMine)
    }

    @Test func questionsAboutPullRequestsWithdrawOnceTheyRecover() async throws {
        let initiative = try initiative()
        var other = pull(checks: "FAILURE")
        other.id = "me/app#8"
        other.number = 8
        _ = await initiative.saw([pull(mergeable: "CONFLICTING"), other])
        let questions = [ask("a-1", "app#7 conflicts and #8 is failing. Fix both?"), ask("a-2", "Want a walk?")]
        for question in questions { await initiative.link(question) }
        #expect(await initiative.moot(questions).isEmpty)

        // One recovers; the question still stands for the other. Checks running again aren't passing yet.
        other.checks = "PENDING"
        _ = await initiative.saw([pull(mergeable: "MERGEABLE"), other], at: .now.addingTimeInterval(1))
        #expect(await initiative.moot(questions).isEmpty)

        var merged = pull(mergeable: "UNKNOWN")
        merged.merged = true
        other.checks = "SUCCESS"
        _ = await initiative.saw([merged, other], at: .now.addingTimeInterval(2))
        #expect(await initiative.moot(questions) == ["a-1": "app#7 merged, checks pass on app#8"])
    }

    @Test func aQuestionAboutAHealthyPullRequestWaitsForItToMerge() async throws {
        let initiative = try initiative()
        _ = await initiative.saw([pull(checks: "SUCCESS", review: "APPROVED")])
        // Asked before tilde tied questions to PRs: it's tied on the next look.
        let question = ask("a-1", "app#7 is approved and green. Merge it?")
        #expect(await initiative.moot([question]).isEmpty)
        var merged = pull()
        merged.merged = true
        _ = await initiative.saw([merged], at: .now.addingTimeInterval(1))
        #expect(await initiative.moot([question]) == ["a-1": "app#7 merged"])
    }

    @Test func pullRequestsOffTheWatchedListsAreKnownByTheirRepo() async throws {
        let initiative = try initiative()
        _ = await initiative.saw([pull()])
        await initiative.link(ask("a-1", "app#703 and #704 conflict with their base. Fix them?"))
        #expect(await initiative.seen.asks["a-1"]?.map(\.subject) == ["me/app#703", "me/app#704"])
        await initiative.link(ask("a-2", "Pick option #2 or #3?"))  // no repo named, no watched PR with that number
        #expect(await initiative.seen.asks["a-2"] == nil)
    }

    @Test func questionsForAJobWaitForTheirAnswer() async throws {
        let initiative = try initiative()
        var merged = pull()
        merged.merged = true
        _ = await initiative.saw([merged])
        var question = ask("a-1", "Push app#7?")
        question.jobID = "j-1"
        #expect(await initiative.moot([question]).isEmpty)
    }

    func ask(_ id: String, _ question: String) -> Attention {
        Attention(id: id, jobID: nil, question: question, options: ["Yes", "No"], recommended: 0, detail: nil, requestID: nil, isApproval: false)
    }

    @Test func mergedPullRequestsOnlyMatterWhenMainBreaks() async throws {
        let initiative = try initiative()
        var merged = pull(checks: "SUCCESS")
        merged.merged = true
        #expect(await initiative.transitions([merged]).isEmpty)
        merged.checks = "FAILURE"
        merged.defaultBranchChecks = "FAILURE"
        let found = await initiative.transitions([merged])
        #expect(found.map(\.key) == ["main:app:def"])  // no "checks failed" for a PR that's already merged
        #expect(await initiative.nudges([merged], focusedRepo: "/x/app").isEmpty)
    }
}

