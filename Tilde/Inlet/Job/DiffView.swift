import SwiftUI
import TildeKit

/// A unified diff, file by file: numbered on both sides, each file's name pinned while
/// you read it, and big or generated files folded until you open them. Click a line to
/// open the file there in your editor.
struct DiffView: View {
    var patch: String
    var open: (_ file: String, _ line: Int?) -> Void
    /// Files folded or unfolded by hand, against how they start.
    @State private var flipped: Set<String> = []

    var body: some View {
        let files = DiffMap.files(patch)
        if files.isEmpty {
            Text("No changes yet.").font(.system(size: 12)).foregroundStyle(Theme.text2)
        } else {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(files) { file in
                    let folded = file.startsFolded != flipped.contains(file.path)
                    Section {
                        if !folded {
                            FileLines(file: file, open: open)
                                .padding(.bottom, 18)
                                .transition(.opacity)
                        }
                    } header: {
                        FileHeader(file: file, folded: folded, open: open) {
                            withAnimation(Theme.quick) { flipped.formSymmetricDifference([file.path]) }
                        }
                    }
                }
            }
        }
    }
}

extension DiffMap.File {
    /// Big changes and files nobody reads line by line wait to be opened.
    var startsFolded: Bool {
        let name = (path as NSString).lastPathComponent
        let generated = [
            "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb", "Cargo.lock", "Package.resolved",
            "go.sum", "Gemfile.lock", "poetry.lock", "uv.lock", "composer.lock",
        ].contains(name) || name.hasSuffix(".min.js") || name.hasSuffix(".snap") || name.hasSuffix(".pbxproj")
        return generated || lines.count > 300
    }
}

/// A file's name, what happened to it, and how much, pinned above its lines.
private struct FileHeader: View {
    var file: DiffMap.File
    var folded: Bool
    var open: (_ file: String, _ line: Int?) -> Void
    var toggle: () -> Void
    @State private var hovered = false

    private var folder: String {
        let folder = (file.path as NSString).deletingLastPathComponent
        return folder.isEmpty ? "" : folder + "/"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(Theme.text3)
                .rotationEffect(.degrees(folded ? 0 : 90))
                .frame(width: 10)
            Text("\(Text(folder).foregroundStyle(Theme.text3))\(Text((file.path as NSString).lastPathComponent).foregroundStyle(Theme.text))")
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.head)
            if let note { Meta(text: note, color: noteColor) }
            Spacer(minLength: 12)
            if file.status != .binary {
                DiffBadge(diff: DiffStat(files: 1, insertions: file.insertions, deletions: file.deletions), compact: true)
            }
            if file.status != .deleted {
                Button { open(file.path, nil) } label: {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 20, height: 20)
                        .background(Theme.raised, in: .circle)
                }
                .buttonStyle(.plain)
                .help("Open in your editor")
                .opacity(hovered ? 1 : 0)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ink)
        .contentShape(.rect)
        .onTapGesture(perform: toggle)
        .onHover { hovered = $0 }
    }

    private var note: String? {
        switch file.status {
        case .added: "new"
        case .deleted: "deleted"
        case .renamed: file.oldPath.map { "from \($0)" } ?? "renamed"
        case .binary: "binary"
        case .modified: nil
        }
    }

    private var noteColor: Color {
        switch file.status {
        case .added: Theme.ready
        case .deleted: Theme.failed
        default: Theme.text3
        }
    }
}

/// A file's changed lines, numbered old then new, with the code that wraps under itself.
private struct FileLines: View {
    var file: DiffMap.File
    var open: (_ file: String, _ line: Int?) -> Void
    @State private var hovered: Int?

    /// Room for the file's longest line number.
    private var number: CGFloat {
        let widest = file.lines.map { max($0.oldLine ?? 0, $0.newLine ?? 0) }.max() ?? 0
        return CGFloat(String(widest).count) * 7 + 10
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(file.lines.enumerated()), id: \.offset) { index, line in
                if line.kind == .hunk {
                    // The first hunk of a file shown from its top needs no marker.
                    if !(index == 0 && line.newLine ?? 0 <= 1 && line.text.isEmpty) { hunk(line) }
                } else {
                    row(line, index: index)
                }
            }
        }
        .background(Color.white.opacity(0.025), in: .rect(cornerRadius: 8))
        .clipShape(.rect(cornerRadius: 8))
    }

    private func hunk(_ line: DiffMap.Line) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.text3)
                .frame(width: number * 2 + 4)
            Text(line.text.isEmpty ? "Line \(line.newLine ?? 0)" : line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.035))
    }

    private func row(_ line: DiffMap.Line, index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Group {
                Text(line.kind == .added ? "" : line.oldLine.map(String.init) ?? "")
                    .frame(width: number, alignment: .trailing)
                Text(line.kind == .removed ? "" : line.newLine.map(String.init) ?? "")
                    .frame(width: number, alignment: .trailing)
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(Theme.text3)
            Text(sign(line.kind))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint(line.kind) ?? Theme.text3)
                .frame(width: 24)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(line.kind == .context ? Theme.text2 : Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 10)
        }
        .padding(.vertical, 1.5)
        .background(hovered == index ? Color.white.opacity(0.07) : tint(line.kind)?.opacity(0.11) ?? .clear)
        .contentShape(.rect)
        .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
        .onTapGesture { open(file.path, line.newLine) }
    }

    private func sign(_ kind: DiffMap.Line.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "−"
        default: ""
        }
    }

    private func tint(_ kind: DiffMap.Line.Kind) -> Color? {
        switch kind {
        case .added: Theme.ready
        case .removed: Theme.failed
        default: nil
        }
    }
}
