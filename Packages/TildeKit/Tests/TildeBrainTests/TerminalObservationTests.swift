import Foundation
import Testing
import TildeSupport
import TildeWork
@testable import TildeBrain

@Suite struct TerminalObservationTests {
    func agent(_ state: TerminalAgent.State, changes: Int, pane: String = "w1:p1") -> TerminalAgent {
        TerminalAgent(harness: .claude, cwd: "/Users/o/shop", state: state, place: .herdr(pane: pane), changes: changes)
    }

    @Test func aBlockedAgentIsRaisedOnlyOnceItHasWaitedALook() {
        #expect(AgentWatch.notices([agent(.blocked, changes: 4)], before: []).isEmpty)
        #expect(AgentWatch.notices([agent(.blocked, changes: 4)], before: [agent(.working, changes: 3)]).isEmpty)
        let raised = AgentWatch.notices([agent(.blocked, changes: 4)], before: [agent(.blocked, changes: 4)])
        #expect(raised.map(\.urgency) == [.soon])
        #expect(raised.first?.summary.contains("waiting on you") == true)
        // Answered and blocked again since the last look: the owner is at it.
        #expect(AgentWatch.notices([agent(.blocked, changes: 6)], before: [agent(.blocked, changes: 4)]).isEmpty)
    }

    @Test func finishingUnseenIsAnFYIButIdleWasSeen() {
        #expect(AgentWatch.notices([agent(.done, changes: 5)], before: [agent(.working, changes: 4)]).map(\.urgency) == [.fyi])
        #expect(AgentWatch.notices([agent(.done, changes: 5)], before: [agent(.done, changes: 5)]).isEmpty)
        #expect(AgentWatch.notices([agent(.idle, changes: 5)], before: [agent(.working, changes: 4)]).isEmpty)
        let elsewhere = [agent(.done, changes: 5, pane: "w9:p9")]
        #expect(AgentWatch.notices(elsewhere, before: [agent(.working, changes: 4)]).isEmpty)
    }

    @Test(arguments: [(TerminalAgent.State.done, 1), (.idle, 0), (.working, 0)])
    func aHeldNoticeStandsOnlyWhileTheAgentStaysAsItWas(next: TerminalAgent.State, said: Int) async throws {
        let home = TildeHome(root: FileManager.default.temporaryDirectory.appending(path: "tilde-terminals-\(UUID().uuidString)"))
        try home.prepare()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let initiative = Initiative(home: home)
        _ = await initiative.saw([agent(.working, changes: 4)])
        let finished = await initiative.saw([agent(.done, changes: 5)])
        #expect(await initiative.due(finished, typing: false, looking: false).isEmpty)
        _ = await initiative.saw([agent(next, changes: next == .done ? 5 : 6)])
        #expect(await initiative.due([], typing: false, looking: true).count == said)
        #expect(await initiative.watching().components(separatedBy: "Claude Code in /Users/o/shop").count == 2)
    }
}
