import SwiftUI
import TildeKit

/// The resting `~` and a dot per open job, laid out for the edge: stacked on
/// the sides, either side of the camera on a notch, in a row on the lip.
struct CompactInlet: View {
    @Environment(AppModel.self) private var model
    var placement: InletPlacement
    var preferences: InletPreferences

    var body: some View {
        if preferences.confinesRestingInlet(edge: placement.edge, notch: placement.notch), let notch = placement.notch {
            // The physical camera covers this space. No wings or hidden controls extend beyond it.
            Color.clear.frame(width: notch.width, height: notch.height)
        } else {
            switch (placement.edge, placement.notch) {
            case (.top, let notch?):
                HStack(spacing: 0) {
                    Group {
                        if showsMark { TildeMark(mood: mood, size: 18) }
                        else { Color.clear }
                    }
                    .frame(width: Inlet.wing)
                    Color.clear.frame(width: notch.width)
                    dots.frame(width: Inlet.wing)
                }
                .frame(height: notch.height)
            case (.top, nil):
                HStack(spacing: 12) {
                    if showsMark { TildeMark(mood: mood, size: 18) }
                    if !model.crew.isEmpty { dots }
                }
                .padding(.horizontal, 15)
                .frame(height: placement.menuBar)
            case (let edge, _):
                VStack(spacing: 14) {
                    if showsMark { TildeMark(mood: mood, size: 20) }
                    dots
                }
                .frame(width: Inlet.pill.width, height: Inlet.pill.height)
                // Optically centred: the ears make the bezel side look heavier.
                .offset(x: edge == .left ? 2 : -2)
            }
        }
    }

    /// A dot per job, running along the edge: a column on the sides, a row on top. With more than
    /// fit, the ones that need you or failed come first, and a fifth dot, hollow, says there are more.
    /// Whole-point dots on a whole-point pitch land on the same pixels, so they read as a set at 1x.
    private var dots: some View {
        let layout = placement.edge == .top ? AnyLayout(HStackLayout(spacing: 4)) : AnyLayout(VStackLayout(spacing: 4))
        let urgent: (Job) -> Int = { [.needsYou: 0, .failed: 1, .ready: 2][$0.phase] ?? 3 }
        let crew = model.crew.sorted { urgent($0) < urgent($1) }
        return layout {
            ForEach(crew.prefix(4)) { job in
                Circle().fill(Theme.tint(job.phase)).frame(width: 4, height: 4)
            }
            if crew.count > 4 { Circle().strokeBorder(Theme.text3, lineWidth: 1).frame(width: 4, height: 4) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(crew.map { "\($0.title), \(JobStatus.words($0))" }.joined(separator: "; "))
    }

    /// Hiding the ~ never hides that something needs you.
    private var showsMark: Bool { !preferences.hideMark || !model.attention.isEmpty }

    private var mood: TildeMark.Mood {
        if !model.attention.isEmpty { return .needsYou }
        if model.crew.contains(where: { $0.phase == .failed }) { return .failed }
        if model.crew.contains(where: { $0.phase.isActive }) { return .working }
        if model.crew.contains(where: { $0.phase == .ready }) { return .done }
        return .idle
    }
}
