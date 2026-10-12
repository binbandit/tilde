import Foundation

/// Preferences for the resting Inlet. Open conversations always keep their mark.
nonisolated struct InletPreferences: Equatable {
    static let stayWithinNotchKey = "inletStayWithinNotch"
    static let hideMarkKey = "inletHideRestingMark"

    var stayWithinNotch = false
    var hideMark = false

    init(stayWithinNotch: Bool = false, hideMark: Bool = false) {
        self.stayWithinNotch = stayWithinNotch
        self.hideMark = hideMark
    }

    init(defaults: UserDefaults) {
        stayWithinNotch = defaults.bool(forKey: Self.stayWithinNotchKey)
        hideMark = defaults.bool(forKey: Self.hideMarkKey)
    }

    func confinesRestingInlet(edge: InletEdge, notch: CGSize?) -> Bool {
        stayWithinNotch && edge == .top && notch != nil
    }
}
