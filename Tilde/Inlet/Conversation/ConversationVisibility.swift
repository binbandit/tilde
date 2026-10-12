import Foundation
import Observation
import TildeKit

/// Clearing is a reversible view preference. The conductor's conversation,
/// pending questions, deliveries and running work are never changed.
@MainActor @Observable
final class ConversationVisibility {
    static let storageKey = "inlet.clearedMessages"
    private(set) var hidden: Set<String>
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hidden = Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }

    /// Keep a pending reply with the message it answers, and keep every way
    /// to answer a question or retry a delivery available after clearing.
    func protectedIDs(in messages: [Message], questions: Set<String>) -> Set<String> {
        var protected = Set<String>()
        // Coalesced turns can leave partial replies between several owner
        // messages. Without the manager's turn mapping, keep every owner message
        // while a reply streams rather than hide an input it may still answer.
        if messages.contains(where: \.streaming) {
            protected.formUnion(messages.filter { $0.from == .you && !hidden.contains($0.id) }.map(\.id))
        }
        for message in messages {
            let question = message.attentionID.map { questions.contains($0) } ?? false
            let pending: Bool
            switch message.delivery {
            case .sent, .failed: pending = true
            default: pending = false
            }
            guard message.streaming || question || pending else { continue }
            protected.insert(message.id)
        }
        return protected
    }

    func visible(_ messages: [Message], protecting protected: Set<String>) -> [Message] {
        messages.filter { !hidden.contains($0.id) || protected.contains($0.id) }
    }

    func canClear(_ messages: [Message], questions: Set<String>) -> Bool {
        let protected = protectedIDs(in: messages, questions: questions)
        return messages.contains { !hidden.contains($0.id) && !protected.contains($0.id) }
    }

    func clear(_ messages: [Message], questions: Set<String>) {
        let protected = protectedIDs(in: messages, questions: questions)
        // Only these messages can be displayed now or carried into tomorrow.
        // Prune older IDs while preserving repeated clears and relaunches.
        hidden.formIntersection(messages.map(\.id))
        hidden.formUnion(messages.lazy.map(\.id).filter { !protected.contains($0) })
        persist()
    }

    func restore() {
        hidden.removeAll()
        persist()
    }

    private func persist() {
        defaults.set(hidden.sorted(), forKey: Self.storageKey)
    }
}
