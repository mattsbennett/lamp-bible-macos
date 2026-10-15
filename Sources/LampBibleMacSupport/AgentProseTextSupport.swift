import AppKit
import Foundation

/// An agent's reply as one piece of styled text, so a selection can run across
/// its paragraphs, lists, quotes and tables — separate text views can only be
/// selected one at a time.
///
/// Code blocks are the exception: they keep their own panel, with its copy
/// button and horizontal scrolling, since wrapping code at a bubble's width
/// makes it unreadable. A reply is therefore a sequence of prose runs and code
/// blocks.
public enum AgentProseText {
    public enum Segment: Equatable, Sendable {
        case prose([DevotionalProseBlock])
        case code(language: String?, code: String)
    }

    public static func segments(of markdown: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [DevotionalProseBlock] = []
        for block in DevotionalProseParser.parse(markdown) {
            if case .codeBlock(let language, let code) = block {
                if !prose.isEmpty { segments.append(.prose(prose)) }
                prose = []
                segments.append(.code(language: language, code: code))
            } else {
                prose.append(block)
            }
        }
        if !prose.isEmpty { segments.append(.prose(prose)) }
        return segments
    }

    public struct Style {
        public var fontSize: CGFloat = NSFont.systemFontSize
        public var foreground: NSColor = .labelColor
        /// Between blocks, as the reply's paragraphs were spaced before.
        public var blockSpacing: CGFloat = 10

        public init() {}
    }

