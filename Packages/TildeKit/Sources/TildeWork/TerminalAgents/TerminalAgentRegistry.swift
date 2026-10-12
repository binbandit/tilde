import Foundation
import TildeSupport

/// An opt-in registry and a bounded local inbox of the latest lifecycle event per
/// terminal session. No listener, agent connection, transcript reader, or model call.
public struct TerminalAgentRegistry: Sendable {
    public let home: TildeHome
    public static let maximumRegistrations = 128
    public static let maximumSessions = 512
    public static let retention: TimeInterval = 24 * 60 * 60

    public init(home: TildeHome = .default) { self.home = home }

    public func registrations() throws -> [TerminalAgentRegistration] {
        try withStore(create: false) { try readRegistrations($0) } ?? []
    }

    /// Explicit opt-in for one harness in one project. This merges only the
    /// observer's commands into the project config, never changes hook trust,
    /// permissions, sandbox settings, user-level config, or unrelated hooks.
    @discardableResult
    public func register(project: String, adapter: TerminalAgentAdapter, executable: String,
                         now: Date = .now) throws -> TerminalAgentRegistration {
        guard TerminalAgentEvent.validPath(project), TerminalAgentEvent.validPath(executable) else {
            throw TerminalAgentError.invalidProject
        }
        let canonical = URL(fileURLWithPath: project).resolvingSymlinksInPath().path
        guard canonical != "/", canonical != URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path else {
            throw TerminalAgentError.invalidProject
        }
        let program = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: program, isDirectory: &isDirectory), !isDirectory.boolValue,
            FileManager.default.isExecutableFile(atPath: program)
        else { throw TerminalAgentError.unsafeFile }
        let projectDirectory = try TerminalAgentDirectory(path: canonical)
        return try withStore(create: true) { store in
            var entries = try readRegistrations(store)
            let old = entries.first { $0.project == canonical && $0.adapter == adapter }
            guard old != nil || entries.count < Self.maximumRegistrations else { throw TerminalAgentError.limitExceeded }
            let registration = TerminalAgentRegistration(
                id: old?.id ?? UUID(), adapter: adapter, project: canonical, executable: program, createdAt: old?.createdAt ?? now)
            let components = adapter.configPath.split(separator: "/").map(String.init)
            guard let configDirectory = try projectDirectory.child(components[0], create: true) else { throw TerminalAgentError.unsafeFile }
            let original = try configDirectory.read(components[1], limit: TerminalAgentHooks.maximumConfigBytes)
            let merged = try TerminalAgentHooks.merge(original, registration: registration, home: home, removing: old, install: true)
            let previous = entries
            entries.removeAll { $0.id == registration.id }
            entries.append(registration)
            try store.write(try JSONEncoder().encode(entries), to: "registrations.json")
            do {
                try configDirectory.write(merged, to: components[1])
            } catch {
                // If rollback fails, the registration is harmless without a hook.
                try? store.write(try JSONEncoder().encode(previous), to: "registrations.json")
                throw error
            }
            return registration
        }!
    }

    /// Revoke ingress first. Even if someone edited the project config or made it
    /// inaccessible, a leftover hook command cannot record any further events.
    public func unregister(id: UUID) throws {
        _ = try withStore(create: false) { store in
            var entries = try readRegistrations(store)
            guard let registration = entries.first(where: { $0.id == id }) else { return }
            entries.removeAll { $0.id == id }
            try store.write(try JSONEncoder().encode(entries), to: "registrations.json")
            let remaining = try readSessions(store).filter { $0.registrationID != id }
            try store.write(try JSONEncoder().encode(remaining), to: "inbox.json")
            let projectDirectory = try TerminalAgentDirectory(path: registration.project)
            let components = registration.adapter.configPath.split(separator: "/").map(String.init)
            guard let configDirectory = try projectDirectory.child(components[0], create: false),
                let original = try configDirectory.read(components[1], limit: TerminalAgentHooks.maximumConfigBytes)
            else { return }
            let merged = try TerminalAgentHooks.merge(original, registration: registration, home: home, removing: nil, install: false)
            try configDirectory.write(merged, to: components[1])
        }
    }

    /// The only event ingress. Registration binds the adapter and allowed project;
    /// payload fields cannot select either the adapter or a destination on disk.
    public func receive(_ data: Data, registrationID: UUID, now: Date = .now) throws {
        guard data.count <= TerminalAgentEvent.maximumBytes else { throw TerminalAgentError.limitExceeded }
        let received: Bool? = try withStore(create: false) { store in
            let entries = try readRegistrations(store)
            guard let registration = entries.first(where: { $0.id == registrationID }) else { throw TerminalAgentError.unregistered }
            let event = try TerminalAgentEvent.parse(data, registration: registration, now: now)
            var sessions = try validSessions(store, entries: entries, now: now)
            sessions.removeAll { $0.id == event.id }
            sessions.append(event)
            sessions.sort { $0.updatedAt > $1.updatedAt }
            try store.write(try JSONEncoder().encode(Array(sessions.prefix(Self.maximumSessions))), to: "inbox.json")
            return true
        }
        guard received == true else { throw TerminalAgentError.unregistered }
    }

    /// Latest observations from active registrations, retained for one day. The
    /// caller should label old observations with isStale, not claim liveness.
    public func sessions(now: Date = .now) throws -> [TerminalAgentSession] {
        try withStore(create: false) { store in
            try validSessions(store, entries: readRegistrations(store), now: now).sorted { $0.updatedAt > $1.updatedAt }
        } ?? []
    }

    private func validSessions(_ store: TerminalAgentDirectory, entries: [TerminalAgentRegistration], now: Date) throws -> [TerminalAgentSession] {
        let registrations = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return try readSessions(store).filter { session in
            guard let registration = registrations[session.registrationID] else { return false }
            return session.adapter == registration.adapter && session.project == registration.project
                && TerminalAgentEvent.validSession(session.session) && TerminalAgentEvent.validPath(session.cwd)
                && Paths.isInside(session.cwd, registration.project)
                && session.updatedAt <= now && now.timeIntervalSince(session.updatedAt) <= Self.retention
        }
    }

    private func readRegistrations(_ store: TerminalAgentDirectory) throws -> [TerminalAgentRegistration] {
        guard let data = try store.read("registrations.json", limit: 2 * 1024 * 1024, privateOnly: true) else { return [] }
        guard let entries = try? JSONDecoder().decode([TerminalAgentRegistration].self, from: data),
            entries.count <= Self.maximumRegistrations, Set(entries.map(\.id)).count == entries.count,
            entries.allSatisfy({ TerminalAgentEvent.validPath($0.project) && TerminalAgentEvent.validPath($0.executable) })
        else { throw TerminalAgentError.invalidConfiguration }
        return entries
    }

    private func readSessions(_ store: TerminalAgentDirectory) throws -> [TerminalAgentSession] {
        guard let data = try store.read("inbox.json", limit: 8 * 1024 * 1024, privateOnly: true) else { return [] }
        guard let sessions = try? JSONDecoder().decode([TerminalAgentSession].self, from: data), sessions.count <= Self.maximumSessions else {
            throw TerminalAgentError.invalidInput
        }
        return sessions
    }

    private func withStore<T>(create: Bool, _ action: (TerminalAgentDirectory) throws -> T) throws -> T? {
        let path = home.root.resolvingSymlinksInPath().path
        if create {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } else if !FileManager.default.fileExists(atPath: path) { return nil }
        let root = try TerminalAgentDirectory(path: path)
        guard let state = try root.child("state", create: create),
            let store = try state.child("terminal-agents", create: create, privateOnly: true)
        else { return nil }
        return try store.locked { try action(store) }
    }
}
