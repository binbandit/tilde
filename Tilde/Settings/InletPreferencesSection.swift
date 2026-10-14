import SwiftUI

struct InletPreferencesSection: View {
    @AppStorage(InletPreferences.stayWithinNotchKey) private var stayWithinNotch = false
    @AppStorage(InletPreferences.hideMarkKey) private var hideMark = false
    @AppStorage(InletPreferences.minimizeAfterSendingKey) private var minimizeAfterSending = true

    var body: some View {
        Section {
            Toggle("Minimize after sending", isOn: $minimizeAfterSending)
        } footer: {
            Text("Finished replies and new questions still peek out. Turn this off to watch replies as they're written.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        Section {
            Toggle("Stay within the notch", isOn: $stayWithinNotch)
            Toggle("Hide the ~", isOn: $hideMark)
        } header: {
            Text("At rest")
        } footer: {
            Text("Within the notch, the camera covers the ~ and job dots until you open tilde. A hidden ~ still shows when something needs you.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
