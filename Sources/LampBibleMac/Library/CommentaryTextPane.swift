import AppKit
import Combine
import LampCore
import LampModuleKit
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI

// The commentary pane draws a chapter's comment as one text view.
//
// It was a SwiftUI lazy stack with a verse group per row. NIC's groups run to
// 90,000 characters, and the scroll link jumps to a new group at every verse
// the reader passes, so each jump built and laid out a group whole on the main
// thread: the styled text, a search for every reference in it, then the
// layout. Now the chapter's text is built once, off the main thread, and
// TextKit 2 lays it out ahead of the pane in idle moments, so following the
// reader is a scroll to text already laid out.

/// What a chapter's commentary is drawn with, which a change to rebuilds it.
struct CommentaryTextStyle: Hashable, Sendable {
    let fontSize: Double
    let lineSpacing: Double
    let typeface: ProseTypeface
}

/// A chapter's commentary as the pane draws it: the text, and where each
/// passage's comment begins in it.
struct CommentaryDocument: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let title: String
        let unitIDs: [String]
        /// `contentFingerprint(of:)` of the units.
        let content: Int
        let style: CommentaryTextStyle
    }

    /// Everything about the units that is drawn, hashed: their order, heading
    /// levels, words and references. The same units with other words, as a
    /// reinstalled commentary has, are another document.
    static func contentFingerprint(of units: [LampCommentaryUnit]) -> Int {
        var hasher = Hasher()
        for unit in units {
            hasher.combine(unit.id)
            hasher.combine(unit.moduleName)
            hasher.combine(unit.orderIndex)
            hasher.combine(unit.level)
            hasher.combine(unit.title)
            hasher.combine(unit.introduction)
            hasher.combine(unit.translation)
            hasher.combine(unit.commentary)
            hasher.combine(unit.footnotes)
            hasher.combine(unit.startReference)
            hasher.combine(unit.endReference)
            for link in unit.scriptureLinks { hasher.combine(link.id) }
        }
        return hasher.finalize()
    }

    let key: Key
    /// Immutable once built; only ever read.
    let text: NSAttributedString
    /// One per passage, in the order they appear.
    let anchors: [VerseAnchor]
    /// Where each anchor's heading begins, in UTF-16 offsets into `text`.
    let anchorLocations: [Int]

    /// Groups by the passage commented on, in reading order, each drawn as
    /// a heading, its outline paths and its units, with rules between units.
    static func build(title: String, units: [LampCommentaryUnit], style: CommentaryTextStyle) -> CommentaryDocument {
        let groups = CommentaryGroup.groups(of: units)
        var writer = CommentaryTextWriter(style: style)
        var anchors: [VerseAnchor] = []
        var locations: [Int] = []

        writer.append(
            NSAttributedString(string: title, attributes: writer.attributes(font: .systemFont(ofSize: 15, weight: .bold), spaced: false)),
            spacingBefore: 0
        )
        for (index, group) in groups.enumerated() {
            // The group's own 6pt above its heading, after the stack's 18pt
            // and, past the first, the 10pt under the group before.
            locations.append(writer.append(writer.heading(group.title), spacingBefore: index == 0 ? 24 : 34))
            anchors.append(group.anchor)
            // The heading's hairline: 6pt under it, 14pt over what follows.
            writer.ruleBeforeNext(gapAbove: 6, gapBelow: 14)
            let pieces = CommentaryPiece.pieces(of: group.units)
            for (pieceIndex, piece) in pieces.enumerated() {
                switch piece {
                case .outline(_, let titles):
                    writer.append(writer.outlinePath(titles), spacingBefore: 14)
                case .unit(let unit):
                    writer.appendUnit(unit, spacingBefore: 14)
                    // A rule between two pieces of comment, but not before an
                    // outline path, which leads into the comment after it.
                    if pieceIndex < pieces.count - 1 {
                        writer.ruleBeforeNext(gapAbove: 16, gapBelow: 16)
                    }
                }
            }
        }
        return CommentaryDocument(
            key: Key(title: title, unitIDs: units.map(\.id), content: contentFingerprint(of: units), style: style),
            text: writer.output,
            anchors: anchors,
            anchorLocations: locations
        )
    }

    /// The passage whose comment `offset` falls in: the last to begin at or
    /// before it, or the first when it is above them all.
    func anchorIndex(containing offset: Int) -> Int? {
        guard !anchorLocations.isEmpty else { return nil }
        var low = 0
        var high = anchorLocations.count - 1
        guard offset >= anchorLocations[0] else { return 0 }
        while low < high {
            let middle = (low + high + 1) / 2
            if anchorLocations[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }
}

/// The comment on one passage: every unit that starts at its verse.
struct CommentaryGroup: Identifiable {
    let id: Int
    let endReference: Int?
    let title: String
    let units: [LampCommentaryUnit]

    var anchor: VerseAnchor {
        VerseAnchor(reference: id, endReference: endReference)
    }

    /// Grouped by the passage a unit comments on rather than by module, so that a
    /// verse the reader is sitting on is one place in this panel even when three
    /// commentaries have something to say about it.
    static func groups(of units: [LampCommentaryUnit]) -> [CommentaryGroup] {
        Dictionary(grouping: units, by: \.startReference)
            .compactMap { startReference, units -> CommentaryGroup? in
                let endReference = units.compactMap(\.endReference).max()
                return CommentaryGroup(
                    id: startReference,
                    endReference: endReference,
                    title: LampBibleReferenceFormatter.describeRange(
                        from: startReference,
                        to: endReference ?? startReference
                    ),
                    units: units.sorted {
                        ($0.moduleName, $0.orderIndex) < ($1.moduleName, $1.orderIndex)
                    }
                )
            }
            .sorted { $0.id < $1.id }
    }
}

/// A group's comment as it is drawn: each run of headings with nothing under
/// them folded into one outline path, then the units that have something to
/// say.
enum CommentaryPiece: Identifiable {
    case outline(id: String, titles: [String])
    case unit(LampCommentaryUnit)

    var id: String {
        switch self {
        case .outline(let id, _): "outline:\(id)"
        case .unit(let unit): "unit:\(unit.id)"
        }
    }

    static func pieces(of units: [LampCommentaryUnit]) -> [CommentaryPiece] {
        var pieces: [CommentaryPiece] = []
        var titles: [String] = []
        var firstID: String?
        func flush() {
            if let firstID, !titles.isEmpty {
                pieces.append(.outline(id: firstID, titles: titles))
            }
            titles = []
            firstID = nil
        }
        for unit in units {
            if !unit.hasBody, let title = unit.title {
                if firstID == nil { firstID = "\(unit.id)" }
                titles.append(title)
            } else {
                flush()
                pieces.append(.unit(unit))
            }
        }
        flush()
        return pieces
    }
}

extension LampCommentaryUnit {
    /// Whether the unit has any prose, rather than only a title: an outline
    /// heading ("Text, Exposition, and Notes") over the units that follow.
    var hasBody: Bool {
        [introduction, translation, commentary, footnotes].contains { $0?.isEmpty == false }
    }

    /// Notes that are the whole of what the unit says, which some
    /// commentaries keep their main comment in. Set as the comment, not as
    /// small grey footnotes, or the pane's main text is its faintest.
    var footnotesAreTheComment: Bool {
        [introduction, translation, commentary].allSatisfy { $0?.isEmpty != false }
    }
}

extension NSAttributedString.Key {
    /// A hairline drawn above a paragraph, as a `Divider` was between two
    /// views: the value is the gap under it, in points, to the paragraph's
    /// first line.
    static let lampCommentaryRuleAbove = NSAttributedString.Key("lampCommentaryRuleAbove")
    /// The SF Symbol drawn before a paragraph's first line, in its indent:
    /// a `CommentaryIcon`.
    static let lampCommentaryIcon = NSAttributedString.Key("lampCommentaryIcon")
    /// The empty paragraph that leaves room under the last passage.
    static let lampCommentaryTail = NSAttributedString.Key("lampCommentaryTail")
}

/// A symbol set before a paragraph, as a SwiftUI `Label` sets its icon.
final class CommentaryIcon: NSObject {
    let symbolName: String
    let pointSize: CGFloat
    let weight: NSFont.Weight
    let color: NSColor

    init(symbolName: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) {
        self.symbolName = symbolName
        self.pointSize = pointSize
        self.weight = weight
        self.color = color
    }

    /// The symbol in `color` as it resolves in the appearance being drawn.
    func image() -> NSImage? {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            )
    }

    var width: CGFloat { image()?.size.width ?? pointSize }
}

