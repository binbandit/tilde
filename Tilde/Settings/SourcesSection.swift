import SwiftUI
import TildeKit

/// Everything tilde reads to brief you and notice what needs you, and whether
/// it can. All of it is read-only.
struct SourcesSection: View {
    @Environment(AppModel.self) private var model
    @State private var github = "Checking…"
    @State private var refresh = 0

    var body: some View {
        Section {
            row("Calendar", model.schedule.calendarAccess)
            row("Reminders", model.schedule.remindersAccess)
            LabeledContent("GitHub", value: github)
            LabeledContent("Your agents", value: "Claude Code and Codex sessions on this Mac")
            LabeledContent("Connected apps", value: "Your Codex MCP servers, read-only tools only")
        } header: {
            Text("What tilde can see")
        } footer: {
            Text("tilde uses these to brief you on your day and to notice what needs you. It never changes anything in them.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .id(refresh)
        .task {
            let status = try? await Shell.run(["gh", "auth", "status", "--active"])
            github = status?.ok == true ? "Signed in with the GitHub CLI" : "Run `gh auth login` to let tilde watch your PRs"
        }
    }

    private func row(_ name: String, _ access: Schedule.Access) -> some View {
        LabeledContent(name) {
            switch access {
            case .granted:
                Text("Allowed").foregroundStyle(.secondary)
            case .notAsked:
                Button("Allow") {
                    Task {
                        await model.schedule.requestAccess()
                        refresh += 1
                    }
                }
            case .denied:
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
            }
        }
    }
}
