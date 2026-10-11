import Foundation

/// Which window titles tilde keeps in its record of your day: the ones about work. In every other app
/// (messages, mail, media, a browser on anything but development) it notes the app and nothing of
/// what's in it, so the journal never learns what you watched or who you talked to.
enum WorkTitles {
    static let editors: Set<String> = [
        "com.apple.dt.Xcode", "dev.zed.Zed", "dev.zed.Zed-Preview", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.sublimetext.4", "com.panic.Nova", "com.github.GitHubClient",
        "com.sublimemerge", "com.fournova.Tower3", "com.apple.dt.Instruments", "com.apple.iphonesimulator",
    ]

    static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox", "com.brave.Browser",
        "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.openai.atlas", "app.zen-browser.zen",
    ]

    /// A browser tab worth naming: something about building software.
    private static let devPages = "github|gitlab|bitbucket|localhost|127\\.0\\.0\\.1|linear|vercel|netlify|stack ?overflow|developer|docs|api reference|swagger|sentry|grafana|datadog"

    static func keep(_ title: String?, bundle: String?) -> String? {
        guard let title, let bundle else { return nil }
        if Pointing.terminals.contains(bundle) || editors.contains(bundle) || bundle.hasPrefix("com.jetbrains.") { return title }
        if browsers.contains(bundle), title.range(of: devPages, options: [.regularExpression, .caseInsensitive]) != nil { return title }
        return nil
    }
}