/// Builds the chapter's text, a paragraph style per block so the gaps match
/// the stack the pane used to be.
private struct CommentaryTextWriter {
    let style: CommentaryTextStyle
    let output = NSMutableAttributedString()
    /// A rule to draw above the next block: the gap over it and under it.
    private var pendingRule: (above: CGFloat, below: CGFloat)?
    private let fontSize: CGFloat
    private let lineSpacing: CGFloat

    init(style: CommentaryTextStyle) {
        self.style = style
        fontSize = LampTextScale.commentaryText.clamped(style.fontSize)
        lineSpacing = LampTextScale.commentaryLineSpacing.clamped(style.lineSpacing)
    }

    /// Commentary is English that quotes Hebrew. A paragraph opening on a
    /// Hebrew word would take a right-to-left base direction and draw
    /// "(2 Sam. 22:1)" as "(Sam. 22:1 2)", so every paragraph is held left to
    /// right.
    /// `spaced` for text inside a unit, which the stack set with the reader's
    /// line spacing; headings and paths outside it had none.
    func paragraphStyle(
        font: NSFont,
        spaced: Bool = true,
        lineBreakMode: NSLineBreakMode = .byWordWrapping,
        headIndent: CGFloat = 0
    ) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = spaced ? lineSpacing : 0
        paragraph.minimumLineHeight = Self.lineHeight(of: font)
        paragraph.baseWritingDirection = .leftToRight
        paragraph.alignment = .left
        paragraph.lineBreakMode = lineBreakMode
        paragraph.firstLineHeadIndent = headIndent
        paragraph.headIndent = headIndent
        return paragraph
    }

    func attributes(font: NSFont, color: NSColor = .labelColor, spaced: Bool = true) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color, .paragraphStyle: paragraphStyle(font: font, spaced: spaced)]
    }

    /// A line's height as SwiftUI's `Text` sets it, which the pane was: the
    /// ascender rounded and the descender rounded up. TextKit rounds their
    /// sum, a point shorter at the default 15pt; measured against SwiftUI
    /// for both typefaces from 11 to 20pt.
    static func lineHeight(of font: NSFont) -> CGFloat {
        font.ascender.rounded() + (-font.descender).rounded(.up)
    }

    func proseFont(size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        var descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        if style.typeface == .serif, let serif = descriptor.withDesign(.serif) { descriptor = serif }
        if italic { descriptor = descriptor.withSymbolicTraits(.italic) }
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    /// Appends `block` as one or more paragraphs, `spacingBefore` above the
    /// first, and returns where it begins.
    @discardableResult
    mutating func append(_ block: NSAttributedString, spacingBefore: CGFloat) -> Int {
        if output.length > 0 {
            let previous = output.attributes(at: output.length - 1, effectiveRange: nil)
            output.append(NSAttributedString(string: "\n", attributes: previous))
        }
        let start = output.length
        output.append(block)
        let string = output.string as NSString
        let firstParagraph = string.paragraphRange(for: NSRange(location: start, length: 0))
        var space = spacingBefore
        if let rule = pendingRule {
            // The rule's room, a point for the line itself, is the space
            // above this paragraph, which draws the rule in it.
            space = rule.above + 1 + rule.below
            output.addAttribute(.lampCommentaryRuleAbove, value: rule.below, range: firstParagraph)
            pendingRule = nil
        }
        // TextKit sets a paragraph's line spacing above its first line too,
        // where the stack of views set none, so that much less space here.
        // Measured: a heading with none, then text with 6pt, had 6pt too many.
        let ownLineSpacing = block.length > 0
            ? (block.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing ?? 0
            : 0
        let spacing = max(space - ownLineSpacing, 0)
        guard spacing > 0 else { return start }
        output.enumerateAttribute(.paragraphStyle, in: firstParagraph) { value, range, _ in
            guard let paragraph = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
            paragraph.paragraphSpacingBefore = spacing
            output.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
        return start
    }

    /// A hairline across the column above the next block, as a `Divider`
    /// drew it between two views. It is drawn by that block's paragraph
    /// rather than being one of its own: TextKit gives a line holding only
    /// a space a height of its own, whatever its font.
    mutating func ruleBeforeNext(gapAbove: CGFloat, gapBelow: CGFloat) {
        pendingRule = (gapAbove, gapBelow)
    }

    /// The passage's running head: the reference in small capitals beside a
    /// book, as `lampSectionHeading` sets a label.
    func heading(_ title: String) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let icon = CommentaryIcon(symbolName: "text.book.closed", pointSize: 11, weight: .semibold, color: .lampSecondaryText)
        return NSAttributedString(string: title.uppercased(), attributes: [
            .font: font,
            .kern: 0.7,
            .foregroundColor: NSColor.lampSecondaryText,
            .paragraphStyle: paragraphStyle(font: font, spaced: false, headIndent: icon.width + 5),
            .lampCommentaryIcon: icon,
        ])
    }

    /// Where the comment sits in the commentary's outline: its headings that
    /// have nothing under them, as one quiet line ("Opening discussion ›
    /// Text, Exposition, and Notes") cut short in the middle.
    func outlinePath(_ titles: [String]) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: max(fontSize - 2, 11), weight: .medium)
        let icon = CommentaryIcon(
            symbolName: "list.bullet.indent",
            pointSize: max(fontSize - 3, 10),
            weight: .semibold,
            color: .lampSecondaryText
        )
        var base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.lampSecondaryText,
            .paragraphStyle: paragraphStyle(font: font, spaced: false, lineBreakMode: .byTruncatingMiddle, headIndent: icon.width + 7),
            .lampCommentaryIcon: icon,
            .toolTip: titles.joined(separator: " › "),
        ]
        let path = NSMutableAttributedString()
        for (index, title) in titles.enumerated() {
            if index > 0 {
                var separator = base
                separator[.foregroundColor] = NSColor.tertiaryLabelColor
                path.append(NSAttributedString(string: "  ›  ", attributes: separator))
            }
            path.append(NSAttributedString(string: title, attributes: base))
        }
        base.removeAll()
        return path
    }

    mutating func appendUnit(_ unit: LampCommentaryUnit, spacingBefore: CGFloat) {
        var spacing = spacingBefore
        func add(_ block: NSAttributedString) {
            append(block, spacingBefore: spacing)
            spacing = 10
        }
        if let title = unit.title {
            let font = unit.hasBody
                ? proseFont(size: fontSize + (unit.level <= 1 ? 3 : 1), weight: unit.level <= 1 ? .bold : .semibold)
                : NSFont.systemFont(ofSize: max(fontSize - 2, 11), weight: .medium)
            add(NSAttributedString(
                string: title,
                attributes: attributes(font: font, color: unit.hasBody ? .labelColor : .lampSecondaryText)
            ))
        }
        let links = unit.scriptureLinks
        if let introduction = unit.introduction {
            add(linked(introduction, links: links, font: proseFont(size: fontSize), color: .lampProse))
        }
        if let translation = unit.translation {
            add(linked(translation, links: links, font: proseFont(size: fontSize, italic: true), color: .lampSecondaryText))
        }
        if let commentary = unit.commentary {
            add(linked(commentary, links: links, font: proseFont(size: fontSize), color: .lampProse))
        }
        if let footnotes = unit.footnotes {
            if unit.footnotesAreTheComment {
                add(linked(footnotes, links: links, font: proseFont(size: fontSize), color: .lampProse))
            } else {
                add(linked(footnotes, links: links, font: proseFont(size: max(fontSize - 1.5, 10)), color: .lampSecondaryText))
            }
        }
        let unmatched = Self.unmatchedLinks(of: unit)
        if !unmatched.isEmpty {
            add(appendedLinks(unmatched, font: proseFont(size: fontSize)))
        }
    }

    /// `text` with each reference linked where its words first appear and
    /// are not already a link: as written, then in any case.
    func linked(_ text: String, links: [LampScriptureLink], font: NSFont, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: attributes(font: font, color: color))
        let string = text as NSString
        var occupied: [NSRange] = []
        for link in links {
            guard let url = link.inlineURL,
                  let range = Self.firstAvailableRange(of: link.inlineLabel, in: string, occupied: occupied) else { continue }
            result.addAttributes([.link: url, .foregroundColor: NSColor.lampLink], range: range)
            occupied.append(range)
        }
        return result
    }

    static func firstAvailableRange(of label: String, in string: NSString, occupied: [NSRange]) -> NSRange? {
        guard !label.isEmpty else { return nil }
        for options: NSString.CompareOptions in [[], [.caseInsensitive]] {
            var searchRange = NSRange(location: 0, length: string.length)
            while searchRange.length > 0 {
                let range = string.range(of: label, options: options, range: searchRange)
                guard range.location != NSNotFound else { break }
                if !occupied.contains(where: { NSIntersectionRange($0, range).length > 0 }) { return range }
                let next = NSMaxRange(range)
                searchRange = NSRange(location: next, length: string.length - next)
            }
        }
        return nil
    }

    /// Annotation offsets are local to the source JSON objects and the core model
    /// exposes their derived labels. Almost every annotation therefore maps back
    /// to its phrase exactly; this keeps malformed legacy annotations available as
    /// inline trailing links without bringing back a separate references panel.
    static func unmatchedLinks(of unit: LampCommentaryUnit) -> [LampScriptureLink] {
        let texts = [unit.introduction, unit.translation, unit.commentary, unit.footnotes]
            .compactMap { $0 }
        return unit.scriptureLinks.filter { link in
            let label = link.inlineLabel
            return !texts.contains { $0.range(of: label, options: [.caseInsensitive]) != nil }
        }
    }

    func appendedLinks(_ links: [LampScriptureLink], font: NSFont) -> NSAttributedString {
        let base = attributes(font: font)
        let result = NSMutableAttributedString(string: "(", attributes: base)
        for (index, link) in links.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "; ", attributes: base)) }
            var attributes = base
            if let url = link.inlineURL {
                attributes[.link] = url
                attributes[.foregroundColor] = NSColor.lampLink
            }
            result.append(NSAttributedString(string: link.inlineLabel, attributes: attributes))
        }
        result.append(NSAttributedString(string: ")", attributes: base))
        return result
    }
}

