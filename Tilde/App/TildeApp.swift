import SwiftUI

@main
struct TildeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView().environment(delegate.model)
        }
    }
}
