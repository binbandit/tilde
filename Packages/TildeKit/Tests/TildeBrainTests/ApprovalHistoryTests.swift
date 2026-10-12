import Foundation
import Testing
import TildeSupport
@testable import TildeBrain

@MainActor @Suite(.serialized) struct ApprovalHistoryTests {
    @Test(arguments: ["Allow", "Don't allow"])
    func permissionControlsStayInTheJobAudit(_ reply: String) async throws {
        let fixture = ConductorTests()
        let conductor = try await fixture.makeConductor()
        _ = await fixture.call(conductor, "delegate", ["project_path": .string(fixture.repo), "title": "Ship", "brief": "Add and push", "harness": "scripted"])
        let job = try #require(conductor.jobs.first)
        try await fixture.waitFor(conductor) { conductor.requests["r-push"] != nil }
        _ = await fixture.call(conductor, "ask", ["question": "Push?", "options": ["Allow", "Don't allow"], "request": "r-push"])
        let item = try #require(conductor.attention.first)
        conductor.answer(item.id, with: reply)
        try await fixture.waitFor(conductor) { conductor.transcriptStore.load(job.id).contains { $0.kind == .decision && $0.from == .you } }
        #expect(!conductor.thread.contains { $0.from == .you && $0.text == reply })
        #expect(conductor.thread.allSatisfy { !$0.streaming })
        #expect(conductor.thread.first?.attentionID == nil)
        #expect(conductor.transcriptStore.load(job.id).contains { $0.kind == .decision && $0.from == .you })
        let restored = try Conductor(home: conductor.home, config: fixture.config)
        #expect(!restored.thread.contains { $0.from == .you && $0.text == reply })
        #expect(restored.transcriptStore.load(job.id).contains { $0.kind == .decision && $0.from == .you })
    }

    @Test func ordinaryAnswersRemainConversationMessages() async throws {
        let fixture = ConductorTests()
        let conductor = try await fixture.makeConductor()
        _ = await fixture.call(conductor, "ask", ["question": "Which layout?", "options": ["Compact", "Wide"]])
        conductor.answer(try #require(conductor.attention.first?.id), with: "Compact")
        #expect(conductor.thread.contains { $0.from == .you && $0.text == "Compact" })
    }

    @Test func staleApprovalCannotCreateStandingPermissionOrChatText() async throws {
        let fixture = ConductorTests()
        let conductor = try await fixture.makeConductor()
        _ = await fixture.call(conductor, "delegate", ["project_path": .string(fixture.repo), "title": "Ship", "brief": "Add and push", "harness": "scripted"])
        let job = try #require(conductor.jobs.first)
        try await fixture.waitFor(conductor) { conductor.requests["r-push"] != nil }
        _ = await fixture.call(conductor, "ask", ["question": "Push?", "options": ["Allow", "Don't allow"], "request": "r-push"])
        let item = try #require(conductor.attention.first)
        conductor.requests.removeAll()
        conductor.answer(item.id, with: "Allow", always: true)
        #expect(conductor.standingAllows.isEmpty)
        #expect(!conductor.thread.contains { $0.from == .you })
        #expect(conductor.transcriptStore.load(job.id).contains { $0.text.contains("not delivered") })
    }
}
