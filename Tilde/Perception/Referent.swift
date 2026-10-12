import AppKit
import ApplicationServices
import TildeKit

/// The thing under the cursor when you tap: what the Lens outlines and what
/// "this" means to the manager.
nonisolated struct Referent: Equatable, Sendable {
    var app: String
    var bundleID: String?
    var pid: pid_t
    /// Screen rect of what's outlined (Cocoa coordinates).
    var frame: CGRect
    var label: String
    var windowTitle: String?
    var document: String?
    var cwd: String?
    var repo: String?
    var selection: String?
    /// The job whose ribbon or card was pointed at.
    var jobID: String?

    var context: TapContext {
        TapContext(
            app: app, bundleID: bundleID, windowTitle: windowTitle, document: document, cwd: cwd, repo: repo,
            pointing: label, text: selection, jobID: jobID)
    }
}

/// Reads what's under a point through the Accessibility API.
nonisolated enum Pointing {
    /// Values captured before tilde takes focus. No AppKit or AX objects cross actors.
    struct Application: Sendable {
        let name: String
        let bundleID: String?
        let pid: pid_t
    }

    struct Request: Sendable {
        let application: Application
        /// A point in Quartz coordinates, scoped to the application that owned it at capture time.
        let point: CGPoint?
        let fallback: Application?
        let coordinates: Coordinates.Snapshot
        let includeSelection: Bool
    }

    static let terminals: Set<String> = [
        "com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.github.wez.wezterm",
        "net.kovidgoyal.kitty", "org.alacritty",
    ]

    static var isTrusted: Bool { AXIsProcessTrusted() }

    @MainActor static func requestTrust() {
        // kAXTrustedCheckOptionPrompt's value; the constant itself is a mutable global.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Blocking AX and process work. Call through ContextCapture on interactive paths.
    static func capture(_ request: Request) -> Referent? {
        guard !Task.isCancelled else { return nil }
        if let result = referent(in: request.application, at: request.point, request: request) { return result }
        guard !Task.isCancelled, let fallback = request.fallback else { return nil }
        return referent(in: fallback, at: nil, request: request)
    }

    private static func referent(in app: Application, at point: CGPoint?, request: Request) -> Referent? {
        var hit: AXUIElement?
        if let point {
            // The global hit test could now hit tilde, or a newly activated app. The original
            // application's hierarchy keeps the request tied to what the user pointed at.
            let application = AXUIElementCreateApplication(app.pid)
            guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit) == .success else { return nil }
        }
        let window = hit.flatMap { ancestor(of: $0, role: kAXWindowRole) } ?? focusedWindow(app.pid)
        guard let window, !Task.isCancelled else { return nil }
        let element = hit ?? window
        let windowTitle = string(window, kAXTitleAttribute)
        var document = string(window, kAXDocumentAttribute).flatMap(path(fromURL:))
        var frame = frameOf(window, coordinates: request.coordinates) ?? .zero
        let name = app.name
        var label = [windowTitle.map { Titles.short($0, app: name) }, name].compactMap { $0 }.joined(separator: " · ")
        var selection: String?

        // A file under the cursor (Finder, open panels, sidebars).
        if point != nil, let url = firstAncestorValue(of: element, kAXURLAttribute), let file = path(fromURL: url) {
            document = file
            if let row = ancestor(of: element, role: kAXRowRole) ?? ancestor(of: element, role: "AXGroup"),
                let rowFrame = frameOf(row, coordinates: request.coordinates),
                rowFrame.width < frame.width * 0.9
            {
                frame = rowFrame
            }
            label = "\((file as NSString).lastPathComponent) · \(name)"
        }

        // Selected text in what you're pointing at.
        if request.includeSelection, let text = string(element, kAXSelectedTextAttribute) ?? focusedSelection(app.pid),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            selection = text
            let lines = text.split(separator: "\n").count
            label = "Selection (\(lines) line\(lines == 1 ? "" : "s"))\(document.map { " in \(($0 as NSString).lastPathComponent)" } ?? "") · \(name)"
        }

        var cwd: String?
        guard !Task.isCancelled else { return nil }
        if let bundle = app.bundleID, terminals.contains(bundle) {
            cwd = Shells.cwd(forTerminal: app.pid, title: windowTitle)
            if let cwd { label = "\((cwd as NSString).abbreviatingWithTildeInPath) · \(name)" }
        }
        let repo = Repos.root(containing: document ?? cwd)

        return Referent(
            app: name, bundleID: app.bundleID, pid: app.pid, frame: frame, label: label, windowTitle: windowTitle,
            document: document, cwd: cwd, repo: repo, selection: selection.map { String($0.prefix(8_000)) })
    }

    /// The frontmost app's focused window, as a referent (for typed taps with no pointing).
    @MainActor static func frontmost() -> Referent? {
        ContextCapture.snapshot(includeSelection: true).flatMap(capture)
    }

    // MARK: AX helpers

    static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        return element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
    }

    static func focusedSelection(_ pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        return element(app, kAXFocusedUIElementAttribute).flatMap { string($0, kAXSelectedTextAttribute) }
    }

    static func frameOf(_ element: AXUIElement, coordinates: Coordinates.Snapshot) -> CGRect? {
        var position = CGPoint.zero, size = CGSize.zero
        guard let p = value(element, kAXPositionAttribute), let s = value(element, kAXSizeAttribute),
            AXValueGetValue(p as! AXValue, .cgPoint, &position), AXValueGetValue(s as! AXValue, .cgSize, &size)
        else { return nil }
        return coordinates.cocoa(CGRect(origin: position, size: size))
    }

    static func ancestor(of element: AXUIElement, role: String, depth: Int = 12) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<depth {
            guard let node = current else { return nil }
            if string(node, kAXRoleAttribute) == role { return node }
            current = self.element(node, kAXParentAttribute)
        }
        return nil
    }

    static func firstAncestorValue(of element: AXUIElement, _ attribute: String, depth: Int = 4) -> CFTypeRef? {
        var current: AXUIElement? = element
        for _ in 0..<depth {
            guard let node = current else { return nil }
            if let found = value(node, attribute) { return found }
            current = self.element(node, kAXParentAttribute)
        }
        return nil
    }

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        guard !Task.isCancelled else { return nil }
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let found = value(element, attribute), CFGetTypeID(found) == AXUIElementGetTypeID() else { return nil }
        return (found as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func path(fromURL value: Any) -> String? {
        if let url = value as? URL, url.isFileURL { return url.path }
        if let text = value as? String, let url = URL(string: text), url.isFileURL { return url.path }
        return nil
    }
}

/// Finds the git repo a path sits in, by walking up to a `.git`.
nonisolated enum Repos {
    static func root(containing path: String?) -> String? {
        guard var url = path.map({ URL(fileURLWithPath: $0) }) else { return nil }
        let fm = FileManager.default
        for _ in 0..<12 {
            if fm.fileExists(atPath: url.appending(path: ".git").path) { return url.path }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return nil
    }
}

nonisolated enum Titles {
    /// Window titles can be long ("ContentView.swift", a dash, "paradise", a dash, "Edited"); keep the
    /// meaningful head. Browsers end theirs with their own name ("Inbox - Google Chrome - Work"),
    /// which the label already says.
    static func short(_ title: String, app: String? = nil) -> String {
        var head = title.components(separatedBy: " \u{2014} ").first ?? title
        if let app, let suffix = [" - \(app)", " \u{2013} \(app)"].lazy.compactMap({ head.range(of: $0) }).first {
            head = String(head[..<suffix.lowerBound])
        }
        return head.count > 40 ? String(head.prefix(39)) + "…" : head
    }
}
