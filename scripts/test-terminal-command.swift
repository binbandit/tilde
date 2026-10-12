import Foundation

@main
struct TerminalCommandTests {
    static func main() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appending(path: "tilde-terminal-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let names = [
            "project with spaces",
            "both 'single' and \"double\" quotes",
            "semi;colon & pipe| and >redirect",
            "literal $(touch substituted) `touch backticked` $HOME * ?",
            "back\\slash\ttab\nnewline\rcarriage",
            "-leading-dash",
        ]
        let command = #"printf '%s\n' "$PWD"; printf '%s\n' 'takeover reached'"#
        for name in names {
            let directory = scratch.appending(path: name)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let shell = TerminalCommand.shell(command, in: directory.path)
            let script = TerminalCommand.appleScript(command, in: directory.path)
            let prefix = "tell application \"Terminal\" to do script "
            precondition(script.hasPrefix(prefix))

            // Evaluate only the literal from the handoff script; this never addresses Terminal.
            let literal = String(script.dropFirst(prefix.count))
            let decoded = try run("/usr/bin/osascript", ["-e", "return \(literal)"], in: scratch)
            precondition(decoded == shell + "\n", "AppleScript changed the shell command for \(name.debugDescription)")

            let output = try run("/bin/zsh", ["-c", shell], in: scratch)
            precondition(output == directory.path + "\ntakeover reached\n", "Shell changed the directory for \(name.debugDescription)")
            precondition(!fm.fileExists(atPath: scratch.appending(path: "substituted").path))
            precondition(!fm.fileExists(atPath: scratch.appending(path: "backticked").path))
        }
        print("Passed \(names.count) terminal path and AppleScript round-trip cases without opening Terminal.")
    }

    static func run(_ executable: String, _ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "Fixture command failed: \(executable)")
        return String(decoding: data, as: UTF8.self)
    }
}
