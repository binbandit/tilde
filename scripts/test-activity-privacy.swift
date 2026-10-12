import Foundation

// Compile the real ambient sampler and policy against fixtures instead of macOS APIs.
struct FixtureApplication {
    var localizedName: String?
    var bundleIdentifier: String?
    var processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier + 1
}

enum NSWorkspace {
    static let shared = FixtureWorkspace()
    static let didActivateApplicationNotification = Notification.Name("fixture activation")
}

final class FixtureWorkspace {
    var frontmostApplication: FixtureApplication?
    let notificationCenter = NotificationCenter()
}

let kAXTitleAttribute = "title"
let kAXDocumentAttribute = "document"

enum Pointing {
    // The production terminal catalog is inserted here by the runner.
    // TERMINAL_CATALOG
    static var title: String?
    static var document: String?
    static var documentReads = 0
    static func focusedWindow(_ pid: Int32) -> Int? { 1 }
    static func string(_ window: Int, _ attribute: String) -> String? {
        if attribute == kAXDocumentAttribute { documentReads += 1; return document }
        return title
    }
    static func path(fromURL text: String) -> String? { URL(string: text)?.path }
    static func frontmost() -> FixtureReferent? { nil }
}

struct FixtureReferent { var context = TapContext() }
struct TapContext { var app: String? }
protocol Perception {}
final class Schedule {
    func upcoming(hours: Double) -> String { "" }
    func remindersDue(days: Double) async -> String { "" }
}
enum Shells {
    static func cwd(forTerminal pid: Int32, title: String?) -> String? { "/synthetic/terminal-project" }
}
enum Repos {
    static func root(containing path: String?) -> String? { nil }
}
enum Titles {
    static func short(_ title: String, app: String) -> String { title }
}
struct TildeHome {
    static var `default` = TildeHome(state: URL(fileURLWithPath: CommandLine.arguments[1]))
    var state: URL
}

extension MacPerception {
    func sampleFixture() -> Span {
        sample()
        return current!
    }

    func finishFixture() {
        current?.start = .now.addingTimeInterval(-120)
        NSWorkspace.shared.frontmostApplication = FixtureApplication(localizedName: "Next fixture", bundleIdentifier: nil)
        Pointing.title = nil
        Pointing.document = nil
        sample()
    }
}

@main
struct ActivityPrivacyTests {
    struct Failure: Error, CustomStringConvertible { var description: String }
    struct Case {
        var name: String
        var bundle: String?
        var title: String?
        var document: String? = "file:///synthetic/private-document.pdf"
        var allowed = false
        var expectedPath: String? { allowed ? document.flatMap { URL(string: $0)?.path } ?? "/synthetic/terminal-project" : nil }
    }

    static func main() {
        do { try check() } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    static func check() throws {
        let scratch = TildeHome.default.state
        let cases = [
            Case(name: "Preview", bundle: "com.apple.Preview", title: "Personal document"),
            Case(name: "Mail", bundle: "com.apple.mail", title: "Private message"),
            Case(name: "Unknown app", bundle: nil, title: "Private title"),
            Case(name: "Browser personal", bundle: "com.apple.Safari", title: "Personal banking"),
            Case(name: "Browser untitled", bundle: "com.apple.Safari", title: nil),
            Case(name: "Browser development", bundle: "com.apple.Safari", title: "Swift developer docs", allowed: true),
            Case(name: "Editor", bundle: "com.microsoft.VSCode", title: "main.swift", allowed: true),
            Case(name: "Editor untitled", bundle: "com.microsoft.VSCode", title: nil, allowed: true),
            Case(name: "JetBrains untitled", bundle: "com.jetbrains.intellij", title: nil, allowed: true),
            Case(name: "Terminal untitled", bundle: "com.apple.Terminal", title: nil, document: nil, allowed: true),
        ]
        for (index, fixture) in cases.enumerated() {
            TildeHome.default.state = scratch.appending(path: String(index))
            try FileManager.default.createDirectory(at: TildeHome.default.state, withIntermediateDirectories: true)
            NSWorkspace.shared.frontmostApplication = FixtureApplication(localizedName: fixture.name, bundleIdentifier: fixture.bundle)
            Pointing.title = fixture.title
            Pointing.document = fixture.document
            Pointing.documentReads = 0
            let perception = MacPerception(schedule: Schedule())
            let span = perception.sampleFixture()
            try expect(span.app == fixture.name, "App name missing: \(fixture.name)")
            try expect(span.title == (fixture.allowed ? fixture.title : nil), "Title policy mismatch: \(fixture.name)")
            try expect(span.path == fixture.expectedPath, "Ambient path policy mismatch: \(fixture.name), got \(span.path ?? "nil")")
            try expect(fixture.allowed || Pointing.documentReads == 0, "Read a private document attribute: \(fixture.name)")

            // Exercise the real persistence and summary paths using only synthetic spans.
            perception.finishFixture()
            let log = try String(contentsOf: TildeHome.default.state.appending(path: "activity.jsonl"), encoding: .utf8)
            let stored = try JSONDecoder().decode(MacPerception.Span.self, from: Data(log.trimmingCharacters(in: .newlines).utf8))
            try expect(stored.app == fixture.name && stored.path == fixture.expectedPath, "Persisted metadata mismatch: \(fixture.name)")
            let summary = perception.recentActivity(hours: 3)
            try expect(summary.contains(fixture.name), "Summary lost the app name: \(fixture.name)")
            if let path = fixture.expectedPath {
                try expect(summary.contains(path), "Summary lost allowed work context: \(fixture.name)")
            } else {
                try expect(!summary.contains("/synthetic/"), "Summary exposed private path: \(fixture.name)")
            }
        }
        print("Passed \(cases.count) synthetic ambient collection, persistence, and summary cases.")
    }

    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
}
