import AppKit
import Foundation
import LampCore

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
        case prose([LampProseBlock])
        case code(language: String?, code: String)
    }

    /// A reply read by core, as the writer's editor reads prose: a soft wrap
    /// joins, which is how an agent writes. This app read it with a block
    /// reader of its own, which disagreed with that editor on 77 of 138 real
    /// writings; an agent's prose is the same prose.
    ///
    /// Remembered by its text, because the view asks on every redraw and a
    /// chat redraws every reply it holds each time the newest one grows. A
    /// reply that has not changed is read once and then recalled; the one
    /// still arriving is read again each time, which is the cost of showing
    /// it as it comes.
    public static func segments(of markdown: String) -> [Segment] {
        // Read a piece at a time, each piece remembered by its own text, so
        // a reply that has grown by a few characters re-reads only the block
        // it grew into. Core cuts only where a piece still reads as it would
        // in the whole (`LampProse.pieces(of:)`).
        var out: [Segment] = []
        for piece in LampProse.pieces(of: markdown) {
            let read: [Segment]
            if let remembered = remembered(piece) {
                read = remembered
            } else {
                read = self.read(piece)
                remember(piece, read)
            }
            // Prose either side of a cut is one run again: the panel draws a
            // run as one text view so a selection can carry from a paragraph
            // into the list under it, and two views cannot be selected at
            // once. The cut is ours, not the writer's, and must not show.
            if case .prose(let blocks) = read.first,
               case .prose(let standing)? = out.last {
                out[out.count - 1] = .prose(standing + blocks)
                out.append(contentsOf: read.dropFirst())
            } else {
                out.append(contentsOf: read)
            }
        }
        return out
    }

    /// The last few replies read, newest last. A transcript redraws all of
    /// its replies together, so this holds enough for a screenful.
    private static let readings = LampProseReadingCache()

    private static func remembered(_ markdown: String) -> [Segment]? {
        readings.value(for: markdown)
    }

    private static func remember(_ markdown: String, _ segments: [Segment]) {
        readings.store(segments, for: markdown)
    }

    private static func read(_ markdown: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [LampProseBlock] = []
        for block in LampProse.blocks(markdown, options: .writing) {
            if case .code(let language, let code) = block {
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
        /// Extra leading between the lines of a paragraph. None by default,
        /// as before; a reply read at length wants a little.
        public var lineSpacing: CGFloat = 0
        /// Between the items of a list.
        public var listItemSpacing: CGFloat = 4

        public init() {}
    }

    /// Prose blocks as one attributed string. Quotes and tables are TextKit 1
    /// text blocks, so it must be shown by a view using TextKit 1.
    public static func attributedString(
        for blocks: [LampProseBlock],
        style: Style = Style()
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var previous: LampProseBlock?
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
        if style.lineSpacing > 0 {
            applyLineSpacing(style.lineSpacing, to: result)
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

    /// Emphasis, inline code, strikethrough and links, as core read them.
    ///
    /// Nothing is parsed here any more: core hands the text over with
    /// Foundation's inline attributes already on it, where this built them
    /// from a Markdown string of its own.
    public static func inline(
        _ text: LampProseText, font: NSFont, color: NSColor
    ) -> NSAttributedString {
        attributed(text.text, font: font, color: color)
    }

    /// The same, for a line of Markdown that did not come from core — a
    /// caption or a label the caller has in hand as a string.
    public static func inline(_ markdown: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let parsed = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
        return attributed(parsed, font: font, color: color)
    }

    private static func attributed(
        _ parsed: AttributedString, font: NSFont, color: NSColor
    ) -> NSAttributedString {
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
        _ block: LampProseBlock,
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
        case .quote(let blocks):
            // One block for every paragraph, so the bar beside them is unbroken.
            let bar = NSTextBlock()
            // Without a width the block isn't laid out as one, and its bar is lost.
            bar.setValue(100, type: .percentageValueType, for: .width)
            bar.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            bar.setBorderColor(translucent(style.foreground, 0.3), for: .minX)
            bar.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
            // Core gives a quote its own blocks rather than a list of
            // paragraphs, so a quoted list or heading keeps what it is.
            let texts = quotedTexts(of: blocks)
            for (index, text) in texts.enumerated() {
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.textBlocks = [bar]
                // Between its paragraphs only: below the last, the gap to the
                // next block is set like any other.
                paragraphStyle.paragraphSpacing = index < texts.count - 1 ? 6 : 0
                appendParagraph(
                    inline(text, font: body, color: style.foreground),
                    to: result,
                    paragraphStyle: paragraphStyle
                )
            }
        case .list(let ordered, let start, let items):
            var lines: [(marker: String, depth: Int, text: LampProseText)] = []
            flatten(items, ordered: ordered, start: start, depth: 0, into: &lines)
            appendList(lines, to: result, style: style)
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
        case .code(_, let code):
            // Code is shown in its own panel; reaching here means a caller
            // passed it in anyway, so it is kept rather than lost.
            appendParagraph(
                NSAttributedString(string: code, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: style.fontSize - 1, weight: .regular),
                    .foregroundColor: style.foreground,
                ]),
                to: result
            )
        case .html(let raw):
            // An agent writes HTML now and then. Shown as the characters it
            // wrote, which is what this app has always done with it.
            appendParagraph(
                inline(raw, font: body, color: style.foreground),
                to: result
            )
        case .footnote(let label, let blocks):
            appendParagraph(
                inline("[^\(label)]:", font: body, color: style.foreground),
                to: result
            )
            for inner in blocks { append(inner, to: result, style: style) }
        case .audio(let caption, _), .picture(let caption, _):
            // A reply's media is not fetched here; its caption says what was
            // meant rather than leaving a gap.
            guard !caption.isEmpty else { return }
            appendParagraph(inline(caption, font: body, color: style.foreground), to: result)
        }
    }

    /// A quote's text, a paragraph at a time, with anything that is not a
    /// paragraph read for its words rather than dropped.
    private static func quotedTexts(of blocks: [LampProseBlock]) -> [LampProseText] {
        var out: [LampProseText] = []
        for block in blocks {
            switch block {
            case .paragraph(let text), .heading(_, let text):
                out.append(text)
            case .quote(let inner):
                out.append(contentsOf: quotedTexts(of: inner))
            case .list(_, _, let items):
                for item in items { out.append(contentsOf: quotedTexts(of: item.blocks)) }
            case .footnote(_, let inner):
                out.append(contentsOf: quotedTexts(of: inner))
            case .code(_, let code):
                out.append(LampProseText(AttributedString(code)))
            case .html(let raw):
                out.append(LampProseText(AttributedString(raw)))
            case .table(let headers, let rows):
                out.append(contentsOf: headers)
                for row in rows { out.append(contentsOf: row) }
            case .audio(let caption, _), .picture(let caption, _):
                if !caption.isEmpty { out.append(LampProseText(AttributedString(caption))) }
            case .rule:
                break
            }
        }
        return out
    }

    /// Core gives a list as a tree; this draws lines carrying a depth, and
    /// the depth is the tree's own. A numbered list counts from the number
    /// the writer began at.
    private static func flatten(
        _ items: [LampProseItem], ordered: Bool, start: Int, depth: Int,
        into lines: inout [(marker: String, depth: Int, text: LampProseText)]
    ) {
        for (offset, item) in items.enumerated() {
            var markerUsed = false
            for block in item.blocks {
                switch block {
                case .paragraph(let text), .heading(_, let text):
                    lines.append((
                        markerUsed ? "" : (ordered ? "\(start + offset)." : "•"),
                        depth,
                        text
                    ))
                    markerUsed = true
                case .list(let innerOrdered, let innerStart, let inner):
                    flatten(
                        inner, ordered: innerOrdered, start: innerStart,
                        depth: depth + 1, into: &lines
                    )
                default:
                    for text in quotedTexts(of: [block]) {
                        lines.append((markerUsed ? "" : "•", depth, text))
                        markerUsed = true
                    }
                }
            }
        }
    }

    private static func appendList(
        _ items: [(marker: String, depth: Int, text: LampProseText)],
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
            paragraphStyle.paragraphSpacing = style.listItemSpacing
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
        headers: [LampProseText],
        rows: [[LampProseText]],
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
                let text = column < row.count ? row[column] : LampProseText()
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

    private static func isBoxed(_ block: LampProseBlock) -> Bool {
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

    /// Leads every paragraph but a table's cells, whose rows are already
    /// spaced by their padding.
    private static func applyLineSpacing(_ spacing: CGFloat, to text: NSMutableAttributedString) {
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
            let current = (value as? NSParagraphStyle) ?? NSParagraphStyle()
            guard !(current.textBlocks.last is NSTextTableBlock) else { return }
            let updated = current.mutableCopy() as! NSMutableParagraphStyle
            updated.lineSpacing = spacing
            text.addAttribute(.paragraphStyle, value: updated, range: range)
        }
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

/// The replies already read, kept by their text.
///
/// Small and oldest-out: a transcript's replies are read together and the
/// one still arriving changes its text on every token, so holding many would
/// keep every half-finished version of it.
private final class LampProseReadingCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(markdown: String, segments: [AgentProseText.Segment])] = []
    private let limit = 24

    func value(for markdown: String) -> [AgentProseText.Segment]? {
        lock.lock()
        defer { lock.unlock() }
        return entries.last { $0.markdown == markdown }?.segments
    }

    func store(_ segments: [AgentProseText.Segment], for markdown: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append((markdown, segments))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }
}
