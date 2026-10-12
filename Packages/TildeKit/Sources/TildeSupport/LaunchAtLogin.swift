import Foundation
import Observation

/// The operating system owns this preference. Never persist an optimistic local copy.
@MainActor @Observable
public final class LaunchAtLogin {
    public enum Status: Sendable {
        case notRegistered, enabled, requiresApproval, notFound, unknown
    }

    public private(set) var status: Status
    public private(set) var isUpdating = false
    public private(set) var error: String?

    @ObservationIgnored private let readStatus: @MainActor () -> Status
    @ObservationIgnored private let register: @MainActor () async throws -> Void
    @ObservationIgnored private let unregister: @MainActor () async throws -> Void

    public init(
        readStatus: @escaping @MainActor () -> Status,
        register: @escaping @MainActor () async throws -> Void,
        unregister: @escaping @MainActor () async throws -> Void
    ) {
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
        status = readStatus()
    }

    /// A pending registration can be cancelled, but is not yet eligible to launch.
    public var isRegistered: Bool { status == .enabled || status == .requiresApproval }
    public var isEnabled: Bool { status == .enabled }

    public func refresh() {
        let current = readStatus()
        if current != status { error = nil }
        status = current
    }

    public func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        refresh()
        error = nil
        if enabled && isRegistered || !enabled && status == .notRegistered { return }

        isUpdating = true
        defer {
            // Preserve an error from this attempt even if the service partly changed state.
            status = readStatus()
            isUpdating = false
        }
        do {
            if enabled { try await register() }
            else { try await unregister() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
