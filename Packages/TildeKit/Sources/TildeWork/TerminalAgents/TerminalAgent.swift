import Foundation
import TildeSupport
import WorkerKit

/// Passive, project-scoped adapters. A harness having ACP or a JSON stream does
/// not imply that another client can observe its already-running terminal.
public enum TerminalAgentAdapter: String, Codable, CaseIterable, Sendable {
    case claude, codex, gemini

    public var harness: Harness { Harness(rawValue: rawValue) }
    public var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        }
    }

    public var configPath: String {
        switch self {
        case .claude: ".claude/settings.local.json"
        case .codex: ".codex/hooks.json"
        case .gemini: ".gemini/settings.json"
        }
    }

    var events: [String] {
        switch self {
        case .claude: ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd"]
        case .codex: ["SessionStart", "UserPromptSubmit", "Stop", "Interrupt", "SessionEnd"]
        case .gemini: ["SessionStart", "BeforeAgent", "AfterAgent", "SessionEnd"]
        }
    }

    public var setupNote: String {
        switch self {
        case .claude: "Restart the project session and review the hooks in /hooks. Managed policy may disable local hooks."
        case .codex: "Open /hooks in a trusted project and trust these exact hooks. Disabled hooks stay disabled."
        case .gemini: "Restart the project session and review Gemini's project hook trust prompt. Disabled hooks stay disabled."
        }
    }
}

public struct TerminalAgentRegistration: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let adapter: TerminalAgentAdapter
    public let project: String
    public let executable: String
    public let createdAt: Date
    public var configPath: String { project + "/" + adapter.configPath }
}

public struct TerminalAgentSession: Codable, Identifiable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case started, working, waiting, failed, interrupted, ended
    }

    public let registrationID: UUID
    public let adapter: TerminalAgentAdapter
    public let session: String
    public let project: String
    public let cwd: String
    public let state: State
    public let updatedAt: Date
    public var id: String { registrationID.uuidString + ":" + session }
    public var harness: Harness { adapter.harness }

    /// Hooks are observations, not a heartbeat. A crashed CLI may never send SessionEnd.
    public func isStale(now: Date = .now) -> Bool { now.timeIntervalSince(updatedAt) > 30 * 60 }
}

public enum TerminalAgentError: Error, LocalizedError, Sendable {
    case invalidInput, unsupportedEvent, unregistered, outsideProject, invalidProject
    case invalidConfiguration, unsafeFile, storeBusy, limitExceeded, io(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidInput: "Invalid terminal agent event."
        case .unsupportedEvent: "This lifecycle event is not supported."
        case .unregistered: "Terminal discovery is not enabled for this registration."
        case .outsideProject: "The event is outside the registered project."
        case .invalidProject: "Choose an existing project directory, not your home directory or the filesystem root."
        case .invalidConfiguration: "Existing hook configuration is malformed; it was left unchanged."
        case .unsafeFile: "A hook or state path is a symlink, is not owned by you, or is unsafe to write."
        case .storeBusy: "Terminal discovery is busy. Try again."
        case .limitExceeded: "Terminal discovery input or storage limit exceeded."
        case .io(let code): "Terminal discovery file operation failed (\(code))."
        }
    }
}

enum TerminalAgentEvent {
    static let maximumBytes = 64 * 1024

    /// Only these fields are decoded. Prompts, tool inputs, output, credentials,
    /// transcript paths and vendor-supplied timestamps never enter the inbox.
    private struct Input: Decodable {
        let session_id: String
        let cwd: String
        let hook_event_name: String
        let agent_id: String?
    }

    static func parse(_ data: Data, registration: TerminalAgentRegistration, now: Date) throws -> TerminalAgentSession {
        guard data.count <= maximumBytes else { throw TerminalAgentError.limitExceeded }
        guard let input = try? JSONDecoder().decode(Input.self, from: data),
            validSession(input.session_id), validPath(input.cwd), input.agent_id == nil
        else { throw TerminalAgentError.invalidInput }
        guard registration.adapter.events.contains(input.hook_event_name) else { throw TerminalAgentError.unsupportedEvent }
        guard Paths.isInside(input.cwd, registration.project) else { throw TerminalAgentError.outsideProject }
        let state: TerminalAgentSession.State
        switch input.hook_event_name {
        case "SessionStart": state = .started
        case "UserPromptSubmit", "BeforeAgent": state = .working
        case "Stop", "AfterAgent": state = .waiting
        case "StopFailure": state = .failed
        case "Interrupt": state = .interrupted
        case "SessionEnd": state = .ended
        default: throw TerminalAgentError.unsupportedEvent
        }
        return TerminalAgentSession(
            registrationID: registration.id, adapter: registration.adapter, session: input.session_id,
            project: registration.project, cwd: URL(fileURLWithPath: input.cwd).resolvingSymlinksInPath().path,
            state: state, updatedAt: now)
    }

    static func validSession(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0) }
    }

    static func validPath(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 4096 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
