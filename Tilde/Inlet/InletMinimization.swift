import Foundation
import CoreGraphics

/// Minimized chat ignores streaming churn, but still announces completion,
/// failed delivery and new questions. Existing completed messages stay dismissed.
nonisolated struct InletMinimization {
    struct MessageState {
        var id: String
        var isReply: Bool
        var streaming: Bool
        var failed: Bool
        var attentionID: String?
    }

    private(set) var isMinimized = false
    /// Where the Inlet was put away from: hovering there doesn't bring it straight back,
    /// until the pointer has left it once.
    private(set) var excludedHoverRect: CGRect?
    private var previous: [String: MessageState] = [:]

    mutating func minimize(in rect: CGRect, messages: [MessageState]) {
        isMinimized = true
        excludeHover(around: rect)
        previous = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    mutating func excludeHover(around rect: CGRect) {
        excludedHoverRect = rect.insetBy(dx: -16, dy: -16)
    }

    mutating func open() {
        isMinimized = false
        excludedHoverRect = nil
        previous.removeAll()
    }

    mutating func pointerMoved(to point: CGPoint) {
        if let rect = excludedHoverRect, !rect.contains(point) { excludedHoverRect = nil }
    }

    /// A completion is announced once, even when its streaming placeholder was
    /// already present at send time. New asks and failures never wait for reopening.
    mutating func latestNotice(in messages: [MessageState]) -> String? {
        defer { previous = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }) }
        guard isMinimized else { return nil }
        return messages.last { message in
            let old = previous[message.id]
            if let attention = message.attentionID, attention != old?.attentionID { return true }
            if message.failed, old?.failed != true { return true }
            return message.isReply && !message.streaming && (old == nil || old?.streaming == true)
        }?.id
    }
}
