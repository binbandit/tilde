import Foundation
import Testing
import TildeSupport
import TildeWork
@testable import TildeBrain

@Suite struct InitiativeTests {
    let home = TildeHome(root: FileManager.default.temporaryDirectory.appending(path: "tilde-initiative-\(UUID().uuidString)"))

    func initiative() throws -> Initiative {
        try home.prepare()
        return Initiative(home: home, projects: ProjectIndex(roots: []))
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
}