/// Built chapters, so returning to one, or to its tab, draws it at once.
@MainActor
enum CommentaryDocumentCache {
    private static var entries: [CommentaryDocument] = []
    private static let capacity = 6

    static func document(for key: CommentaryDocument.Key) -> CommentaryDocument? {
        entries.first { $0.key == key }
    }

    static func keep(_ document: CommentaryDocument) {
        entries.removeAll { $0.key == document.key }
        entries.insert(document, at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }
}

// MARK: - The pane

/// A chapter's commentary in one text view, linked to the reader's scroll.
///
/// It reports the passage at its top edge to the scroll link and follows the
/// reader's, as `VerseAnchoredScrollView` does for the other panes. A tab kept
/// out of sight neither follows the reader on screen nor speaks for it.
struct CommentaryTextPane: NSViewRepresentable {
    let document: CommentaryDocument
    /// The verse the reader has selected, followed whether or not the link
    /// is on: that is selection, not scroll linking.
    let focusedReference: Int?
    let scrollLink: ReaderScrollLink
    let pane: StudyPaneState?
    /// A reference clicked, and where its words are, in this view's space.
    let openLink: (URL, CGRect) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CommentaryScrollView {
        let scrollView = CommentaryScrollView()
        context.coordinator.attach(to: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: CommentaryScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.scrollLink = scrollLink
        coordinator.pane = pane
        coordinator.openLink = openLink
        // The selected verse first, so a chapter shown before the reader has
        // reported a position still opens at it.
        coordinator.follow(focusedReference)
        coordinator.show(document)
    }

    static func dismantleNSView(_ scrollView: CommentaryScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextLayoutManagerDelegate {
        var scrollLink: ReaderScrollLink? {
            didSet {
                guard scrollLink !== oldValue else { return }
                readerSubscription = scrollLink?.readerAnchors.sink { [weak self] reference in
                    self?.followReader(to: reference)
                }
            }
        }
        weak var pane: StudyPaneState?
        var openLink: ((URL, CGRect) -> Void)?

        private weak var scrollView: CommentaryScrollView?
        private var textView: CommentaryTextView?
        private var document: CommentaryDocument?
        /// The selected verse last seen, and whether one has been: the first
        /// is where the pane starts, not a selection to follow.
        private var focusedReference: Int?
        private var hasSeenFocus = false
        /// The passage the pane last moved itself to, held at the top until a
        /// person scrolls, clicks or types in the pane. TextKit moves the
        /// view itself in its layout passes, and does not always keep what
        /// was at the top there, so after each pass the pane puts it back.
        private var pinnedAnchor: VerseAnchor?
        private var isHoldingPin = false
        /// Whether a person is dragging or flicking the pane, while which
        /// the layout ahead waits.
        private var isLiveScrolling = false
        /// Where the layout ahead has reached, and which pass it belongs to.
        private var layoutCursor: NSTextLocation?
        private var layoutGeneration = 0
        private var readerSubscription: AnyCancellable?
        private var observers: [NSObjectProtocol] = []
        /// Set while this pane moves itself, so the move is not reported as
        /// the reader's own scrolling of it.
        private var isMovingItself = false
        /// The text at the top edge, kept so a change of width or of layout
        /// above it leaves the same words there: the line holding `topOffset`,
        /// with the top edge `topLineInset` below that line's top.
        private var topOffset = 0
        private var topLineInset: CGFloat = 0
        private var isOnScreen: Bool { pane?.isOnScreen ?? true }

        func attach(to scrollView: CommentaryScrollView) {
            self.scrollView = scrollView
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = true
            let scroller = CommentaryScroller()
            scroller.userScrollDidBegin = { [weak self] in self?.userScrollDidBegin() }
            scrollView.verticalScroller = scroller
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.automaticallyAdjustsContentInsets = false

            let textView = CommentaryTextView(usingTextLayoutManager: true)
            textView.didInteract = { [weak self] scrolls in self?.userDidInteract(scrolls: scrolls) }
            textView.didLayOutViewport = { [weak self] in self?.holdPin() }
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = true
            textView.importsGraphics = false
            textView.drawsBackground = false
            textView.allowsUndo = false
            textView.displaysLinkToolTips = false
            textView.isAutomaticLinkDetectionEnabled = false
            textView.textContainerInset = NSSize(width: StudyPaneMetrics.contentInset, height: StudyPaneMetrics.contentInset)
            textView.textContainer?.lineFragmentPadding = 0
            textView.textContainer?.widthTracksTextView = true
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.minSize = .zero
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            textView.linkTextAttributes = [
                .foregroundColor: NSColor.lampLink,
                .cursor: NSCursor.pointingHand,
            ]
            textView.delegate = self
            textView.textLayoutManager?.delegate = self
            scrollView.documentView = textView
            self.textView = textView

            scrollView.userScrollDidBegin = { [weak self] in self?.userScrollDidBegin() }
            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.textView?.updateToolTipUnderPointer()
                        self?.didScroll()
                    }
                },
                center.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.didResize() }
                },
                center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.isLiveScrolling = true
                        self?.userScrollDidBegin()
                    }
                },
                center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.isLiveScrolling = false }
                },
            ]
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            readerSubscription = nil
            layoutGeneration += 1
        }

        // MARK: Content

        func show(_ document: CommentaryDocument) {
            guard document.key != self.document?.key, let textView, let scrollView else { return }
            let sameChapter = self.document.map {
                $0.key.title == document.key.title && $0.key.unitIDs == document.key.unitIDs
            } ?? false
            self.document = document
            moveItself {
                textView.contentLength = nil
                textView.textStorage?.setAttributedString(document.text)
                updateTail()
                textView.contentLength = document.text.length
            }
            textView.updateToolTipUnderPointer()
            if sameChapter {
                // Only the type changed: the same words stay at the top.
                if let pinnedAnchor { scroll(to: pinnedAnchor) } else { restoreTop() }
            } else {
                pinnedAnchor = nil
                topOffset = 0
                topLineInset = 0
                moveItself { scrollView.contentView.scroll(to: .zero) }
                adoptReaderPosition()
            }
            layOutAhead()
        }

        /// A newly shown chapter starts where the reader is, not at its own
        /// first passage, and does not report that first position back.
        private func adoptReaderPosition() {
            guard isOnScreen, let scrollLink, let document else { return }
            scrollLink.prepareForStudyPaneChange()
            guard let reference = scrollLink.currentReaderAnchor ?? focusedReference,
                  let anchor = VerseAnchorResolver.anchor(for: reference, in: document.anchors) else { return }
            scroll(to: anchor)
            scrollLink.toolDidAdopt(anchor.reference)
        }

        func follow(_ reference: Int?) {
            guard hasSeenFocus else {
                hasSeenFocus = true
                focusedReference = reference
                return
            }
            guard reference != focusedReference else { return }
            focusedReference = reference
            guard isOnScreen, let reference, let document,
                  let anchor = VerseAnchorResolver.anchor(for: reference, in: document.anchors) else { return }
            scrollLink?.reset()
            scroll(to: anchor)
        }

        private func followReader(to reference: Int) {
            guard isOnScreen, let document,
                  let anchor = VerseAnchorResolver.anchor(for: reference, in: document.anchors) else { return }
            scroll(to: anchor)
            scrollLink?.toolDidAdopt(anchor.reference)
        }

        // MARK: Scrolling

        /// Puts the passage's heading where the stack put it: its line 6pt
        /// below the top edge, the group's own padding. Placed by the heading's
        /// baseline, which does not depend on where TextKit puts the space
        /// above a paragraph.
        private func scroll(to anchor: VerseAnchor) {
            place(anchor)
            layOutAhead()
        }

        /// Scrolls to `anchor` and pins it there, without restarting the
        /// layout ahead.
        private func place(_ anchor: VerseAnchor) {
            guard let document, let textView, let scrollView,
                  let layoutManager = textView.textLayoutManager,
                  let index = document.anchors.firstIndex(of: anchor) else { return }
            let offset = document.anchorLocations[index]
            guard let location = layoutManager.location(layoutManager.documentRange.location, offsetBy: offset) else { return }
            layoutManager.ensureLayout(for: NSTextRange(location: location))
            guard let fragment = layoutManager.textLayoutFragment(for: location),
                  let line = fragment.textLineFragments.first else { return }
            let font = document.text.attribute(.font, at: offset, effectiveRange: nil) as? NSFont
            let baseline = fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
            let y = baseline - (font?.ascender.rounded() ?? 0) - 6 + textView.textContainerOrigin.y
            moveItself {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(y, 0)))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            recordTop()
            pinnedAnchor = anchor
        }

        /// Scrolls so the top edge is `topLineInset` below the top of the line
        /// holding `topOffset`, laying out only as far as that text needs.
        private func restoreTop() {
            guard let textView, let scrollView, let layoutManager = textView.textLayoutManager,
                  let location = layoutManager.location(layoutManager.documentRange.location, offsetBy: topOffset) else { return }
            layoutManager.ensureLayout(for: NSTextRange(location: location))
            guard let fragment = layoutManager.textLayoutFragment(for: location) else { return }
            let lineTop = lineTop(of: fragment, at: location)
            let y = lineTop + textView.textContainerOrigin.y + topLineInset
            let maxY = max(textView.frame.height - scrollView.contentView.bounds.height, 0)
            moveItself {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(y, 0), maxY)))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        /// The top of the line holding `location`, in the text container.
        private func lineTop(of fragment: NSTextLayoutFragment, at location: NSTextLocation) -> CGFloat {
            let frame = fragment.layoutFragmentFrame
            guard let layoutManager = fragment.textLayoutManager,
                  let start = fragment.rangeInElement.location as NSTextLocation?,
                  !fragment.textLineFragments.isEmpty else { return frame.minY }
            let offset = layoutManager.offset(from: start, to: location)
            let line = fragment.textLineFragments.first {
                NSLocationInRange(offset, $0.characterRange) || offset < $0.characterRange.location
            } ?? fragment.textLineFragments[0]
            return frame.minY + line.typographicBounds.minY
        }

        private func moveItself(_ body: () -> Void) {
            let wasMoving = isMovingItself
            isMovingItself = true
            body()
            isMovingItself = wasMoving
        }

        private func didScroll() {
            guard !isMovingItself else { return }
            recordTop()
            // Pinned, the pane is where it put itself, and any move is
            // TextKit's own, not a person's scrolling to tell the reader of.
            guard pinnedAnchor == nil, isOnScreen, let document,
                  let index = document.anchorIndex(containing: topOffset) else { return }
            scrollLink?.toolDidScroll(to: document.anchors[index].reference)
        }

        /// Notes the text at the top edge, for `restoreTop`.
        private func recordTop() {
            guard let textView, let scrollView, let layoutManager = textView.textLayoutManager else { return }
            let top = scrollView.contentView.bounds.minY - textView.textContainerOrigin.y
            guard let fragment = fragment(at: top, in: layoutManager) else { return }
            let frame = fragment.layoutFragmentFrame
            let line = fragment.textLineFragments.last { frame.minY + $0.typographicBounds.minY <= top }
                ?? fragment.textLineFragments.first
            let start = layoutManager.offset(from: layoutManager.documentRange.location, to: fragment.rangeInElement.location)
            topOffset = start + (line?.characterRange.location ?? 0)
            topLineInset = top - (line.map { frame.minY + $0.typographicBounds.minY } ?? frame.minY)
        }

        private func didResize() {
            updateTail()
            // A new width wraps every line again; keep the same words on top.
            if let pinnedAnchor { scroll(to: pinnedAnchor) } else { restoreTop() }
            layOutAhead()
        }

        private func userScrollDidBegin() {
            pinnedAnchor = nil
            guard isOnScreen else { return }
            scrollLink?.toolUserScrollDidBegin()
        }

        /// Puts a pinned passage back where it was put, after TextKit has
        /// moved the view. Placing it lays out again, which comes back here;
        /// the second time nothing moves.
        private func holdPin() {
            guard let pinnedAnchor, !isHoldingPin else { return }
            isHoldingPin = true
            place(pinnedAnchor)
            isHoldingPin = false
        }

        /// A key or a click in the text, or VoiceOver or Find moving through
        /// it: the person has the pane now. All but a click can scroll it,
        /// so they take the link's lead as scrolling does; a click that
        /// selects leaves the lead where it was, as it always did.
        fileprivate func userDidInteract(scrolls: Bool) {
            if scrolls { userScrollDidBegin() } else { pinnedAnchor = nil }
        }

        /// Room under the last passage for it to reach the top, as the reader
        /// leaves under its last verse: a last, empty paragraph as tall as the
        /// pane. Not a bottom content inset, over which AppKit lays a scroll
        /// edge view that takes every click, so links and selection never
        /// reached the text.
        private func updateTail() {
            guard let scrollView, let storage = textView?.textStorage else { return }
            let tail = max(ReaderScrollTail.height(for: scrollView.contentView.bounds.height), 1)
            var range = NSRange(location: NSNotFound, length: 0)
            let hasTail = storage.length > 0
                && storage.attribute(.lampCommentaryTail, at: storage.length - 1, effectiveRange: &range) != nil
            if hasTail,
               (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.minimumLineHeight == tail {
                return
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = tail
            paragraph.maximumLineHeight = tail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 1),
                .paragraphStyle: paragraph,
                .lampCommentaryTail: true,
            ]
            if hasTail {
                storage.setAttributes(attributes, range: range)
            } else {
                // The break belongs to the paragraph it ends, and keeps its look.
                let previous = storage.length > 0 ? storage.attributes(at: storage.length - 1, effectiveRange: nil) : [:]
                storage.append(NSAttributedString(string: "\n", attributes: previous))
                storage.append(NSAttributedString(string: " ", attributes: attributes))
            }
        }

        // MARK: Layout ahead

        /// Lays out the chapter from the top of the pane down, a few
        /// milliseconds at a time while nothing else is happening, so the
        /// next passage the reader reaches is already laid out and scrolling
        /// to it only draws. Never above the top edge: text laid out there
        /// changes height from TextKit's estimate, and TextKit's correction
        /// for that moved what was on screen. TextKit lays out what is above
        /// itself, as it comes into view.
        private func layOutAhead() {
            layoutGeneration += 1
            layoutCursor = viewTopLocation()
            scheduleLayoutAhead(generation: layoutGeneration)
        }

        /// Where the paragraph at the pane's top edge begins.
        private func viewTopLocation() -> NSTextLocation? {
            guard let textView, let scrollView, let layoutManager = textView.textLayoutManager else { return nil }
            let top = scrollView.contentView.bounds.minY - textView.textContainerOrigin.y
            return fragment(at: top, in: layoutManager)?.rangeInElement.location
        }

        /// The paragraph at `y` in the text container, or the last one when
        /// `y` is in the room left under it for the last passage to reach
        /// the top.
        private func fragment(at y: CGFloat, in layoutManager: NSTextLayoutManager) -> NSTextLayoutFragment? {
            if let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(y, 0))) { return fragment }
            var last: NSTextLayoutFragment?
            layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.endLocation, options: [.reverse]) { fragment in
                last = fragment
                return false
            }
            return last
        }

        private func scheduleLayoutAhead(generation: Int, after delay: TimeInterval = 0) {
            guard delay > 0 else {
                RunLoop.main.perform(inModes: [.default]) { [weak self] in
                    MainActor.assumeIsolated { self?.layOutSomeAhead(generation: generation) }
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.scheduleLayoutAhead(generation: generation) }
            }
        }

        private func layOutSomeAhead(generation: Int) {
            guard generation == layoutGeneration,
                  let layoutManager = textView?.textLayoutManager,
                  var start = layoutCursor else { return }
            // Never in a frame a person is scrolling through, nor for a tab
            // kept out of sight, which waits until it is shown.
            guard !isLiveScrolling, isOnScreen else {
                scheduleLayoutAhead(generation: generation, after: isOnScreen ? 0.1 : 0.5)
                return
            }
            // A person may have scrolled past where this had reached: carry
            // on from the top edge, never above it.
            if let top = viewTopLocation(), start.compare(top) == .orderedAscending { start = top }
            let deadline = CFAbsoluteTimeGetCurrent() + 0.004
            var next: NSTextLocation? = start
            layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
                next = fragment.rangeInElement.endLocation
                return CFAbsoluteTimeGetCurrent() < deadline
            }
            guard let next, next.compare(layoutManager.documentRange.endLocation) == .orderedAscending,
                  next.compare(start) == .orderedDescending else {
                layoutCursor = nil
                return
            }
            layoutCursor = next
            scheduleLayoutAhead(generation: generation)
        }

        // MARK: TextKit

        func textLayoutManager(
            _ textLayoutManager: NSTextLayoutManager,
            textLayoutFragmentFor location: NSTextLocation,
            in textElement: NSTextElement
        ) -> NSTextLayoutFragment {
            if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 {
                let attributes = paragraph.attributedString.attributes(at: 0, effectiveRange: nil)
                let icon = attributes[.lampCommentaryIcon] as? CommentaryIcon
                let ruleGap = (attributes[.lampCommentaryRuleAbove] as? NSNumber).map { CGFloat($0.doubleValue) }
                if icon != nil || ruleGap != nil {
                    let fragment = CommentaryFragment(textElement: textElement, range: textElement.elementRange)
                    fragment.icon = icon
                    fragment.ruleGap = ruleGap
                    return fragment
                }
            }
            return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)),
                  url.scheme == "lampbible" else { return false }
            openLink?(url, pointerRect() ?? rect(ofLinkAt: charIndex, in: textView))
            return true
        }

        /// Where the click was, as the old pane's preview pointed: a link
        /// that wraps may have its first line out of sight.
        private func pointerRect() -> CGRect? {
            guard let scrollView, let event = NSApp.currentEvent,
                  event.window === scrollView.window else { return nil }
            var point = scrollView.convert(event.locationInWindow, from: nil)
            if !scrollView.isFlipped { point.y = scrollView.bounds.height - point.y }
            return CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
        }

        /// The first line of the link at `charIndex`, in the scroll view's
        /// space as SwiftUI reads it, for the preview to point at.
        private func rect(ofLinkAt charIndex: Int, in textView: NSTextView) -> CGRect {
            guard let scrollView, let storage = textView.textStorage,
                  let layoutManager = textView.textLayoutManager,
                  charIndex < storage.length else { return .zero }
            var linkRange = NSRange(location: charIndex, length: 1)
            _ = storage.attribute(.link, at: charIndex, effectiveRange: &linkRange)
            guard let start = layoutManager.location(layoutManager.documentRange.location, offsetBy: linkRange.location),
                  let end = layoutManager.location(start, offsetBy: linkRange.length),
                  let range = NSTextRange(location: start, end: end) else { return .zero }
            var first = CGRect.zero
            layoutManager.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
                first = frame
                return false
            }
            let origin = textView.textContainerOrigin
            let inTextView = first.offsetBy(dx: origin.x, dy: origin.y)
            var inScrollView = textView.convert(inTextView, to: scrollView)
            if !scrollView.isFlipped {
                inScrollView.origin.y = scrollView.bounds.height - inScrollView.maxY
            }
            return inScrollView
        }
    }
}

