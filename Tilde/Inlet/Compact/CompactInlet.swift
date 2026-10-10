import SwiftUI
import TildeKit

/// The resting `~` and a dot per open job, laid out for the edge: stacked on
/// the sides, either side of the camera on a notch, in a row on the lip.
struct CompactInlet: View {
    @Environment(AppModel.self) private var model
    var placement: InletPlacement

    var body: some View {
        switch (placement.edge, placement.notch) {
        case (.top, let notch?):
            HStack(spacing: 0) {
                TildeMark(mood: mood, size: 18).frame(width: Inlet.wing)
                Color.clear.frame(width: notch.width)
                dots.frame(width: Inlet.wing)
            }
        case (.top, nil):
            HStack(spacing: 12) {
                TildeMark(mood: mood, size: 18)
                if !model.openJobs.isEmpty { dots }
            }
            .padding(.horizontal, 15)
            .frame(maxHeight: .infinity)
        case (let edge, _):
            VStack(spacing: 14) {
                TildeMark(mood: mood, size: 20)
                dots
            }
            .frame(width: Inlet.pill.width, height: Inlet.pill.height)
            // Optically centred: the ears make the bezel side look heavier.
            .offset(x: edge == .left ? 2 : -2)
        }
    }

    /// A dot per open job, running along the edge: a column on the sides, a
    /// row on top. Whole-point dots on a whole-point pitch land on the same
    /// pixels, so they read as a set at 1x.
    private var dots: some View {
        let layout = placement.edge == .top ? AnyLayout(HStackLayout(spacing: 4)) : AnyLayout(VStackLayout(spacing: 4))
        return layout {
            ForEach(model.openJobs.prefix(4)) { job in
                Circle().fill(Theme.tint(job.phase)).frame(width: 4, height: 4)
            }
        }
    }

    private var mood: TildeMark.Mood {
        if !model.attention.isEmpty { return .needsYou }
        if model.openJobs.contains(where: { $0.phase.isActive }) { return .working }
        if model.openJobs.contains(where: { $0.phase == .ready }) { return .done }
        return .idle
    }
}
