import Testing
@testable import WorkerKit

@Suite struct WorkerAnswerTests {
    @Test func approvalRepliesReadAsYesOrNo() {
        #expect(WorkerAnswer.isYes("Allow"))
        #expect(WorkerAnswer.isYes("yes please"))
        #expect(!WorkerAnswer.isYes("Don't allow"))
        #expect(!WorkerAnswer.isYes("no"))
        // A yes has to be the whole reply.
        #expect(!WorkerAnswer.isYes("do not push"))
        #expect(!WorkerAnswer.isYes("ok but not to main"))
        #expect(!WorkerAnswer.isYes("go away"))
    }
}