/// Tells the pane when a person starts scrolling it, which is the one move
/// that is unambiguously theirs: the link gives it the lead at once.
/// Tells the pane when a person clicks or types in it, which takes the
/// pane back from following the reader just as scrolling does.
final class CommentaryTextView: NSTextView {
    /// How much of the text is the commentary, before the empty paragraph
    /// that leaves room under the last passage. A selection stops there, so
    /// copying never takes that paragraph, a pane high, with it.
    var contentLength: Int?

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        guard let contentLength else {
            super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
            return
        }
        let clamped = ranges.map { value -> NSValue in
            let range = value.rangeValue
            let start = min(range.location, contentLength)
            return NSValue(range: NSRange(location: start, length: min(NSMaxRange(range), contentLength) - start))
        }
        super.setSelectedRanges(clamped, affinity: affinity, stillSelecting: stillSelecting)
    }

    /// Whether what the person did can scroll the pane.
    var didInteract: ((_ scrolls: Bool) -> Void)?
    /// After each of TextKit's layout passes over what is on screen, which
    /// is when it moves the view itself.
    var didLayOutViewport: (() -> Void)?

    // A TextKit 2 text view shows no tooltip of its own for `.toolTip`
    // text, which the outline path's full title is: the view's tooltip is
    // set from the text under the pointer instead.
    private var toolTipArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let toolTipArea { removeTrackingArea(toolTipArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        toolTipArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateToolTip(at: convert(event.locationInWindow, from: nil))
    }

    /// Again when the text moves under a pointer that has not, as it does
    /// when the pane scrolls or follows the reader.
    func updateToolTipUnderPointer() {
        guard let window, window.isKeyWindow else { return }
        updateToolTip(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func updateToolTip(at point: NSPoint) {
        let tip = visibleRect.contains(point) ? toolTip(at: point) : nil
        if tip != toolTip { toolTip = tip }
    }

    /// The `.toolTip` of the text under `point`, in the view's space.
    func toolTip(at point: NSPoint) -> String? {
        guard let storage = textStorage,
              let index = ReaderTextLinkHitTester.characterIndex(at: point, inTextKit2View: self) else { return nil }
        return storage.attribute(.toolTip, at: index, effectiveRange: nil) as? String
    }

    override func textViewportLayoutControllerDidLayout(_ controller: NSTextViewportLayoutController) {
        super.textViewportLayoutControllerDidLayout(controller)
        didLayOutViewport?()
    }

    /// Keys a read-only text view scrolls with; any other key only stops
    /// the pane holding its passage.
    private static let scrollingKeys: Set<NSEvent.SpecialKey> = [
        .pageUp, .pageDown, .home, .end, .upArrow, .downArrow,
    ]

    override func keyDown(with event: NSEvent) {
        let scrolls = event.specialKey.map { Self.scrollingKeys.contains($0) }
            ?? (event.charactersIgnoringModifiers == " ")
        didInteract?(scrolls)
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        didInteract?(false)
        super.mouseDown(with: event)
    }

    // VoiceOver and Find move through the text without a key or a click.
    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        didInteract?(true)
        super.setAccessibilitySelectedTextRange(range)
    }

    override func setAccessibilityVisibleCharacterRange(_ range: NSRange) {
        didInteract?(true)
        super.setAccessibilityVisibleCharacterRange(range)
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        didInteract?(true)
        super.scrollRangeToVisible(range)
    }
}

/// The pane's scroller, which tells it when VoiceOver moves it: that
/// scrolls the pane without a live scroll or a wheel.
final class CommentaryScroller: NSScroller {
    var userScrollDidBegin: (() -> Void)?

    // A subclass is held to the legacy style unless it says it can overlay:
    // always shown, it took width from the text and moved every line.
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func setAccessibilityValue(_ value: Any?) {
        userScrollDidBegin?()
        super.setAccessibilityValue(value)
    }
}

final class CommentaryScrollView: NSScrollView {
    var userScrollDidBegin: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        // A gesture's first event, or any click of a wheel, which has no phase.
        if event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            userScrollDidBegin?()
        }
        super.scrollWheel(with: event)
    }
}

