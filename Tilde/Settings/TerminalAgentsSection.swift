import SwiftUI
import TildeKit

/// Project hooks are installed only after choosing a harness and a project here.
struct TerminalAgentsSection: View {
    @Environment(AppModel.self) private var model
    @State private var adapter: TerminalAgentAdapter = .claude
    @State private var registrations: [TerminalAgentRegistration] = []
    @State private var sessions: [TerminalAgentSession] = []
    @State private var error: String?
    @State private var readError: String?
    @State private var setupNote: String?

    private var registry: TerminalAgentRegistry {
        TerminalAgentRegistry(home: model.conductor?.home ?? .default)
    }

    var body: some View {
        Section {
            Picker("Terminal agent", selection: $adapter) {
                ForEach(TerminalAgentAdapter.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            Button("Connect Project…", action: connect)
            if registrations.isEmpty {
                Text("No projects connected.").foregroundStyle(.secondary)
            }
            ForEach(registrations) { registration in
                LabeledContent {
                    Button("Disconnect") { disconnect(registration) }
                } label: {
                    Text(registration.adapter.name)
                    Text((registration.project as NSString).abbreviatingWithTildeInPath)
                        .textSelection(.enabled)
                }
            }
            if let setupNote { Text(setupNote).foregroundStyle(.secondary) }
            ForEach(sessions.prefix(6)) { session in
                LabeledContent {
                    Text(session.updatedAt, style: .relative)
                        .foregroundStyle(.secondary)
                } label: {
                    Text("\(session.adapter.name): \(stateLabel(session))")
                    Text((session.cwd as NSString).abbreviatingWithTildeInPath)
                }
                .help("Last lifecycle event. tilde cannot control this terminal session.")
            }
            if let error = error ?? readError { Text(error).foregroundStyle(Theme.failed) }
        } header: {
            Text("Terminal agents")
        } footer: {
            Text("Connect a project to add lifecycle hooks for that harness. Approve them in the harness before starting a session. tilde observes session state only, without reading terminal text or taking control. Other harnesses are not supported here.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func refresh() {
        do {
            registrations = try registry.registrations()
            sessions = try registry.sessions()
            readError = nil
        } catch {
            // A hook may briefly hold the store lock. Keep the last observation
            // until the next successful read, and clear only this read error then.
            readError = error.localizedDescription
        }
    }

    private func connect() {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/tilde-agent-hook")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            error = "The terminal hook helper is missing from this app. Build or reinstall tilde before connecting a project."
            return
        }
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.prompt = "Connect Project"
        picker.message = "Add tilde's lifecycle hooks to \(adapter.configPath) in this project. Existing hooks are kept."
        guard picker.runModal() == .OK, let project = picker.url else { return }
        error = nil
        do {
            try registry.register(project: project.path, adapter: adapter, executable: helper.path)
            setupNote = adapter.setupNote
        } catch { self.error = error.localizedDescription }
        refresh()
    }

    private func disconnect(_ registration: TerminalAgentRegistration) {
        error = nil
        setupNote = nil
        do { try registry.unregister(id: registration.id) }
        catch { self.error = error.localizedDescription }
        // Revocation takes effect even if a changed project file prevented hook cleanup.
        refresh()
    }

    private func stateLabel(_ session: TerminalAgentSession) -> String {
        if session.isStale() { return "last observed \(session.state.rawValue), stale" }
        switch session.state {
        case .started: return "session started"
        case .working: return "turn started"
        case .waiting: return "turn ended"
        case .failed: return "turn failed"
        case .interrupted: return "interrupted"
        case .ended: return "session ended"
        }
    }
}
