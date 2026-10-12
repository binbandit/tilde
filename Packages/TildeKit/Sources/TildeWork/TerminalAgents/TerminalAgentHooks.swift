import Foundation
import TildeSupport

enum TerminalAgentHooks {
    static let maximumConfigBytes = 512 * 1024

    static func command(for registration: TerminalAgentRegistration, home: TildeHome) -> String {
        [registration.executable, "receive", "--home", home.root.resolvingSymlinksInPath().path,
            "--registration", registration.id.uuidString].map(quote).joined(separator: " ")
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    /// Add/remove only exact commands from this registration, preserving unrelated
    /// settings, event groups, and other handlers even when they share a group.
    static func merge(_ original: Data?, registration: TerminalAgentRegistration, home: TildeHome,
                      removing old: TerminalAgentRegistration?, install: Bool) throws -> Data {
        guard (original?.count ?? 0) <= maximumConfigBytes else { throw TerminalAgentError.limitExceeded }
        var config: [String: JSON] = [:]
        if let original {
            guard let object = JSON.parse(original)?.object else { throw TerminalAgentError.invalidConfiguration }
            config = object
        }
        if let value = config["hooks"], value.object == nil { throw TerminalAgentError.invalidConfiguration }
        var hooks = config["hooks"]?.object ?? [:]
        let oldCommand = command(for: old ?? registration, home: home)
        for event in registration.adapter.events {
            if let value = hooks[event], value.array == nil { throw TerminalAgentError.invalidConfiguration }
            var groups: [JSON] = []
            for group in hooks[event]?.array ?? [] {
                guard var object = group.object, let handlers = object["hooks"]?.array else {
                    throw TerminalAgentError.invalidConfiguration
                }
                let kept = handlers.filter { $0["command"]?.string != oldCommand }
                // Preserve an originally empty group and any other group metadata.
                if kept.count == handlers.count { groups.append(group) }
                else if !kept.isEmpty { object["hooks"] = .array(kept); groups.append(.object(object)) }
            }
            if install {
                let timeout = registration.adapter == .gemini ? 2000 : 2
                groups.append(["hooks": [["type": "command", "command": .string(command(for: registration, home: home)), "timeout": .number(Double(timeout))]]])
            }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = .array(groups) }
        }
        if hooks.isEmpty { config.removeValue(forKey: "hooks") } else { config["hooks"] = .object(hooks) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let result = try encoder.encode(JSON.object(config))
        guard result.count <= maximumConfigBytes else { throw TerminalAgentError.limitExceeded }
        return result
    }
}
