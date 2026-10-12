import Darwin
import Foundation
import TildeSupport
import TildeWork

/// No agent process is launched. Receive is always observational: empty JSON,
/// exit 0, no permission verdict or context even when input is rejected.
@main struct TildeAgentHook {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let receiving = args.first == "receive"
        do {
            try run(args)
        } catch {
            FileHandle.standardError.write(Data("tilde-agent-hook: \(error.localizedDescription)\n".utf8))
            if !receiving { exit(1) }
        }
        if receiving { print("{}") }
    }

    static func run(_ arguments: [String]) throws {
        var args = arguments
        var home = TildeHome.default
        if let index = args.firstIndex(of: "--home") {
            guard args.indices.contains(index + 1), args[index + 1].hasPrefix("/") else { throw TerminalAgentError.invalidInput }
            home = TildeHome(root: URL(fileURLWithPath: args[index + 1]))
            args.removeSubrange(index...index + 1)
        }
        let registry = TerminalAgentRegistry(home: home)
        switch args.first {
        case "receive":
            guard args.count == 3, args[1] == "--registration", let id = UUID(uuidString: args[2]) else {
                throw TerminalAgentError.invalidInput
            }
            try registry.receive(readInput(), registrationID: id)
        case "install":
            guard args.count == 3, let adapter = TerminalAgentAdapter(rawValue: args[1]), let executable = Bundle.main.executableURL else {
                throw TerminalAgentError.invalidInput
            }
            let registration = try registry.register(project: args[2], adapter: adapter, executable: executable.path)
            print(registration.id.uuidString)
            print(registration.configPath)
            print(adapter.setupNote)
        case "remove":
            guard args.count == 2, let id = UUID(uuidString: args[1]) else { throw TerminalAgentError.invalidInput }
            try registry.unregister(id: id)
            print("Removed terminal discovery registration.")
        case "list":
            guard args.count == 1 else { throw TerminalAgentError.invalidInput }
            print(String(decoding: try JSONEncoder().encode(registry.registrations()), as: UTF8.self))
        case "sessions":
            guard args.count == 1 else { throw TerminalAgentError.invalidInput }
            print(String(decoding: try JSONEncoder().encode(registry.sessions()), as: UTF8.self))
        case "--help", "help", nil:
            print("""
                Usage: tilde-agent-hook install <claude|codex|gemini> /absolute/project [--home /absolute/tilde-home]
                       tilde-agent-hook remove <registration-id> [--home /absolute/tilde-home]
                       tilde-agent-hook list|sessions [--home /absolute/tilde-home]
                       tilde-agent-hook receive --registration <id> [--home /absolute/tilde-home]
                Install changes only this project's hook configuration. Review hooks in the agent before use.
                No user-level hooks, transcripts, permissions, credentials, or agent control are accessed.
                """)
        default: throw TerminalAgentError.invalidInput
        }
    }

    /// Bound both bytes and waiting time, even if a caller keeps stdin open.
    static func readInput() throws -> Data {
        let limit = 64 * 1024
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw TerminalAgentError.invalidInput }
            var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&input, 1, Int32(remaining * 1000))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw TerminalAgentError.invalidInput }
            let count = Darwin.read(STDIN_FILENO, &buffer, min(buffer.count, limit + 1 - data.count))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw TerminalAgentError.invalidInput }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw TerminalAgentError.limitExceeded }
        }
    }
}
