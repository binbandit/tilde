import Foundation

/// Preferences for the resting Inlet. Open conversations always keep their mark.
nonisolated struct InletPreferences: Equatable {
    static let stayWithinNotchKey = "inletStayWithinNotch"
    static let hideMarkKey = "inletHideRestingMark"
    static let minimizeAfterSendingKey = "inletMinimizeAfterSending"

    var stayWithinNotch = false
    var hideMark = false
    var minimizeAfterSending = true

    init(stayWithinNotch: Bool = false, hideMark: Bool = false, minimizeAfterSending: Bool = true) {
        self.stayWithinNotch = stayWithinNotch
        self.hideMark = hideMark
        self.minimizeAfterSending = minimizeAfterSending
    }

    init(defaults: UserDefaults) {
        stayWithinNotch = defaults.bool(forKey: Self.stayWithinNotchKey)
        hideMark = defaults.bool(forKey: Self.hideMarkKey)
        minimizeAfterSending = defaults.object(forKey: Self.minimizeAfterSendingKey) as? Bool ?? true
    }

    func confinesRestingInlet(edge: InletEdge, notch: CGSize?) -> Bool {
        stayWithinNotch && edge == .top && notch != nil
    }
}
