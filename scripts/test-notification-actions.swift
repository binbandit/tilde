import Foundation

// Platform fixtures: the production Notifications class below never reaches a system service.
nonisolated protocol UNUserNotificationCenterDelegate: AnyObject {}
nonisolated struct UNAuthorizationOptions: OptionSet {
    let rawValue: Int
    static let alert = Self(rawValue: 1), sound = Self(rawValue: 2), badge = Self(rawValue: 4)
}
nonisolated struct UNNotificationPresentationOptions: OptionSet {
    let rawValue: Int
    static let banner = Self(rawValue: 1), sound = Self(rawValue: 2), list = Self(rawValue: 4)
}
nonisolated enum InterruptionLevel { case active, timeSensitive }
nonisolated enum NotificationSound { case `default` }
nonisolated class UNNotificationAction: @unchecked Sendable {
    let identifier: String
    let title: String
    init(identifier: String, title: String) { self.identifier = identifier; self.title = title }
}
nonisolated final class UNTextInputNotificationAction: UNNotificationAction, @unchecked Sendable {
    init(identifier: String, title: String, textInputButtonTitle: String, textInputPlaceholder: String) {
        super.init(identifier: identifier, title: title)
    }
}
nonisolated final class UNNotificationCategory: Hashable, @unchecked Sendable {
    let identifier: String
    let actions: [UNNotificationAction]
    init(identifier: String, actions: [UNNotificationAction], intentIdentifiers: [String]) {
        self.identifier = identifier; self.actions = actions
    }
    static func == (a: UNNotificationCategory, b: UNNotificationCategory) -> Bool { a.identifier == b.identifier }
    func hash(into hasher: inout Hasher) { hasher.combine(identifier) }
}
nonisolated final class UNMutableNotificationContent: @unchecked Sendable {
    var title = "", subtitle = "", body = "", threadIdentifier = "", categoryIdentifier = ""
    var interruptionLevel = InterruptionLevel.active
    var sound: NotificationSound?
    var userInfo: [AnyHashable: Any] = [:]
}
nonisolated final class UNNotificationRequest: @unchecked Sendable {
    let identifier: String
    let content: UNMutableNotificationContent
    init(identifier: String, content: UNMutableNotificationContent, trigger: String?) {
        self.identifier = identifier; self.content = content
    }
}
nonisolated struct UNNotification: Sendable { var request: UNNotificationRequest }
nonisolated class UNNotificationResponse: @unchecked Sendable {
    let notification: UNNotification
    let actionIdentifier: String
    init(notification: UNNotification, actionIdentifier: String) {
        self.notification = notification; self.actionIdentifier = actionIdentifier
    }
}
nonisolated final class UNTextInputNotificationResponse: UNNotificationResponse, @unchecked Sendable {
    let userText = "typed reply"
}
let UNNotificationDefaultActionIdentifier = "default"

final class UNUserNotificationCenter {
    static var fixture = UNUserNotificationCenter()
    static func current() -> UNUserNotificationCenter { fixture }
    var delegate: (any UNUserNotificationCenterDelegate)?
    var categories: Set<UNNotificationCategory> = []
    var delivered: [String: UNNotificationRequest] = [:]
    var added: [String] = []
    var reads = 0, addStarts = 0, addEnds = 0
    var blockReads = false, blockAdds = false
    var readers: [CheckedContinuation<Void, Never>] = []
    var adders: [CheckedContinuation<Void, Never>] = []
    var removedPending: [String] = []
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }
    func notificationCategories() async -> Set<UNNotificationCategory> {
        reads += 1
        let snapshot = categories
        if blockReads { await withCheckedContinuation { readers.append($0) } }
        return snapshot
    }
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) { self.categories = categories }
    func add(_ request: UNNotificationRequest) async throws {
        addStarts += 1
        if blockAdds { await withCheckedContinuation { adders.append($0) } }
        delivered[request.identifier] = request
        added.append(request.identifier)
        addEnds += 1
    }
    func add(_ request: UNNotificationRequest, withCompletionHandler: ((Error?) -> Void)? = nil) {
        delivered[request.identifier] = request
        added.append(request.identifier)
    }
    func removeDeliveredNotifications(withIdentifiers ids: [String]) { ids.forEach { delivered[$0] = nil } }
    func removePendingNotificationRequests(withIdentifiers ids: [String]) { removedPending += ids }
    func releaseReads() {
        blockReads = false
        let waiting = readers; readers = []
        waiting.forEach { $0.resume() }
    }
    func releaseAdds() {
        blockAdds = false
        let waiting = adders; adders = []
        waiting.forEach { $0.resume() }
    }
}

