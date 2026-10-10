import AppKit
import ApplicationServices
import TildeKit

/// The thing under the cursor when you tap: what the Lens outlines and what
/// "this" means to the manager.
struct Referent: Equatable {
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
enum Pointing {
    static let terminals: Set<String> = [
        "com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.github.wez.wezterm",
        "net.kovidgoyal.kitty", "org.alacritty",
    ]

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        // kAXTrustedCheckOptionPrompt's value; the constant itself is a mutable global.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// What's under `point` (Cocoa coordinates). Points at a selection, a file,
    /// or otherwise the whole window: the granularity people mean by "this".
    static func referent(at point: CGPoint) -> Referent? {
        let quartz = Coordinates.quartz(point)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(quartz.x), Float(quartz.y), &hit) == .success,
            let element = hit
        else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier, let app = NSRunningApplication(processIdentifier: pid) else { return nil }

        let window = ancestor(of: element, role: kAXWindowRole) ?? focusedWindow(pid)
        let windowTitle = window.flatMap { string($0, kAXTitleAttribute) }
        var document = window.flatMap { string($0, kAXDocumentAttribute) }.flatMap(path(fromURL:))
        var frame = window.flatMap(frameOf) ?? .zero
        let name = app.localizedName ?? "App"
        var label = [windowTitle.map { Titles.short($0, app: name) }, name].compactMap { $0 }.joined(separator: " · ")
        var selection: String?

        // A file under the cursor (Finder, open panels, sidebars).
        if let url = firstAncestorValue(of: element, kAXURLAttribute), let file = path(fromURL: url) {
            document = file
            if let row = ancestor(of: element, role: kAXRowRole) ?? ancestor(of: element, role: "AXGroup"), let rowFrame = frameOf(row),
                rowFrame.width < frame.width * 0.9
            {
                frame = rowFrame
            }
            label = "\((file as NSString).lastPathComponent) · \(name)"
        }

        // Selected text in what you're pointing at.
        if let text = string(element, kAXSelectedTextAttribute) ?? focusedSelection(pid), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selection = text
            let lines = text.split(separator: "\n").count
            label = "Selection (\(lines) line\(lines == 1 ? "" : "s"))\(document.map { " in \(($0 as NSString).lastPathComponent)" } ?? "") · \(name)"
        }

        var cwd: String?
        if let bundle = app.bundleIdentifier, terminals.contains(bundle) {
            cwd = Shells.cwd(forTerminal: pid, title: windowTitle)
            if let cwd { label = "\((cwd as NSString).abbreviatingWithTildeInPath) · \(name)" }
        }
        let repo = Repos.root(containing: document ?? cwd)

        return Referent(
            app: name, bundleID: app.bundleIdentifier, pid: pid, frame: frame, label: label, windowTitle: windowTitle,
            document: document, cwd: cwd, repo: repo, selection: selection.map { String($0.prefix(8_000)) })
    }

    /// The frontmost app's focused window, as a referent (for typed taps with no pointing).
    static func frontmost() -> Referent? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
            let window = focusedWindow(app.processIdentifier), let frame = frameOf(window)
        else { return nil }
        return referent(at: CGPoint(x: frame.midX, y: frame.maxY - 60)) ?? Referent(
            app: app.localizedName ?? "App", bundleID: app.bundleIdentifier, pid: app.processIdentifier, frame: frame,
            label: app.localizedName ?? "App")
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

    static func frameOf(_ element: AXUIElement) -> CGRect? {
        var position = CGPoint.zero, size = CGSize.zero
        guard let p = value(element, kAXPositionAttribute), let s = value(element, kAXSizeAttribute),
            AXValueGetValue(p as! AXValue, .cgPoint, &position), AXValueGetValue(s as! AXValue, .cgSize, &size)
        else { return nil }
        return Coordinates.cocoa(CGRect(origin: position, size: size))
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
enum Repos {
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

enum Titles {
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
