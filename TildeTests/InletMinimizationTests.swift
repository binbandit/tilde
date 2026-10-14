import CoreGraphics
import Testing

@Suite struct InletMinimizationTests {
    let chat = CGRect(x: -400, y: 100, width: 400, height: 600)
    let read = message("read")

    @Test func aReplyIsAnnouncedOnceWhenItFinishes() {
        var minimization = InletMinimization()
        var reply = message("reply", streaming: true)
        minimization.minimize(in: chat, messages: [read, reply])
        #expect(minimization.latestNotice(in: [read, reply]) == nil, "streaming stays minimized")

        reply.streaming = false
        #expect(minimization.latestNotice(in: [read, reply]) == "reply")
        #expect(minimization.latestNotice(in: [read, reply]) == nil, "announced once")

        minimization.minimize(in: chat, messages: [read, reply])
        #expect(minimization.latestNotice(in: [read, reply]) == nil, "dismissing it doesn't bring it back")
    }

    @Test func questionsAndFailuresShowWhileMinimized() {
        var minimization = InletMinimization()
        minimization.minimize(in: chat, messages: [read])
        let question = message("question", streaming: true, attention: "a-1")
        #expect(minimization.latestNotice(in: [read, question]) == "question")

        let failed = message("failed", isReply: false, failed: true)
        #expect(minimization.latestNotice(in: [read, question, failed]) == "failed")
    }

    @Test func nothingIsAnnouncedWhileOpen() {
        var minimization = InletMinimization()
        minimization.minimize(in: chat, messages: [read])
        minimization.open()
        #expect(minimization.latestNotice(in: [read, message("reply")]) == nil)
    }
}

private func message(
    _ id: String, isReply: Bool = true, streaming: Bool = false, failed: Bool = false, attention: String? = nil
) -> InletMinimization.MessageState {
    InletMinimization.MessageState(id: id, isReply: isReply, streaming: streaming, failed: failed, attentionID: attention)
}
