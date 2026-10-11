import AppKit
import AVFoundation

/// What tilde needs macOS to allow, and where to allow it.
enum Permission: CaseIterable {
    case accessibility, microphone

    var name: String {
        switch self {
        case .accessibility: "Accessibility"
        case .microphone: "Microphone"
        }
    }

    /// What it's for, in a few words.
    var why: String {
        switch self {
        case .accessibility: "to see what you point at"
        case .microphone: "to hear you while you hold the key"
        }
    }

    var granted: Bool {
        switch self {
        case .accessibility: Pointing.isTrusted
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    /// Opens its pane in System Settings.
    func open() {
        let pane = self == .accessibility ? "Privacy_Accessibility" : "Privacy_Microphone"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}
