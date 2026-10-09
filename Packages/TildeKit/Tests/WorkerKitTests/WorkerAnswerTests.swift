import Testing
@testable import WorkerKit

@Suite struct WorkerAnswerTests {
    @Test func approvalRepliesReadAsYesOrNo() {
        #expect(WorkerAnswer.isYes("Allow"))
        #expect(WorkerAnswer.isYes("yes please"))
        #expect(!WorkerAnswer.isYes("Don't allow"))
        #expect(!WorkerAnswer.isYes("no"))
    }
}
