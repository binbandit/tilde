import Foundation
import Testing
import TildeKit

/// Each test gets a fresh instance, so its own defaults suite.
@Suite final class ConversationVisibilityTests {
    let suite = "dev.tilde.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let history: ConversationVisibility

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        history = ConversationVisibility(defaults: defaults)
    }

    isolated deinit { defaults.removePersistentDomain(forName: suite) }

    @Test func clearingHidesOnlyWhatIsSettled() {
        let messages = [
            message("old", from: .tilde),
            message("question", from: .tilde, attention: "a-1"),
            message("failed", from: .you, delivery: .failed("Offline")),
            message("queued", from: .you, delivery: .sent),
        ]
        history.clear(messages, questions: ["a-1"])
        #expect(history.hidden == ["old"])
        #expect(!history.canClear(messages, questions: ["a-1"]))
        #expect(ConversationVisibility(defaults: defaults).hidden == ["old"], "cleared IDs survive a relaunch")
    }

    @Test func clearingKeepsEveryInputAStreamingReplyMayAnswer() {
        // Coalesced turns can put a partial reply between several of your messages.
        let messages = [
            message("old", from: .tilde),
            message("first", from: .you, delivery: .read(.now)),
            message("partial", from: .tilde),
            message("second", from: .you, delivery: .read(.now)),
            message("reply", from: .tilde, streaming: true),
        ]
        history.clear(messages, questions: [])
        #expect(history.hidden == ["old", "partial"])
    }

    @Test func aNewReplyDoesNotBringBackClearedInput() {
        let earlier = message("earlier", from: .you, delivery: .read(.now))
        history.clear([message("old", from: .tilde), earlier], questions: [])
        let next = [earlier, message("sent", from: .you, delivery: .read(.now)), message("reply", from: .tilde, streaming: true)]
        let visible = history.visible(next, protecting: history.protectedIDs(in: next, questions: []))
        #expect(visible.map(\.id) == ["sent", "reply"])
    }

    @Test func aClearedMessageThatAsksAgainIsShown() {
        history.clear([message("old", from: .tilde)], questions: [])
        let reopened = message("old", from: .tilde, attention: "a-2")
        let protected = history.protectedIDs(in: [reopened], questions: ["a-2"])
        #expect(history.visible([reopened], protecting: protected) == [reopened])
    }

    @Test func restoreShowsEverythingAgain() {
        let messages = [message("old", from: .tilde), message("sent", from: .you, delivery: .read(.now))]
        history.clear(messages, questions: [])
        history.restore()
        #expect(history.visible(messages, protecting: []) == messages)
        #expect(ConversationVisibility(defaults: defaults).hidden.isEmpty)
    }

    private func message(
        _ id: String, from: Message.From, streaming: Bool = false, attention: String? = nil, delivery: Message.Delivery? = nil
    ) -> Message {
        var message = Message(id: id, from: from, text: id, attentionID: attention, streaming: streaming)
        message.delivery = delivery
        return message
    }
}
