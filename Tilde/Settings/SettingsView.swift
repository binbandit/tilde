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
                Text("Point at something and \((Trigger(rawValue: trigger) ?? .doubleOption).hint). Rest the pointer on tilde to see everything it's doing, or right-click it for Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        // Tall enough for everything, so nothing hides below a scroll.
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
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
