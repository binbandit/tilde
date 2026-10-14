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
        // Questions restored with the conversation need their inline actions registered again.
        registerQuestions()
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    /// While you're at the Mac the inlet does the talking; notifications are
    /// for when you've stepped away, so nothing waits on you unseen.
    func handle(_ signal: Conductor.Signal) {
        switch signal {
        case .asked(let item): if Self.isAway { post(item) } else { remindLater(item) }
        case .resolved(let id):
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.removeDeliveredNotifications(withIdentifiers: [id])
            registerQuestions()
        case .said(let text, let jobID): if Self.isAway { say(text, jobID: jobID) }
        // A reply you walked away from waits for you like a text would (not one showing on the Inlet now).
        case .replied(let text): if Self.isAway, inlet.inlet.mode == .rest { say(text, jobID: nil) }
        case .noted, .jobChanged, .trouble: break
        }
    }

    /// A question still unanswered after a few minutes reaches you anyway: its peek may have come and gone on a
    /// screen you weren't looking at.
    private func remindLater(_ item: Attention) {
        Task {
            try? await Task.sleep(for: .seconds(300))
            // Not if it's answered, or in front of you right now (the conversation, or its job, open).
            guard model.attention.contains(where: { $0.id == item.id }), !inlet.inlet.isConversation,
                inlet.inlet.mode != .job(item.jobID ?? "")
            else { return }
            post(item)
        }
    }

    /// No keyboard or mouse input for a minute.
    static var isAway: Bool {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) > 60
    }

    private func post(_ item: Attention) {
        // Its actions have to be registered before the notification that uses them.
        registerQuestions()
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
        content.categoryIdentifier = Self.categoryID(item.id)
        center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
    }

    /// Every open question keeps its inline answers. tilde registers no other categories.
    private func registerQuestions() {
        center.setNotificationCategories(Set(model.attention.map(Self.category)))
    }

    private static func categoryID(_ attentionID: String) -> String { "ask.\(attentionID)" }

    private static func category(_ item: Attention) -> UNNotificationCategory {
        // Options become buttons (the recommended one first); a text field takes anything else.
        let recommended = item.recommended.flatMap { item.options.indices.contains($0) ? item.options[$0] : nil }
        var options = item.options
        if let recommended, let i = options.firstIndex(of: recommended) { options.insert(options.remove(at: i), at: 0) }
        let actions: [UNNotificationAction] = options.prefix(3).enumerated().map { index, option in
            UNNotificationAction(identifier: "option.\(index).\(option)", title: index == 0 && recommended != nil ? "\(option) ✓" : option)
        } + [UNTextInputNotificationAction(identifier: "reply", title: "Reply…", textInputButtonTitle: "Send", textInputPlaceholder: "Message tilde")]
        return UNNotificationCategory(identifier: categoryID(item.id), actions: actions, intentIdentifiers: [])
    }

    private func say(_ text: String, jobID: String?) {
        let content = UNMutableNotificationContent()
        let job = model.job(jobID)
        content.title = job?.title ?? "tilde"
        content.subtitle = job?.projectName ?? ""
        content.body = Self.plain(text)
        content.threadIdentifier = jobID ?? "tilde"
        content.userInfo = jobID.map { ["job": $0] } ?? [:]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Notifications show plain words: a link as its text, emphasis without its stars.
    private static func plain(_ text: String) -> String {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            .map { String($0.characters) } ?? text
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
            if let id = attentionID, let item = model.attention.first(where: { $0.id == id }), typed != nil || action.hasPrefix("option.") {
                model.answer(item, with: typed ?? action.split(separator: ".", maxSplits: 2).last.map(String.init) ?? "")
            } else if let job = model.job(jobID) {
                inlet.openJob(job)
            } else if action == UNNotificationDefaultActionIdentifier {
                // Clicked: the conversation opens where it left off, ready for what you say next.
                inlet.compose(about: nil)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
