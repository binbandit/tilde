import Foundation

/// The environment the user's terminal would have.
///
/// tilde starts from launchd with a bare PATH, so tools installed through
/// Homebrew, mise, bun, or ~/.local/bin would be invisible to the agents
/// it launches. We ask the login shell once and reuse the answer.
public final class UserEnvironment: Sendable {
    public static let shared = UserEnvironment()

    public let variables: [String: String]

    init() {
        var env = ProcessInfo.processInfo.environment
        // Never leak our own host's agent context into the agents we launch.
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") {
            env.removeValue(forKey: key)
        }
        if let path = UserEnvironment.loginPath(shell: env["SHELL"] ?? "/bin/zsh") {
            env["PATH"] = path
        }
        let home = NSHomeDirectory()
        let fallback = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (existing + fallback.filter { !existing.contains($0) }).joined(separator: ":")
        env["HOME"] = env["HOME"] ?? home
        variables = env
    }

    private static func loginPath(shell: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // `env` prints the exported, colon-joined PATH in every shell (fish
        // stores PATH as a list, so echoing "$PATH" there joins with spaces).
        process.arguments = ["-l", "-c", "/usr/bin/env"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return nil }
        let env = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return env.split(separator: "\n").first { $0.hasPrefix("PATH=") }.map { String($0.dropFirst(5)) }
    }
}
