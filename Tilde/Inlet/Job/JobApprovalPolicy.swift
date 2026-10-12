import SwiftUI
import TildeKit

/// Explicit owner opt-in for the small set of commands the conductor can prove safe.
struct JobApprovalPolicy: View {
    @Environment(AppModel.self) private var model
    var job: Job

    var body: some View {
        if job.phase.isActive, let conductor = model.conductor {
            Toggle(isOn: Binding {
                conductor.automaticApprovalEnabled(for: job.id)
            } set: {
                conductor.setAutomaticApproval($0, for: job.id)
            }) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Automatically allow folder listings this turn")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2)
                    Text("Claude permission requests for /bin/ls of this job's folder only. Expires on new feedback, completion, or stop. Other requests still need approval.")
                        .font(.system(size: 11)).foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }
}
