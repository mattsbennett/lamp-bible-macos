import AppKit
// Xcode compiles the support sources straight into the app target, where there
// is no module of that name to import; the package builds it as one.
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI

/// What an agent actually said, rendered rather than printed.
///
/// A provider replies in Markdown — fenced code, lists, tables, emphasis — and
/// a chat bubble that holds a plain `String` shows the characters instead of
/// the writing. This shares the parser the devotional reader uses, so a heading
/// here and a heading there are the same heading; only the presentation differs,
/// because prose on a page and a reply in a bubble want different typography.
struct AgentMarkdownMessageView: View {
    let markdown: String
    /// Agent text sits on the window background, the person's on the accent, so
    /// the colour has to come from whoever placed the bubble.
    var foreground: Color = .primary

    private var blocks: [DevotionalProseBlock] {
        DevotionalProseParser.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: DevotionalProseBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(.system(size: headingSize(level), weight: .semibold))
        case .paragraph(let text):
            inline(text)
        case .quote(let paragraphs):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    inline(paragraph)
                }
            }
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(foreground.opacity(0.3))
                    .frame(width: 3)
            }
        case .bulletList(let items):
            list(items.map { (nil, $0) })
        case .numberedList(let items):
            list(items.enumerated().map { ("\($0.offset + 1).", $0.element) })
        case .nestedBulletList(let lines):
            list(lines.map { (nil, $0.text) }, depths: lines.map(\.depth))
        case .nestedNumberedList(let lines):
            list(lines.map { (nil, $0.text) }, depths: lines.map(\.depth))
        case .table(let headers, let rows):
            table(headers: headers, rows: rows)
        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)
        case .rule:
            Divider()
        }
    }

    private func list(
        _ items: [(String?, String)],
        depths: [Int]? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.0 ?? "•")
                        .monospacedDigit()
                        .foregroundStyle(foreground.opacity(0.7))
                    inline(item.1)
                }
                .padding(.leading, CGFloat(depths?[index] ?? 0) * 14)
            }
        }
    }

    private func table(headers: [String], rows: [[String]]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            tableRow(headers, isHeader: true)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider()
                tableRow(row, isHeader: false)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(foreground.opacity(0.06))
        )
    }

    private func tableRow(_ cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                inline(cell)
                    .font(isHeader ? .body.weight(.semibold) : .body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Emphasis, links and inline code, resolved by Foundation rather than by
    /// hand. A line that will not parse is shown as it was written.
    private func inline(_ source: String) -> some View {
        let attributed = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
        return Text(attributed)
            .textSelection(.enabled)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 20
        case 2: 18
        default: 16
        }
    }
}
