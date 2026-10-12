import Foundation
import TildeKit

@main
struct ChatHistoryTests {
    @MainActor static func main() {
        let suite = "tilde.chat-history-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = ConversationVisibility(defaults: defaults)
        let old = Message(id: "old", from: .tilde, text: "Finished yesterday")
        var sent = Message(id: "sent", from: .you, text: "Please work")
        sent.delivery = .read(.now)
        var reply = Message(id: "reply", from: .tilde, text: "", streaming: true)
        let question = Message(id: "question", from: .tilde, text: "Approve?", attentionID: "a-1")
        var failed = Message(id: "failed", from: .you, text: "Retry me")
        failed.delivery = .failed("Offline")
        var queued = Message(id: "queued", from: .you, text: "Next request")
        queued.delivery = .sent
        let messages = [old, sent, reply, question, failed, queued]
        var earlierTap = Message(id: "earlier-tap", from: .you, text: "Also handle the first request")
        earlierTap.delivery = .read(.now)
        let partial = Message(id: "partial", from: .tilde, text: "Started before the second tap")
        let batched = [old, earlierTap, partial, sent, reply]
        history.clear(batched, questions: [])
        precondition(!history.hidden.contains(earlierTap.id), "Coalesced in-flight input must remain visible, even across a partial reply")
        history.restore()
        history.clear([old, earlierTap], questions: [])
        let nextExchange = [old, earlierTap, sent, reply]
        let nextProtection = history.protectedIDs(in: nextExchange, questions: [])
        precondition(!history.visible(nextExchange, protecting: nextProtection).contains(earlierTap),
            "A new streaming reply must not resurrect previously cleared inputs")
        history.restore()
        let before = messages
        history.clear(messages, questions: ["a-1"])
        precondition(messages == before, "Clear must not change the conversation or delivery state")
        precondition(history.hidden == ["old"], "Only completed messages can be hidden")
        precondition(!history.canClear(messages, questions: ["a-1"]))
        let reloaded = ConversationVisibility(defaults: defaults)
        precondition(reloaded.hidden == history.hidden, "A new history instance reloads cleared IDs")
        reply.streaming = false
        reply.text = "Done"
        let completed = [old, sent, reply, question, failed, queued]
        precondition(history.visible(completed, protecting: []).contains(reply), "An in-flight reply remains visible after finishing")
        history.clear(completed, questions: ["a-1"])
        precondition(history.hidden == ["old", "sent", "reply"])
        let reopened = Message(id: "old", from: .tilde, text: "Needs a new answer", attentionID: "a-2")
        let protection = history.protectedIDs(in: [reopened], questions: ["a-2"])
        precondition(history.visible([reopened], protecting: protection) == [reopened])
        history.restore()
        precondition(history.visible(messages, protecting: []) == messages)
        precondition(ConversationVisibility(defaults: defaults).hidden.isEmpty)
        var minimization = InletMinimization()
        let expanded = CGRect(x: -400, y: 100, width: 400, height: 600)
        minimization.minimize(in: expanded)
        precondition(minimization.isMinimized)
        minimization.pointerMoved(to: CGPoint(x: -200, y: 500))
        precondition(minimization.excludedHoverRect != nil, "A still pointer cannot reopen minimized chat")
        minimization.pointerMoved(to: CGPoint(x: -500, y: 500))
        precondition(minimization.excludedHoverRect == nil)
        precondition(minimization.isMinimized, "Leaving only rearms hover without reopening chat")
        var pending = InletMinimization.MessageState(id: "streaming", streaming: true)
        let oldNotice = InletMinimization.MessageState(id: "already-read")
        minimization.minimize(in: expanded, messages: [oldNotice, pending])
        precondition(minimization.latestNotice(in: [oldNotice, pending]) == nil, "Streaming churn must stay minimized")
        pending.streaming = false
        precondition(minimization.latestNotice(in: [oldNotice, pending]) == pending.id, "Completion must still notify after automatic minimization")
        precondition(minimization.latestNotice(in: [oldNotice, pending]) == nil, "Completion must announce only once")
        minimization.minimize(in: expanded, messages: [oldNotice, pending])
        precondition(minimization.latestNotice(in: [oldNotice, pending]) == nil, "Dismissing a completed peek must not immediately reopen it")
        let ask = InletMinimization.MessageState(id: "new-question", streaming: true, attentionID: "a-next")
        precondition(minimization.latestNotice(in: [oldNotice, pending, ask]) == ask.id, "New questions must remain visible while minimized")
        let failedNotice = InletMinimization.MessageState(id: "failed-send", isReply: false, failed: true)
        precondition(minimization.latestNotice(in: [failedNotice]) == failedNotice.id, "Failed delivery must remain visible while minimized")
        let pointer = CGPoint(x: -200, y: 500)
        precondition(!InletMinimization.pointerIsReadingPeek(at: pointer, shownAt: pointer, in: expanded),
            "A peek under a stationary pointer must still settle")
        precondition(InletMinimization.pointerIsReadingPeek(at: CGPoint(x: -190, y: 500), shownAt: pointer, in: expanded))
        precondition(!InletMinimization.pointerIsReadingPeek(at: .zero, shownAt: pointer, in: expanded))
        minimization.open()
        precondition(!minimization.isMinimized && minimization.excludedHoverRect == nil)
        print("Chat history and minimization regressions passed: clear, restore, defaults reload, active replies, questions, queued and failed delivery.")
    }
}
