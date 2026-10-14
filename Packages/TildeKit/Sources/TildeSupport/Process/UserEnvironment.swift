import Foundation

/// The environment the user's terminal would have.
///
/// tilde starts from launchd with a bare environment: no PATH for tools installed through
/// Homebrew, mise, bun, or ~/.local/bin, and none of the API keys your shell config exports, so
/// agents launched from a tilde opened in Finder or at login couldn't find their tools or sign in.
/// We ask your login shell once, started as a terminal starts it, and take everything it exports.
public final class UserEnvironment: Sendable {
    public static let shared = UserEnvironment()

    public let variables: [String: String]

    init() {
        var env = ProcessInfo.processInfo.environment
        if let login = UserEnvironment.login(shell: UserEnvironment.accountShell) {
            env.merge(login) { $1 }
        }
        // Never leak our own host's agent context into the agents we launch, nor the shell's bookkeeping.
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || ["_", "SHLVL", "PWD", "OLDPWD"].contains(key) {
            env.removeValue(forKey: key)
        }
        let home = NSHomeDirectory()
        let fallback = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (existing + fallback.filter { !existing.contains($0) }).joined(separator: ":")
        env["HOME"] = env["HOME"] ?? home
        variables = env
    }

    /// The shell your account logs in with, which is what a terminal starts. launchd's $SHELL
    /// can be missing or stale.
    static var accountShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell, shell.pointee != 0 {
            return String(cString: shell)
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// What `shell` exports as an interactive login shell, so a zsh user's .zshrc counts as it does
    /// in a terminal. A config that replaces the interactive shell (`exec fish` in .zshrc) leaves
    /// nothing behind, so a plain login shell is the second try. The environment goes to a private
    /// file rather than a pipe: whatever the config prints can't garble it, and a background
    /// process the config leaves holding stdout can't keep us waiting.
    static func login(shell: String, timeout: TimeInterval = 10) -> [String: String]? {
        let file = FileManager.default.temporaryDirectory.appending(path: "tilde-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let command = "/usr/bin/env -0 > '\(file.path)'"
        for flags in [["-i", "-l"], ["-l"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = flags + ["-c", command]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline { usleep(20_000) }
            if process.isRunning {
                process.terminate()
                return nil
            }
            // NUL-separated, so values with newlines in them survive.
            if let data = try? Data(contentsOf: file), !data.isEmpty {
                let pairs = data.split(separator: 0).compactMap { entry -> (String, String)? in
                    let text = String(decoding: entry, as: UTF8.self)
                    guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { return nil }
                    return (String(text[..<equals]), String(text[text.index(after: equals)...]))
                }
                return Dictionary(pairs) { $1 }
            }
        }
        return nil
    }
}