    /// Prose blocks as one attributed string. Quotes and tables are TextKit 1
    /// text blocks, so it must be shown by a view using TextKit 1.
    public static func attributedString(
        for blocks: [DevotionalProseBlock],
        style: Style = Style()
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var previous: DevotionalProseBlock?
        for block in blocks {
            let piece = NSMutableAttributedString()
            append(block, to: piece, style: style)
            guard piece.length > 0 else { continue }
            // The gap between blocks belongs to the block above, unless that
            // block is drawn in a box — a quote's bar, a table's cells — which
            // the gap would stretch; then it goes above the block below. When
            // both are boxes it is a line of its own: a margin would do, but
            // AppKit narrows a table by its margin.
            if let previous {
                if !isBoxed(previous) {
                    let last = paragraphRange(containing: result.length - 1, in: result)
                    setSpacing(after: style.blockSpacing, in: last, of: result)
                } else if isBoxed(block) {
                    appendSpacer(height: style.blockSpacing, to: result)
                } else {
                    setSpacing(before: style.blockSpacing, in: paragraphRange(containing: 0, in: piece), of: piece)
                }
            }
            result.append(piece)
            previous = block
        }
        // Each paragraph ends in a newline; the reply's last one needs none.
        if result.string.hasSuffix("\n") {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        return result
    }

    /// Marks a line that only spaces two blocks apart, which copying leaves out.
    public static let spacerAttribute = NSAttributedString.Key("LampProseSpacer")
    /// Marks a list item's marker; its value is the item's depth.
    public static let listMarkerAttribute = NSAttributedString.Key("LampProseListMarker")

    /// A selection as plain text: a table's rows as lines of tab-separated
    /// cells, ready to paste into a spreadsheet, and list markers followed by a
    /// space rather than the tab that aligns them.
    public static func plainText(of text: NSAttributedString, in range: NSRange) -> String {
        let string = text.string as NSString
        var result = ""
        string.enumerateSubstrings(
            in: string.paragraphRange(for: range),
            options: [.byParagraphs, .substringNotRequired]
        ) { _, content, enclosing, _ in
            guard text.attribute(spacerAttribute, at: enclosing.location, effectiveRange: nil) == nil else { return }
            let selected = NSIntersectionRange(content, range)
            if selected.length > 0 {
                text.enumerateAttribute(listMarkerAttribute, in: selected) { depth, run, _ in
                    let piece = string.substring(with: run)
                    if let depth = depth as? Int {
                        result += String(repeating: "  ", count: depth) + piece.replacingOccurrences(of: "\t", with: " ")
                    } else {
                        result += piece
                    }
                }
            }
            // The paragraph's end, when the selection runs over it.
            let end = NSMaxRange(content)
            if NSMaxRange(enclosing) > end, range.location <= end, end < NSMaxRange(range) {
                result += continuesRow(text, at: end) ? "\t" : "\n"
            }
        }
        return result
    }

    /// Emphasis, inline code, strikethrough and links, read by Foundation's
    /// Markdown parser. A line that won't parse is kept as written.
    public static func inline(_ markdown: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let parsed = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            var runFont = font
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    runFont = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                    attributes[.backgroundColor] = translucent(color, 0.08)
                }
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = runFont.fontDescriptor.withSymbolicTraits(
                        runFont.fontDescriptor.symbolicTraits.union(traits)
                    )
                    runFont = NSFont(descriptor: descriptor, size: runFont.pointSize) ?? runFont
                }
                if intent.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            if let link = run.link { attributes[.link] = link }
            attributes[.font] = runFont
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }

    /// The colour at an opacity, still following light and dark mode:
    /// `withAlphaComponent` fixes a system colour to the appearance current
    /// when it's called.
    public static func translucent(_ color: NSColor, _ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolved = color
            appearance.performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.deviceRGB) ?? color
            }
            return resolved.withAlphaComponent(alpha)
        }
    }

    // MARK: - Blocks

    private static func append(
        _ block: DevotionalProseBlock,
        to result: NSMutableAttributedString,
        style: Style
    ) {
        let body = NSFont.systemFont(ofSize: style.fontSize)
        switch block {
        case .heading(let level, let text):
            let size: CGFloat = switch level {
            case 1: 20
            case 2: 18
            default: 16
            }
            appendParagraph(
                inline(text, font: .systemFont(ofSize: size, weight: .semibold), color: style.foreground),
                to: result
            )
        case .paragraph(let text):
            appendParagraph(inline(text, font: body, color: style.foreground), to: result)
        case .quote(let paragraphs):
            // One block for every paragraph, so the bar beside them is unbroken.
            let bar = NSTextBlock()
            // Without a width the block isn't laid out as one, and its bar is lost.
            bar.setValue(100, type: .percentageValueType, for: .width)
            bar.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            bar.setBorderColor(translucent(style.foreground, 0.3), for: .minX)
            bar.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
            for (index, paragraph) in paragraphs.enumerated() {
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.textBlocks = [bar]
                // Between its paragraphs only: below the last, the gap to the
                // next block is set like any other.
                paragraphStyle.paragraphSpacing = index < paragraphs.count - 1 ? 6 : 0
                appendParagraph(
                    inline(paragraph, font: body, color: style.foreground),
                    to: result,
                    paragraphStyle: paragraphStyle
                )
            }
        case .bulletList(let items):
            appendList(items.map { ("•", 0, $0) }, to: result, style: style)
        case .numberedList(let items):
            appendList(items.enumerated().map { ("\($0.offset + 1).", 0, $0.element) }, to: result, style: style)
        case .nestedBulletList(let lines), .nestedNumberedList(let lines):
            appendList(lines.map { ("•", $0.depth, $0.text) }, to: result, style: style)
        case .table(let headers, let rows):
            appendTable(headers: headers, rows: rows, to: result, style: style)
        case .rule:
            let line = NSTextBlock()
            line.setValue(100, type: .percentageValueType, for: .width)
            line.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            line.setBorderColor(translucent(style.foreground, 0.2), for: .maxY)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.textBlocks = [line]
            appendParagraph(
                NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 2)]),
                to: result,
                paragraphStyle: paragraphStyle
            )
        case .codeBlock(_, let code):
            // Code is shown in its own panel; reaching here means a caller
            // passed it in anyway, so it is kept rather than lost.
            appendParagraph(
                NSAttributedString(string: code, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: style.fontSize - 1, weight: .regular),
                    .foregroundColor: style.foreground,
                ]),
                to: result
            )
        }
    }

    private static func appendList(
        _ items: [(marker: String, depth: Int, text: String)],
        to result: NSMutableAttributedString,
        style: Style
    ) {
        let body = NSFont.systemFont(ofSize: style.fontSize)
        for item in items {
            let indent = CGFloat(item.depth) * 14
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.firstLineHeadIndent = indent
            // Wrapped lines align with the text, not the marker.
            paragraphStyle.headIndent = indent + 20
            paragraphStyle.tabStops = [NSTextTab(textAlignment: .left, location: indent + 20)]
            paragraphStyle.paragraphSpacing = 4
            let line = NSMutableAttributedString(string: item.marker + "\t", attributes: [
                .font: body.monospacedDigitFont,
                .foregroundColor: translucent(style.foreground, 0.7),
                listMarkerAttribute: item.depth,
            ])
            line.append(inline(item.text, font: body, color: style.foreground))
            appendParagraph(line, to: result, paragraphStyle: paragraphStyle)
        }
    }

    private static func appendTable(
        headers: [String],
        rows: [[String]],
        to result: NSMutableAttributedString,
        style: Style
    ) {
        let columns = max(headers.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.collapsesBorders = true
        table.setContentWidth(100, type: .percentageValueType)
        let body = NSFont.systemFont(ofSize: style.fontSize)
        let header = NSFont.systemFont(ofSize: style.fontSize, weight: .semibold)
        let allRows = [headers] + rows
        for (rowIndex, row) in allRows.enumerated() {
            for column in 0..<columns {
                let cell = NSTextTableBlock(
                    table: table, startingRow: rowIndex, rowSpan: 1,
                    startingColumn: column, columnSpan: 1
                )
                cell.backgroundColor = translucent(style.foreground, 0.06)
                cell.setWidth(4, type: .absoluteValueType, for: .padding, edge: .minY)
                cell.setWidth(4, type: .absoluteValueType, for: .padding, edge: .maxY)
                cell.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxX)
                if rowIndex < allRows.count - 1 {
                    cell.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                    cell.setBorderColor(translucent(style.foreground, 0.12), for: .maxY)
                }
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.textBlocks = [cell]
                let text = column < row.count ? row[column] : ""
                appendParagraph(
                    inline(text, font: rowIndex == 0 ? header : body, color: style.foreground),
                    to: result,
                    paragraphStyle: paragraphStyle
                )
            }
        }
    }

    private static func appendParagraph(
        _ content: NSAttributedString,
        to result: NSMutableAttributedString,
        paragraphStyle: NSParagraphStyle = NSParagraphStyle()
    ) {
        let paragraph = NSMutableAttributedString(attributedString: content)
        paragraph.append(NSAttributedString(string: "\n", attributes: [
            .font: content.length > 0
                ? (content.attribute(.font, at: content.length - 1, effectiveRange: nil) as? NSFont)
                    ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                : NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ]))
        paragraph.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: paragraph.length)
        )
        result.append(paragraph)
    }

    private static func isBoxed(_ block: DevotionalProseBlock) -> Bool {
        switch block {
        case .quote, .table, .rule: true
        default: false
        }
    }

    private static func appendSpacer(height: CGFloat, to result: NSMutableAttributedString) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = height
        paragraphStyle.maximumLineHeight = height
        result.append(NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 1),
            .paragraphStyle: paragraphStyle,
            spacerAttribute: true,
        ]))
    }

    /// Whether the paragraph is a table cell with more of its row to the right.
    private static func continuesRow(_ text: NSAttributedString, at location: Int) -> Bool {
        guard location < text.length,
              let style = text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle,
              let cell = style.textBlocks.last as? NSTextTableBlock
        else { return false }
        return cell.startingColumn + cell.columnSpan < cell.table.numberOfColumns
    }

    private static func paragraphRange(containing location: Int, in text: NSAttributedString) -> NSRange {
        (text.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
    }

    private static func setSpacing(
        before: CGFloat = 0,
        after: CGFloat = 0,
        in range: NSRange,
        of text: NSMutableAttributedString
    ) {
        guard range.length > 0,
              let current = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        else { return }
        let updated = current.mutableCopy() as! NSMutableParagraphStyle
        updated.paragraphSpacingBefore = max(updated.paragraphSpacingBefore, before)
        updated.paragraphSpacing = max(updated.paragraphSpacing, after)
        text.addAttribute(.paragraphStyle, value: updated, range: range)
    }
}

private extension NSFont {
    var monospacedDigitFont: NSFont {
        let descriptor = fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]],
        ])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
