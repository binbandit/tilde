import Foundation

/// What Brayden was looking at and pointing at when he spoke.
public struct TapContext: Codable, Sendable, Hashable {
    public var app: String?
    public var bundleID: String?
    public var windowTitle: String?
    /// A file the window or pointed-at element represents.
    public var document: String?
    /// The working directory of the terminal he was in.
    public var cwd: String?
    /// The git repo that `document` or `cwd` sits in.
    public var repo: String?
    /// What the Lens outlined, in a few words ("selected text in ContentView.swift").
    public var pointing: String?
    /// Selected or pointed-at text, clipped.
    public var text: String?
    /// The job whose Ribbon or Desk card he pointed at.
    public var jobID: String?

    public init(
        app: String? = nil, bundleID: String? = nil, windowTitle: String? = nil, document: String? = nil,
        cwd: String? = nil, repo: String? = nil, pointing: String? = nil, text: String? = nil, jobID: String? = nil
    ) {
        self.app = app
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.document = document
        self.cwd = cwd
        self.repo = repo
        self.pointing = pointing
        self.text = text
        self.jobID = jobID
    }

    /// XML-ish attributes for the manager's <tap> tag.
    var attributes: [(String, String)] {
        [("app", app), ("window", windowTitle), ("document", document), ("cwd", cwd), ("repo", repo),
         ("pointing", pointing), ("job", jobID)]
            .compactMap { key, value in value.flatMap { $0.isEmpty ? nil : (key, $0) } }
    }
}

/// The app's senses, as the brain sees them.
@MainActor
public protocol Perception: AnyObject {
    /// Where Brayden is right now (frontmost app, window, terminal cwd).
    func currentContext() -> TapContext
    /// A compact, human-readable account of recent app and window activity.
    func recentActivity(hours: Double) -> String
    /// Calendar events from now until `hours` ahead (with who and the notes) and reminders due
    /// today, as text. Empty when there's nothing, or tilde hasn't been given access.
    func schedule(hours: Double) async -> String
}
