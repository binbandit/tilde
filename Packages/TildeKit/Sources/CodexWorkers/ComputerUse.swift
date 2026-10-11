import Foundation
import TildeSupport

/// Codex's computer use, as a harness (`CodexHarnesses.computerUse`): a Codex worker briefed to operate this
/// Mac's apps through the GUI, for work that has no API or that has to be seen
/// to be checked (an app's UI, a simulator, a web flow).
///
/// It shares the user's screen, so it's fenced twice: apps that hold mail,
/// messages, money or secrets are denied in Codex's own config, and every
/// app-access prompt comes to the manager, marked as a rail when it names
/// something sensitive.
enum ComputerUse {
    static let brief = """
        You can operate this Mac's apps with your computer use tool. The owner may be using the computer at the same time:
        - Prefer the CLI and files when they can do the job; use the GUI for what only the GUI can show or do.
        - Keep it brief and targeted. Don't rearrange windows or leave apps in a different state than you found them.
        - Never send messages or email, buy anything, change account or security settings, or enter credentials.
        - Report what you saw, with specifics (what was on screen, what worked, what didn't).
        """

    /// Apps computer use may not touch at all.
    static let denied = [
        "com.apple.mail", "com.apple.MobileSMS", "com.apple.iChat", "com.apple.facetime", "com.apple.keychainaccess",
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.Passwords",
        "com.apple.systempreferences", "com.apple.Wallet", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
        "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram",
        // Terminals are a shell with none of a worker's sandbox.
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "org.alacritty", "com.github.wez.wezterm",
    ]

    static let config: JSON = [
        "features": ["computer_use": true],
        "computer_use": ["macos": ["bundle_ids": .object(Dictionary(uniqueKeysWithValues: denied.map { ($0, "deny") }))]],
    ]

    private static let sensitive = [
        "mail", "message", "imessage", "slack", "discord", "whatsapp", "telegram", "bank", "pay", "wallet", "password",
        "keychain", "1password", "bitwarden", "settings", "purchase", "buy", "checkout", "send", "post", "delete",
    ]

    /// Why an app-access prompt deserves the owner's eyes, if it does.
    static func rail(for message: String) -> String? {
        let lowered = message.lowercased()
        return sensitive.first { lowered.contains($0) }.map { "Computer use touching something sensitive (\($0))" }
    }
}
