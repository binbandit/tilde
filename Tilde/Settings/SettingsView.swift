import ServiceManagement
import SwiftUI
import TildeKit

/// tilde's only window: where it lives, and how you talk to it.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(InletEdge.builtInKey) private var builtInEdge: InletEdge = .top
    @AppStorage(InletEdge.externalKey) private var externalEdge: InletEdge = .right
    @AppStorage(InletPlacement.displayKey) private var display = ""
    @AppStorage("trigger") private var trigger = "doubleOption"
    @State private var screens = NSScreen.screens
    /// macOS owns launch at login; this is what it last said.
    @State private var loginItem = SMAppService.mainApp.status
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("tilde") {
                LabeledContent("Notebook", value: model.conductor?.memory.notebook.path ?? "-")
                ForEach(Permission.allCases, id: \.self) { permission in
                    LabeledContent {
                        if permission.granted {
                            Text("Allowed")
                        } else {
                            Button("Allow…") { permission.open() }
                        }
                    } label: {
                        Text(permission.name)
                        Text(permission.granted ? "" : "Needed \(permission.why)")
                    }
                }
                if let error = model.startupError {
                    Text(error).foregroundStyle(Theme.failed)
                }
            }
            Section {
                // Waiting for approval counts as on: switching it off withdraws the request.
                Toggle("Launch at login", isOn: Binding {
                    loginItem == .enabled || loginItem == .requiresApproval
                } set: { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginItemError = nil
                    } catch {
                        loginItemError = error.localizedDescription
                    }
                    loginItem = SMAppService.mainApp.status
                })
                if loginItem == .requiresApproval {
                    Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let loginItemError {
                    Text("Couldn't change launch at login: \(loginItemError)")
                        .foregroundStyle(Theme.failed)
                }
            } header: {
                Text("Startup")
            } footer: {
                if loginItem == .requiresApproval {
                    Text("tilde won't open at login until you allow it in Login Items.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Display", selection: connectedDisplay) {
                    Text("Automatic").tag("")
                    ForEach(screens.compactMap(\.uuid), id: \.self) { uuid in
                        Text(screens.first { $0.uuid == uuid }?.localizedName ?? uuid).tag(uuid)
                    }
                }
                Picker("On the built-in display", selection: $builtInEdge) { edges }
                Picker("On external displays", selection: $externalEdge) { edges }
            } header: {
                Text("Where tilde lives")
            } footer: {
                Text("Automatic uses the built-in display while the lid is open, and the main display when it's closed. At the top, tilde becomes part of the notch, or hangs from the menu bar on a display without one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            InletPreferencesSection()
            SourcesSection()
            Section {
                Picker("Talk to tilde", selection: $trigger) {
                    ForEach(Trigger.allCases, id: \.self) { Text(label($0)).tag($0.rawValue) }
                }
            } header: {
                Text("Talking")
            } footer: {
                Text("Point at something and \((Trigger(rawValue: trigger) ?? .doubleOption).hint). Rest the pointer on tilde to see everything it's doing. Open Settings from the tilde menu in the menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 660)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
        // Approval happens in System Settings, so look again whenever tilde comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem = SMAppService.mainApp.status
        }
    }

    private var edges: some View {
        ForEach(InletEdge.allCases) { Text($0.label).tag($0) }
    }

    /// The chosen display while it's connected; Automatic otherwise, keeping
    /// the choice for when it comes back.
    private var connectedDisplay: Binding<String> {
        Binding {
            screens.contains { $0.uuid == display } ? display : ""
        } set: {
            display = $0
        }
    }

    private func label(_ trigger: Trigger) -> String {
        switch trigger {
        case .doubleOption: "Double-tap ⌥ (hold the second tap to talk)"
        case .doubleCommand: "Double-tap ⌘"
        case .doubleControl: "Double-tap ⌃"
        case .rightOption: "Right ⌥ (tap or hold)"
        case .rightCommand: "Right ⌘ (tap or hold)"
        case .fn: "Fn / 🌐 (tap or hold)"
        }
    }
}
