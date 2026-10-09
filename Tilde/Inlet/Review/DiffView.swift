import SwiftUI
import TildeKit

/// A unified diff, coloured and grouped by file. Click a file or a line to
/// open it in your editor right there.
struct DiffView: View {
    var patch: String
    var open: (_ file: String, _ line: Int?) -> Void
    @State private var hovered: Int?

    var body: some View {
        if patch.isEmpty {
            Text("No changes yet.").font(.system(size: 12)).foregroundStyle(Theme.text2)
        } else {
            let lines = Array(DiffMap.lines(patch).enumerated())
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines, id: \.offset) { index, line in
                    row(line, index: index)
                }
            }
        }
    }

    @ViewBuilder private func row(_ line: DiffMap.Line, index: Int) -> some View {
        switch line.kind {
        case .file:
            Button {
                if let file = line.file { open(file, nil) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(Theme.text3)
                    Text(line.text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Image(systemName: "arrow.up.forward").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text3)
                        .opacity(hovered == index ? 1 : 0)
                }
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 ? index : nil }
            .padding(.top, index == 0 ? 0 : 16)
            .padding(.bottom, 7)
        case .hunk:
            Text(line.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text3).padding(.vertical, 3)
        default:
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(color(line.kind))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                .background(hovered == index ? Theme.raised : background(line.kind))
                .contentShape(.rect)
                .onHover { hovered = $0 ? index : nil }
                .onTapGesture { if let file = line.file { open(file, line.newLine) } }
        }
    }

    private func color(_ kind: DiffMap.Line.Kind) -> Color {
        switch kind {
        case .added: Theme.ready
        case .removed: Theme.failed
        default: Theme.text2
        }
    }

    private func background(_ kind: DiffMap.Line.Kind) -> Color {
        switch kind {
        case .added: Theme.ready.opacity(0.1)
        case .removed: Theme.failed.opacity(0.1)
        default: .clear
        }
    }
}
