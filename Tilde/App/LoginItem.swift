import ServiceManagement
import TildeKit

/// Only an explicit toggle registers the running app. Opening Settings just reads macOS state.
enum LoginItem {
    static func makeState() -> LaunchAtLogin {
        LaunchAtLogin {
            switch SMAppService.mainApp.status {
            case .notRegistered: .notRegistered
            case .enabled: .enabled
            case .requiresApproval: .requiresApproval
            case .notFound: .notFound
            @unknown default: .unknown
            }
        } register: {
            try SMAppService.mainApp.register()
        } unregister: {
            try await SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