/// A paragraph with a hairline above it, its symbol in its first line's
/// indent, or both. Both are placed from the first line's baseline, which
/// does not depend on where TextKit puts the space above a paragraph.
final class CommentaryFragment: NSTextLayoutFragment {
    var icon: CommentaryIcon?
    /// The gap from the rule down to the first line, when there is a rule.
    var ruleGap: CGFloat?

    private var firstCharacterAttributes: [NSAttributedString.Key: Any] {
        guard let paragraph = (textElement as? NSTextParagraph)?.attributedString, paragraph.length > 0 else { return [:] }
        return paragraph.attributes(at: 0, effectiveRange: nil)
    }

    /// How far the paragraph is indented, which its frame begins at.
    private var indent: CGFloat {
        (firstCharacterAttributes[.paragraphStyle] as? NSParagraphStyle)?.headIndent ?? 0
    }

    private var font: NSFont? { firstCharacterAttributes[.font] as? NSFont }

    private var width: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    /// The first line's baseline, and the top of its line as SwiftUI set it,
    /// in the fragment's own space.
    private var firstLine: (baseline: CGFloat, top: CGFloat)? {
        guard let line = textLineFragments.first else { return nil }
        let baseline = line.typographicBounds.minY + line.glyphOrigin.y
        return (baseline, baseline - (font?.ascender.rounded() ?? 0))
    }

