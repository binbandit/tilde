import SwiftUI

/// Words from tilde or an agent, as written: Markdown paragraphs, headings, lists, quotes
/// and code blocks, with `code`, bold and links inline. A single line break stays a line
/// break, the way people write in chat.
struct Prose: View {
    var text: String
    var size: CGFloat = 13
    var weight: Font.Weight = .regular
    var color = Theme.text

    var body: some View {
        let blocks = Block.parse(text, size: size)
        VStack(alignment: .leading, spacing: size * 0.55) {
            ForEach(blocks) { block in
                view(for: block)
            }
        }
        .font(.system(size: size, weight: weight))
        .foregroundStyle(color)
        .tint(Theme.focus)
    }

    @ViewBuilder private func view(for block: Block) -> some View {
        switch block.kind {
        case .code:
            ScrollView(.horizontal) {
                Text(block.text)
                    .font(.system(size: size - 1.5, design: .monospaced))
                    .foregroundStyle(Theme.text2)
                    .fixedSize()
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
            }
            .scrollIndicators(.never)
            .background(Theme.raised, in: .rect(cornerRadius: 9))
            .padding(.leading, block.indent)
        case .rule:
            Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 2)
        case .table:
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(block.rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .fontWeight(index == 0 ? .semibold : nil)
                                .foregroundStyle(index == 0 ? Theme.text2 : color)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    if index == 0 { Rectangle().fill(Theme.line).frame(height: 1).gridCellUnsizedAxes(.horizontal) }
                }
            }
            .padding(.leading, block.indent)
        case .heading, .paragraph:
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if block.quoted {
                    Capsule().fill(Theme.text3).frame(width: 2).padding(.vertical, -1)
                }
                if let marker = block.marker {
                    // Later paragraphs of a list item keep the item's indent, with no marker of their own.
                    Text(marker.text)
                        .monospacedDigit()
                        .foregroundStyle(Theme.text3)
                        .frame(minWidth: 10, alignment: .leading)
                        .opacity(marker.shown ? 1 : 0)
                }
                Text(block.text)
                    .font(block.kind == .heading ? .system(size: size + 1, weight: .semibold) : nil)
                    .foregroundStyle(block.quoted ? Theme.text2 : color)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.leading, block.indent)
        }
    }
}

extension Prose {
    /// One block of the text, flattened out of Markdown's nesting.
    struct Block: Identifiable {
        enum Kind { case paragraph, heading, code, rule, table }
        struct Marker {
            var text: String
            var shown: Bool
        }

        var id: Int
        var kind: Kind
        var text: AttributedString
        /// A table's cells, row by row, its header first.
        var rows: [[AttributedString]] = []
        private var filling: (row: Int, cell: Int)?
        var marker: Marker?
        /// How deep in nested lists it sits, as a leading inset.
        var indent: CGFloat
        var quoted: Bool

        static func parse(_ source: String, size: CGFloat) -> [Block] {
            let options = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
            guard var text = try? AttributedString(markdown: source, options: options) else {
                return [Block(id: 0, kind: .paragraph, text: AttributedString(source), indent: 0, quoted: false)]
            }
            style(&text, size: size)

            var blocks: [Block] = []
            var marked: Set<Int> = []
            for (intent, range) in text.runs[\.presentationIntent] {
                let components = intent?.components ?? []
                // A table is one block, filled cell by cell: a cell, in a row, in the table.
                if components.count >= 3, case .table = components[2].kind {
                    if blocks.last?.id != components[2].identity {
                        blocks.append(Block(id: components[2].identity, kind: .table, text: "", indent: 0, quoted: false))
                    }
                    blocks[blocks.count - 1].fill(row: components[1].identity, cell: components[0].identity, with: text[range])
                    continue
                }
                // Components run innermost first: a paragraph, in a list item, in a list.
                let id = components.first?.identity ?? -1
                if let last = blocks.last, last.id == id {
                    blocks[blocks.count - 1].text += text[range]
                    continue
                }
                var block = Block(id: id, kind: .paragraph, text: AttributedString(text[range]), indent: 0, quoted: false)
                var lists = 0
                for component in components {
                    switch component.kind {
                    case .header: block.kind = .heading
                    case .codeBlock: block.kind = .code
                    case .thematicBreak: block.kind = .rule
                    case .blockQuote: block.quoted = true
                    case .orderedList, .unorderedList: lists += 1
                    default: break
                    }
                }
                // The innermost list item, and whether it's numbered.
                if let item = components.firstIndex(where: { if case .listItem = $0.kind { true } else { false } }),
                    case .listItem(let ordinal) = components[item].kind
                {
                    let ordered = components.dropFirst(item + 1).first.map { $0.kind == .orderedList } ?? false
                    let shown = marked.insert(components[item].identity).inserted
                    block.marker = Marker(text: ordered ? "\(ordinal)." : lists > 1 ? "◦" : "•", shown: shown)
                }
                block.indent = CGFloat(max(0, lists - 1)) * 17
                if block.kind == .code {
                    // A code block keeps its own lines; the last newline is just its end.
                    while block.text.characters.last == "\n" { block.text.characters.removeLast() }
                }
                blocks.append(block)
            }
            return blocks
        }

        private mutating func fill(row: Int, cell: Int, with piece: AttributedSubstring) {
            if filling?.row != row { rows.append([]) }
            if filling?.row != row || filling?.cell != cell { rows[rows.count - 1].append("") }
            rows[rows.count - 1][rows[rows.count - 1].count - 1] += piece
            filling = (row, cell)
        }

        /// Inline code in mono, and soft line breaks kept as the writer typed them.
        private static func style(_ text: inout AttributedString, size: CGFloat) {
            for (inline, range) in text.runs[\.inlinePresentationIntent].reversed() {
                guard let inline else { continue }
                if inline.contains(.softBreak) {
                    text.characters.replaceSubrange(range, with: "\n")
                } else if inline.contains(.code) {
                    text[range].font = .system(size: size - 1, weight: .medium, design: .monospaced)
                    text[range].foregroundColor = Color(white: 0.86)
                }
            }
        }
    }
}
