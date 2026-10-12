import Foundation
import SwiftUI

// Layout tests don't need the conductor's messages or the real history preference.
// Every geometry, placement, preference and shape type below is production code.
@MainActor final class ConversationVisibility {}

@main
struct InletGeometryTests {
    @MainActor static func main() {
        var checks = 0
        func check(_ passed: Bool, _ message: String) {
            precondition(passed, message)
            checks += 1
        }
        func contained(_ inner: CGRect, by outer: CGRect) -> Bool {
            inner.minX >= outer.minX - 0.001 && inner.maxX <= outer.maxX + 0.001
                && inner.minY >= outer.minY - 0.001 && inner.maxY <= outer.maxY + 0.001
        }

        // Screen-relative placement must work on either side of the primary screen,
        // at small logical resolutions, with a Dock at any edge or with it hidden.
        let screens: [(CGRect, CGRect)] = [
            (CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 0, y: 70, width: 1512, height: 880)),
            (CGRect(x: -1920, y: -300, width: 1920, height: 1080), CGRect(x: -1840, y: -300, width: 1840, height: 1056)),
            (CGRect(x: 1512, y: 80, width: 640, height: 480), CGRect(x: 1512, y: 80, width: 568, height: 456)),
            (CGRect(x: 0, y: 0, width: 320, height: 240), CGRect(x: 0, y: 0, width: 320, height: 240)),
            (CGRect(x: 0.5, y: 0.5, width: 799, height: 601), CGRect(x: 0.5, y: 2.5, width: 797, height: 575)),
        ]
        for (full, visible) in screens {
            for edge in InletEdge.allCases {
                let panel = InletGeometry.panelFrame(edge: edge, full: full, visible: visible)
                check(contained(panel, by: full), "\(edge) panel escaped \(full)")
                check(panel.width <= 900, "Panel exceeded its maximum span")
                check(panel.minY >= visible.minY, "Panel overlaps the bottom Dock")
                if edge == .top {
                    check(abs(panel.midX - full.midX) <= 0.5, "Top panel lost camera alignment")
                    check(panel.maxY <= full.maxY, "Top panel exceeds the display")
                } else {
                    check(panel.maxY <= visible.maxY, "Side panel overlaps the menu bar")
                }
                if visible.minX - full.minX > 8 { check(panel.minX >= visible.minX, "Panel overlaps the left Dock") }
                if full.maxX - visible.maxX > 8 { check(panel.maxX <= visible.maxX, "Panel overlaps the right Dock") }
            }
        }

        let shiftedNotch = InletGeometry.panelFrame(
            edge: .top, full: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visible: CGRect(x: 0, y: 0, width: 1000, height: 768), notchCenterX: 350)
        check(shiftedNotch.midX == 350, "Explicit camera position must centre the top strip")

        // The maximum includes header, crew, composer, every gap and outer padding.
        // No minimum height is allowed to force a small display to clip its content.
        for edge in InletEdge.allCases {
            for panelSize in [CGSize(width: 900, height: 1200), CGSize(width: 640, height: 456), CGSize(width: 300, height: 180), CGSize(width: 40, height: 40), .zero] {
                for notch in [nil, CGSize(width: 190, height: 32)] as [CGSize?] {
                    let geometry = InletGeometry(edge: edge, panelSize: panelSize, notch: edge == .top ? notch : nil)
                    let limit = geometry.bodyLimit(ear: InletGeometry.expandedEar)
                    let chat = geometry.conversationSize
                    check(chat.height <= 600 && chat.height <= limit.height * 0.70, "Conversation exceeds its total height budget")
                    check(chat.width <= min(400, limit.width), "Conversation exceeds the available width")
                    for size in [chat, geometry.peekSize] {
                        let padding = geometry.padding(in: size)
                        check(padding.horizontal <= size.width, "Horizontal padding cannot exceed its surface")
                        check(padding.vertical <= size.height, "Vertical padding cannot exceed its surface")
                        check(abs(geometry.contentHeight(in: size) + padding.vertical - size.height) < 0.001, "Outer padding was not included in the budget")
                    }
                    check(geometry.jobSize.width <= min(820, limit.width), "Job exceeds available width")
                    check(geometry.jobSize.height <= min(860, limit.height * 0.84), "Job exceeds total height budget")
                    check(geometry.jobContentHeight + geometry.jobTopPadding <= geometry.jobSize.height, "Job ignores camera clearance")
                    let bounded = geometry.bounded(CGSize(width: 10000, height: 10000), ear: 12, maximum: chat)
                    check(bounded == chat, "Huge content must stop at the conversation budget")
                }
            }
        }

        let suite = "dev.tilde.geometry-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        check(InletPreferences(defaults: defaults) == InletPreferences(), "New defaults must preserve existing appearance")
        defaults.set(true, forKey: InletPreferences.stayWithinNotchKey)
        defaults.set(true, forKey: InletPreferences.hideMarkKey)
        let preferences = InletPreferences(defaults: defaults)
        check(preferences.stayWithinNotch && preferences.hideMark, "Both preferences must persist independently")
        check(preferences.confinesRestingInlet(edge: .top, notch: CGSize(width: 190, height: 32)), "Notched top must be confined")
        check(!preferences.confinesRestingInlet(edge: .top, notch: nil), "No-notch display must ignore confinement")
        check(!preferences.confinesRestingInlet(edge: .right, notch: CGSize(width: 190, height: 32)), "Side must ignore confinement")

        // Exercise the actual drawn and hit-tested shape, not a duplicate formula.
        let inlet = Inlet()
        inlet.placement.edge = .top
        inlet.placement.notch = CGSize(width: 190, height: 32)
        inlet.placement.frame = CGRect(x: 0, y: 0, width: 900, height: 900)
        inlet.preferences = preferences
        for look in [Inlet.Look.dormant, .compact] {
            let shape = inlet.shape(for: look)
            check(shape.length == 190 && shape.depth == 32 && shape.ear == 0, "Confined rest must have no wings or ears")
            let housing = CGRect(x: 355, y: 0, width: 190, height: 32)
            check(contained(shape.path(in: inlet.placement.frame).boundingRect, by: housing), "Confined path escapes the camera housing")
        }
        inlet.preferences = InletPreferences(hideMark: true)
        let dotsOnly = inlet.shape(for: .compact)
        check(dotsOnly.length == 190 + 2 * Inlet.wing, "Hiding the mark must retain room for job dots")
        check(dotsOnly.ear > 0, "Only confinement removes notch ears")

        for edge in InletEdge.allCases {
            inlet.placement.edge = edge
            inlet.placement.notch = edge == .top ? CGSize(width: 190, height: 32) : nil
            for size in [CGSize(width: 900, height: 900), CGSize(width: 300, height: 180), CGSize(width: 80, height: 80)] {
                inlet.placement.frame = CGRect(origin: .zero, size: size)
                for look in [Inlet.Look.dormant, .compact, .peek, .conversation, .job] {
                    inlet.measured[look] = CGSize(width: 10000, height: 10000)
                    let shape = inlet.shape(for: look)
                    check(contained(shape.path(in: inlet.placement.frame).boundingRect, by: inlet.placement.frame), "\(edge) \(look) path exceeds its panel")
                    check(contained(shape.body(in: inlet.placement.frame), by: inlet.placement.frame), "\(edge) \(look) hit area exceeds its panel")
                }
            }
        }
        print("PASS: \(checks) Inlet geometry and preference checks")
    }
}
