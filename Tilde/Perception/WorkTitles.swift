import Foundation

/// Which window titles and paths tilde keeps in its record of your day: the ones about work. In every other app
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
        allowsContext(title, bundle: bundle) ? title : nil
    }

    /// The same boundary applies to document paths. A terminal or editor can still have a
    /// useful path when its window has no title; a browser needs a development page title.
    static func allowsContext(_ title: String?, bundle: String?) -> Bool {
        guard let bundle else { return false }
        if Pointing.terminals.contains(bundle) || editors.contains(bundle) || bundle.hasPrefix("com.jetbrains.") { return true }
        guard let title, browsers.contains(bundle) else { return false }
        return title.range(of: devPages, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
