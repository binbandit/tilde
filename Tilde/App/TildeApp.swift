import SwiftUI

@main
struct TildeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            StatusMenu()
        } label: {
            Image(nsImage: StatusMenu.icon)
                .accessibilityLabel("tilde")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView().environment(delegate.model)
        }
    }
}
