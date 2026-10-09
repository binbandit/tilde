import AppKit
import TildeKit
@preconcurrency import UserNotifications

/// Native notifications for when you're not looking: questions you can answer
/// inline, and work that's ready. Grouped per job; only blocking asks are Time Sensitive.
@MainActor
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    private let model: AppModel
    private let inlet: InletController
    private let center = UNUserNotificationCenter.current()

    init(model: AppModel, inlet: InletController) {
        self.model = model
        self.inlet = inlet
    }

    func start() {
        center.delegate = self
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    /// While you're at the Mac the inlet does the talking; notifications are
    /// for when you've stepped away, so nothing waits on you unseen.
    func handle(_ signal: Conductor.Signal) {
        switch signal {
        case .asked(let item): if Self.isAway { post(item) }
        case .resolved(let id): center.removeDeliveredNotifications(withIdentifiers: [id])
        case .said(let text, let jobID): if Self.isAway { say(text, jobID: jobID) }
        case .noted, .jobChanged, .trouble: break
        }
    }

    /// No keyboard or mouse input for a minute.
    static var isAway: Bool {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) > 60
    }

    private func post(_ item: Attention) {
        let content = UNMutableNotificationContent()
        let job = model.job(item.jobID)
        content.title = item.question
        content.subtitle = job.map { "\($0.title) · \($0.projectName)" } ?? ""
        let recommended = item.recommended.flatMap { item.options.indices.contains($0) ? item.options[$0] : nil }
        content.body = [item.detail, recommended.map { "tilde suggests: \($0)" }].compactMap { $0 }.joined(separator: "\n")
        content.threadIdentifier = item.jobID ?? "tilde"
        content.interruptionLevel = item.requestID != nil ? .timeSensitive : .active
        content.sound = .default
        content.userInfo = ["attention": item.id]

        // Options become buttons (the recommended one first); a text field takes anything else.
        var options = item.options
        if let recommended, let i = options.firstIndex(of: recommended) { options.insert(options.remove(at: i), at: 0) }
        let actions: [UNNotificationAction] = options.prefix(3).enumerated().map { index, option in
            UNNotificationAction(identifier: "option.\(index).\(option)", title: index == 0 && recommended != nil ? "\(option) ✓" : option)
        } + [UNTextInputNotificationAction(identifier: "reply", title: "Reply…", textInputButtonTitle: "Send", textInputPlaceholder: "Tell tilde…")]
        let category = UNNotificationCategory(identifier: "ask.\(item.id)", actions: actions, intentIdentifiers: [])
        content.categoryIdentifier = category.identifier
        Task {
            // Categories must exist before the notification that uses them.
            let existing = await center.notificationCategories().filter { !$0.identifier.hasPrefix("ask.") }
            center.setNotificationCategories(existing.union([category]))
            try? await center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
        }
    }

    private func say(_ text: String, jobID: String?) {
        let content = UNMutableNotificationContent()
        let job = model.job(jobID)
        content.title = job?.title ?? "tilde"
        content.subtitle = job?.projectName ?? ""
        content.body = text
        content.threadIdentifier = jobID ?? "tilde"
        content.userInfo = jobID.map { ["job": $0] } ?? [:]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let attentionID = info["attention"] as? String
        let jobID = info["job"] as? String
        let action = response.actionIdentifier
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            if let id = attentionID, let item = model.attention.first(where: { $0.id == id }) {
                if let typed {
                    model.answer(item, with: typed)
                } else if action.hasPrefix("option.") {
                    model.answer(item, with: action.split(separator: ".", maxSplits: 2).last.map(String.init) ?? "")
                }
            } else if let job = model.job(jobID) {
                inlet.openJob(job)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