    private func ruleRect() -> CGRect? {
        guard let ruleGap, let firstLine else { return nil }
        return CGRect(x: -indent, y: (firstLine.top - ruleGap - 1).rounded(.down), width: width, height: 1)
    }

    private func iconRect(for image: NSImage) -> CGRect? {
        guard let icon, let firstLine else { return nil }
        // Centred on the text's capitals, as a label centres its icon.
        let capCentre = firstLine.baseline - (font?.capHeight ?? icon.pointSize * 0.7) / 2
        return CGRect(x: -indent, y: capCentre - image.size.height / 2, width: image.size.width, height: image.size.height)
    }

    // TextKit draws a fragment only inside these bounds, which end at its
    // text: the rule above it and the icon beside it are outside.
    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        if let rule = ruleRect() { bounds = bounds.union(rule.insetBy(dx: 0, dy: -1)) }
        if let image = icon?.image(), let rect = iconRect(for: image) { bounds = bounds.union(rect.insetBy(dx: -1, dy: -1)) }
        return bounds
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        if let rule = ruleRect() {
            context.saveGState()
            context.setFillColor(NSColor.separatorColor.cgColor)
            context.fill(rule.offsetBy(dx: point.x, dy: point.y))
            context.restoreGState()
        }
        if let image = icon?.image(), let rect = iconRect(for: image) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            image.draw(
                in: rect.offsetBy(dx: point.x, dy: point.y),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
            )
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
