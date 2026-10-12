import Foundation
import CoreGraphics

/// Minimized chat ignores streaming churn, but still announces completion,
/// failed delivery and new questions. Existing completed messages stay dismissed.
nonisolated struct InletMinimization {
    struct MessageState {
        var id: String
        var isReply: Bool = true
        var streaming = false
        var failed = false
        var attentionID: String?
    }

    private(set) var isMinimized = false
    private(set) var excludedHoverRect: CGRect?
    private var previous: [String: MessageState] = [:]

    mutating func minimize(in rect: CGRect, messages: [MessageState] = []) {
        isMinimized = true
        excludedHoverRect = rect.insetBy(dx: -16, dy: -16)
        previous = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
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

    static func pointerIsReadingPeek(at point: CGPoint, shownAt origin: CGPoint?, in rect: CGRect) -> Bool {
        guard rect.insetBy(dx: -16, dy: -16).contains(point) else { return false }
        return origin.map { hypot(point.x - $0.x, point.y - $0.y) >= 4 } ?? true
    }
}
