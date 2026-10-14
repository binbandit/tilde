import CoreGraphics
import Foundation
import Testing

@Suite struct InletShapeTests {
    /// Displays left of and above the primary one, small logical resolutions, and a Dock
    /// at the bottom, at either side, or hidden.
    static let displays: [(full: CGRect, visible: CGRect)] = [
        (CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 0, y: 70, width: 1512, height: 880)),
        (CGRect(x: -1920, y: -300, width: 1920, height: 1080), CGRect(x: -1840, y: -300, width: 1840, height: 1056)),
        (CGRect(x: 1512, y: 80, width: 640, height: 480), CGRect(x: 1512, y: 80, width: 568, height: 456)),
        (CGRect(x: 0, y: 0, width: 320, height: 240), CGRect(x: 0, y: 0, width: 320, height: 240)),
        (CGRect(x: 0.5, y: 0.5, width: 799, height: 601), CGRect(x: 0.5, y: 2.5, width: 797, height: 575)),
    ]
    static let notch = CGSize(width: 190, height: 32)
    static let looks: [Inlet.Look] = [.dormant, .compact, .peek, .conversation, .job]

    @Test(arguments: InletEdge.allCases)
    func panelStaysOnTheDisplayAndClearOfTheDock(edge: InletEdge) {
        for (full, visible) in Self.displays {
            let panel = InletGeometry.panelFrame(edge: edge, full: full, visible: visible)
            #expect(contains(full, panel))
            #expect(panel.minY >= visible.minY, "bottom Dock")
            if visible.minX - full.minX > 8 { #expect(panel.minX >= visible.minX, "left Dock") }
            if full.maxX - visible.maxX > 8 { #expect(panel.maxX <= visible.maxX, "right Dock") }
            if edge == .top {
                #expect(abs(panel.midX - full.midX) <= 0.5, "centred on the camera")
            } else {
                #expect(panel.maxY <= visible.maxY, "menu bar")
            }
        }
    }

    @Test func topPanelCentresOnTheCamera() {
        let panel = InletGeometry.panelFrame(
            edge: .top, full: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visible: CGRect(x: 0, y: 0, width: 1000, height: 768), notchCenterX: 350)
        #expect(panel.midX == 350)
    }

    /// The drawn outline and the hit area are the same shape, so both must stay in the panel
    /// however large the content measures, on any edge and any panel size.
    @Test(arguments: InletEdge.allCases)
    func everyLookStaysInsideItsPanel(edge: InletEdge) {
        let inlet = Inlet()
        inlet.placement.edge = edge
        inlet.placement.notch = edge == .top ? Self.notch : nil
        for size in [CGSize(width: 900, height: 900), CGSize(width: 300, height: 180), CGSize(width: 80, height: 80)] {
            inlet.placement.frame = CGRect(origin: .zero, size: size)
            for look in Self.looks {
                inlet.measured[look] = CGSize(width: 10_000, height: 10_000)
                let shape = inlet.shape(for: look)
                #expect(contains(inlet.placement.frame, shape.path(in: inlet.placement.frame).boundingRect), "\(look) outline")
                #expect(contains(inlet.placement.frame, shape.body(in: inlet.placement.frame)), "\(look) hit area")
            }
        }
    }

    @Test(arguments: InletEdge.allCases)
    func expandedLooksStopAtTheirBudgets(edge: InletEdge) {
        let inlet = Inlet()
        inlet.placement.edge = edge
        inlet.placement.notch = edge == .top ? Self.notch : nil
        for size in [CGSize(width: 900, height: 1200), CGSize(width: 640, height: 456), CGSize(width: 300, height: 180)] {
            inlet.placement.frame = CGRect(origin: .zero, size: size)
            let geometry = inlet.placement.geometry
            let budgets: [(Inlet.Look, CGSize)] = [
                (.conversation, geometry.conversationSize), (.peek, geometry.peekSize), (.job, geometry.jobSize),
            ]
            for (look, budget) in budgets {
                #expect(budget.width <= size.width && budget.height <= size.height, "\(look) budget exceeds the panel")
                inlet.measured[look] = CGSize(width: 10_000, height: 10_000)
                let shape = inlet.shape(for: look)
                let (width, height) = edge == .top ? (shape.length, shape.depth) : (shape.depth, shape.length)
                #expect(width <= budget.width && height <= budget.height, "\(look) outgrew its budget")
            }
        }
    }

    @Test func confinedRestStaysInTheCameraHousing() {
        let inlet = Inlet()
        inlet.placement.edge = .top
        inlet.placement.notch = Self.notch
        inlet.placement.frame = CGRect(x: 0, y: 0, width: 900, height: 900)
        inlet.preferences = InletPreferences(stayWithinNotch: true)
        let housing = CGRect(x: 355, y: 0, width: 190, height: 32)
        for look in [Inlet.Look.dormant, .compact] {
            let shape = inlet.shape(for: look)
            #expect(shape.ear == 0)
            #expect(contains(housing, shape.path(in: inlet.placement.frame).boundingRect))
        }
    }

    @Test func hidingTheMarkKeepsRoomForJobDots() {
        let inlet = Inlet()
        inlet.placement.edge = .top
        inlet.placement.notch = Self.notch
        inlet.placement.frame = CGRect(x: 0, y: 0, width: 900, height: 900)
        inlet.preferences = InletPreferences(hideMark: true)
        let shape = inlet.shape(for: .compact)
        #expect(shape.length == Self.notch.width + 2 * Inlet.wing)
        #expect(shape.ear > 0)
    }

    @Test func confinementOnlyAppliesToANotchedTop() {
        let preferences = InletPreferences(stayWithinNotch: true)
        #expect(preferences.confinesRestingInlet(edge: .top, notch: Self.notch))
        #expect(!preferences.confinesRestingInlet(edge: .top, notch: nil))
        #expect(!preferences.confinesRestingInlet(edge: .right, notch: Self.notch))
    }

    @Test func preferencesPersist() throws {
        let suite = "dev.tilde.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(InletPreferences(defaults: defaults) == InletPreferences())
        #expect(InletPreferences(defaults: defaults).minimizeAfterSending)

        defaults.set(false, forKey: InletPreferences.minimizeAfterSendingKey)
        defaults.set(true, forKey: InletPreferences.stayWithinNotchKey)
        defaults.set(true, forKey: InletPreferences.hideMarkKey)
        #expect(InletPreferences(defaults: defaults) == InletPreferences(stayWithinNotch: true, hideMark: true, minimizeAfterSending: false))
    }

    private func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        outer.insetBy(dx: -0.001, dy: -0.001).contains(inner)
    }
}