enum CGEventSource {
    enum State { case combinedSessionState }
    static func secondsSinceLastEventType(_ state: State, eventType: CGEventType) -> Double { 120 }
}
struct CGEventType { init?(rawValue: Int) {} }
struct Job { var title = "fixture", projectName = "fixture" }
final class AppModel {
    var attention: [Attention] = []
    var answers: [String: String] = [:]
    func job(_ id: String?) -> Job? { nil }
    func answer(_ item: Attention, with reply: String) { answers[item.id] = reply }
}
enum Conductor {
    enum Signal {
        case asked(Attention), resolved(String), said(String, String?), replied(String), noted, jobChanged, trouble
    }
}
final class InletController {
    final class State {
        enum Mode: Equatable { case rest, job(String) }
        var mode = Mode.rest
        var isConversation = false
    }
    let inlet = State()
    func openJob(_ job: Job) {}
    func compose(about: String?) {}
}

@main
struct NotificationActionsTests {
    struct Failure: Error, CustomStringConvertible { var description: String }
    static func ask(_ id: String) -> Attention {
        Attention(id: id, jobID: nil, question: "Question \(id)", options: ["Wait", "Proceed."], recommended: 1,
                  detail: nil, requestID: nil, isApproval: false)
    }
    static func setup(_ items: [Attention]) -> (Notifications, AppModel, UNUserNotificationCenter) {
        let center = UNUserNotificationCenter()
        center.categories = [
            UNNotificationCategory(identifier: "external", actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: "ask.unowned", actions: [], intentIdentifiers: []),
        ]
        UNUserNotificationCenter.fixture = center
        let model = AppModel()
        model.attention = items
        return (Notifications(model: model, inlet: InletController()), model, center)
    }
    static func main() async {
        do { try await check() } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
    static func check() async throws {
        let a = ask("a"), b = ask("b")
        let (notifications, model, center) = setup([a, b])
        notifications.handle(.asked(a))
        notifications.handle(.asked(b))
        try await eventually("both questions published") { center.addEnds == 2 }
        try expect(Set(center.categories.map(\.identifier)) == ["external", "ask.unowned", "ask.a", "ask.b"],
                   "Posting a second question removed an outstanding or unrelated category")
        let category = center.categories.first { $0.identifier == "ask.a" }!
        try expect(category.actions.map(\.identifier) == ["option.0.Proceed.", "option.1.Wait", "reply"], "Question actions changed")
        let response = UNNotificationResponse(notification: UNNotification(request: center.delivered["a"]!), actionIdentifier: "option.0.Proceed.")
        await notifications.userNotificationCenter(center, didReceive: response)
        try expect(model.answers["a"] == "Proceed.", "Inline answer did not retain punctuation")

        model.attention.removeAll { $0.id == a.id }
        notifications.handle(.resolved(a.id))
        try await eventually("resolved category removed") { !center.categories.contains { $0.identifier == "ask.a" } }
        try expect(center.delivered["a"] == nil && center.delivered["b"] != nil, "Resolving one question removed the wrong notification")
        try expect(center.categories.contains { $0.identifier == "ask.b" }, "Resolving one question removed another's actions")

        let restored = ask("restored")
        let (restart, _, restartCenter) = setup([restored])
        restart.start()
        try await eventually("restored question actions registered") { restartCenter.categories.contains { $0.identifier == "ask.restored" } }
        try expect(restartCenter.added.isEmpty, "Restoring categories republished questions")

        let (queued, queuedModel, queuedCenter) = setup([a, b])
        queuedCenter.blockReads = true
        queued.handle(.asked(a))
        queued.handle(.asked(b))
        try await eventually("category read suspended") { !queuedCenter.readers.isEmpty }
        queuedModel.attention.removeAll { $0.id == a.id }
        queued.handle(.resolved(a.id))
        queuedCenter.releaseReads()
        try await eventually("remaining queued question published") { queuedCenter.added.contains(b.id) }
        try expect(!queuedCenter.added.contains(a.id), "Question resolved during registration was published")
        try expect(Set(queuedCenter.categories.map(\.identifier)) == ["external", "ask.unowned", "ask.b"], "Concurrent registration lost categories")

        let (inFlight, inFlightModel, inFlightCenter) = setup([a])
        inFlightCenter.blockAdds = true
        inFlight.handle(.asked(a))
        try await eventually("publication suspended") { !inFlightCenter.adders.isEmpty }
        inFlightModel.attention = []
        inFlight.handle(.resolved(a.id))
        inFlightCenter.releaseAdds()
        try await eventually("resolved in-flight notification removed") { inFlightCenter.addEnds == 1 && inFlightCenter.delivered[a.id] == nil }
        try expect(inFlightCenter.removedPending.contains(a.id), "Resolved pending notification was not removed")
        print("Passed notification category retention, restoration, action delivery, concurrent registration, and resolution-race fixtures.")
    }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    static func eventually(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw Failure(description: "Timed out: \(message)")
    }
}
