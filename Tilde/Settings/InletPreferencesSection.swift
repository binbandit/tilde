import SwiftUI

struct InletPreferencesSection: View {
    @AppStorage(InletPreferences.stayWithinNotchKey) private var stayWithinNotch = false
    @AppStorage(InletPreferences.hideMarkKey) private var hideMark = false

    var body: some View {
        Section {
            Toggle("Stay within the notch when hidden", isOn: $stayWithinNotch)
            Toggle("Hide the ~ indicator when hidden", isOn: $hideMark)
        } header: {
            Text("When tilde is hidden")
        } footer: {
            Text("Staying within the notch removes both wings on a notched display. The camera housing covers the ~ and job dots, so neither is visible until you open tilde. On other edges and displays, this setting has no effect. Hiding only the ~ keeps job dots visible when tilde can extend beyond the notch.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
