import AppKit
import Combine
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampModuleKit
import SwiftUI
import UniformTypeIdentifiers

enum ReaderLayoutMode: String, CaseIterable, Identifiable {
    case continuousParagraphs
    case versePerLine
    /// The translation being read and a companion, verse by verse in rows.
    case sideBySide

    var id: Self { self }

    var title: String {
        switch self {
        case .versePerLine: "Verse per Line"
        case .continuousParagraphs: "Continuous Paragraph Flow"
        case .sideBySide: "Side by Side"
        }
    }

    var systemImage: String {
        switch self {
        case .versePerLine: "text.line.first.and.arrowtriangle.forward"
        case .continuousParagraphs: "text.justify.leading"
        case .sideBySide: "rectangle.split.2x1"
        }
    }

    /// Whether each verse is a row of its own, scrolled to by its reference.
    var drawsVerseRows: Bool { self != .continuousParagraphs }
}

/// Which column a verse is drawn in, and so what it carries with it.
enum ReaderVerseColumn: Equatable {
    /// The translation being read, on its own: its marks in the margin beside it.
    case reading
    /// The translation being read, beside companions. The row marks it, since
    /// any column can hold a verse the others lack.
    case main
    /// A companion, by translation: its own highlights and translator's
    /// notes, and none of the reading's notes or marks.
    case companion(String)
    /// A companion set beneath each verse, where columns would be too narrow:
    /// the same, in smaller and quieter type.
    case companionBelow(String)

    var companionID: String? {
        switch self {
        case .companion(let id), .companionBelow(let id): id
        case .reading, .main: nil
        }
    }

    var isCompanion: Bool { companionID != nil }

    var isBelow: Bool {
        if case .companionBelow = self { true } else { false }
    }
}

/// The companions' text for the chapters on screen side by side.
struct ReaderCompanionText {
    /// The companions, in the order of their columns.
    var translationIDs: [String] = []
    /// How the translation being read numbers its verses, for pairing them
    /// with each companion's.
    var mainVersification: LampVersification?
    var columns: [String: ReaderCompanionColumn] = [:]
    /// Every chapter on screen asked for, including those a companion
    /// doesn't have.
    var asked: Set<String> = []

    static func key(book: Int, chapter: Int) -> String { "\(book):\(chapter)" }
}

/// One companion's text.
struct ReaderCompanionColumn {
    /// How the companion numbers its verses.
    var versification: LampVersification
    /// The verses each chapter on screen pairs with, keyed by that chapter:
    /// the companion's own chapter of that number, and any other a verse of
    /// it converts to.
    var chapters: [String: [LampVerse]] = [:]
    var highlights: [Int: [LampVerseHighlight]] = [:]
    /// Its own translator's notes, by verse.
    var footnotes: [Int: LampVerseStudyData] = [:]
}

/// A translator's note the reader has opened: which verse, and which of that
/// verse's notes.
struct ReaderFootnoteKey: Equatable {
    let verse: Int
    let index: Int
    /// The companion whose note it is, or nil for the reading's: side by side,
    /// each translation can mark notes on one verse, each with letters from a.
    var companionID: String?
}

struct ReaderParagraph: Identifiable {
    let verses: [LampVerse]

    var id: Int { verses[0].id }
    var firstVerse: LampVerse { verses[0] }
}

/// The reader and every compact scripture preview use this one grouping rule so
/// paragraph markers, headings, and poetry produce the same breaks everywhere.
enum ReaderParagraphPlanner {
    static func paragraphs(in chapter: LampChapter) -> [ReaderParagraph] {
        let headingVerses = Set(chapter.headings.map(\.beforeVerse))
        var result: [ReaderParagraph] = []
        var current: [LampVerse] = []

        func flushCurrent() {
            guard !current.isEmpty else { return }
            result.append(ReaderParagraph(verses: current))
            current = []
        }

        for verse in chapter.verses {
            let isPoetry = verse.poetry != nil
            let followsPoetry = current.last?.poetry != nil
            let startsParagraph = current.isEmpty
                || verse.beginsParagraph
                || headingVerses.contains(verse.number)
                || isPoetry
                || followsPoetry
            if startsParagraph { flushCurrent() }
            current.append(verse)
            if isPoetry { flushCurrent() }
        }
        flushCurrent()
        return result
    }
}

/// Where each continuously laid-out paragraph currently sits, and which verses it
/// contains, for the scroll link's sub-paragraph anchor.
///
/// Deliberately a plain class rather than a `PreferenceKey` or an observable
/// object. Gathering per-row geometry through the preference system from inside a
/// `LazyVStack` rewrites the key every time a row is materialised — several times
/// in a single pass — which is what SwiftUI reports as "Bound preference
/// ReaderParagraphFramesKey tried to update multiple times per frame", and each of
/// those writes used to re-plan every paragraph in the passage before the frame
/// could finish. Recording into a reference type invalidates no views, so the
/// reader can note positions as often as it likes and read them once per scroll.
@MainActor
final class ReaderParagraphAnchorStore {
    private var frames: [Int: CGRect] = [:]
    private var segmentsByParagraph: [Int: [ReaderParagraphSegment]] = [:]
    private var paragraphsByChapter: [String: [ReaderParagraph]] = [:]

    func record(_ frame: CGRect, for reference: Int) {
        frames[reference] = frame
    }

    func forget(_ reference: Int) {
        frames.removeValue(forKey: reference)
    }

    /// The paragraphs of a chapter, planned once and kept.
    ///
    /// The reader's body rebuilds this list every time it re-evaluates, and it
    /// re-evaluates whenever its frame changes — which is exactly what opening the
    /// study column does. Re-planning every paragraph of a multi-chapter passage
    /// on the main thread, mid-transition, is enough to starve the animation of
    /// frames so completely that it renders only its first and last.
    ///
    /// Filling a cache during a body evaluation is safe here precisely because
    /// this is a plain class: nothing observes it, so nothing is invalidated.
    func paragraphs(in chapter: LampChapter) -> [ReaderParagraph] {
        let key = "\(chapter.translationID):\(chapter.book.id):\(chapter.number)"
        if let cached = paragraphsByChapter[key] { return cached }
        let planned = ReaderParagraphPlanner.paragraphs(in: chapter)
        paragraphsByChapter[key] = planned
        return planned
    }

    /// Plans the passage's paragraphs once, when the passage changes, instead of
    /// on every geometry report.
    func prepare(for chapters: [LampChapter]) {
        frames.removeAll(keepingCapacity: true)
        segmentsByParagraph = Dictionary(
            uniqueKeysWithValues: chapters
                .flatMap { paragraphs(in: $0) }
                .map { paragraph in
                    (paragraph.id, paragraph.verses.map { verse in
                        ReaderParagraphSegment(
                            reference: verse.id,
                            characterCount: verse.text.count + String(verse.number).count + 1
                        )
                    })
                }
        )
    }

    /// The verse at the reader's top edge: the highest paragraph still on screen,
    /// then the verse that far into it.
    var topEdgeReference: Int? {
        guard let (reference, frame) = frames
            .filter({ $0.value.maxY > 0 })
            .min(by: { $0.value.minY < $1.value.minY }) else { return nil }
        guard let segments = segmentsByParagraph[reference], !segments.isEmpty else {
            return reference
        }
        let progress = -frame.minY / max(frame.height, 1)
        return ReaderParagraphAnchorResolver.reference(at: progress, in: segments)
    }
}

struct ReaderPassageChapter: Identifiable {
    let chapter: LampChapter

    var id: String {
        "reader-chapter:\(chapter.translationID):\(chapter.book.id):\(chapter.number)"
    }
}

/// The fonts the reader has asked for. Every paragraph asks for several, and
/// making one from a descriptor each time is a third of what building a
/// paragraph costs. A handful of sizes and weights is all there ever is.
@MainActor
/// A highlight's ground behind the text, one per colour, kept: the reader
/// compares its text before setting it again, and a colour made afresh each
/// time would never compare equal.
///
/// On the dark reader a highlight is the colour lifted a third of the way to
/// white as a translucent tint, keeping the reader's light text (4.5:1 or
/// better over every palette colour). The plain colour at the same strength
/// went to olive and maroon on charcoal; a nearly solid ground with dark
/// words over it was a jarring inversion of the page around it. On white it
/// is a pale wash behind the text's own colour.
enum ReaderHighlightGrounds {
    static var grounds: [NSColor: NSColor] = [:]

    static func ground(for color: NSColor) -> NSColor {
        if let ground = grounds[color] { return ground }
        let lifted = color.usingColorSpace(.sRGB)?.blended(withFraction: 0.35, of: .white) ?? color
        let ground = NSColor(name: nil) { appearance in
            appearance.lampIsDark
                ? lifted.withAlphaComponent(0.38)
                : color.withAlphaComponent(0.32)
        }
        grounds[color] = ground
        return ground
    }
}

enum ReaderFonts {
    struct Key: Hashable {
        let size: CGFloat
        let weight: CGFloat
        let traits: UInt
        let serif: Bool
    }

    static var made: [Key: NSFont] = [:]
}

/// The heights reader text sets to, kept. SwiftUI asks a row its size several
/// times a layout, and again each time the reader is shown, and typesetting
/// the text to answer was most of what showing the reader cost. A height
/// depends only on the text, attributes included, and the width.
private enum ReaderTextHeights {
    private final class Key: NSObject {
        let text: NSAttributedString
        let width: CGFloat

        init(text: NSAttributedString, width: CGFloat) {
            // A copy, so a mutable string changed later can't change a key
            // already in the cache. An immutable one copies as itself.
            self.text = text.copy() as! NSAttributedString
            self.width = width
        }

        override var hash: Int {
            text.string.hash ^ width.hashValue
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return width == other.width && (text === other.text || text.isEqual(to: other.text))
        }
    }

    /// Each key keeps its text alive, and only what's on screen or near it
    /// is ever asked about again, so a few hundred is plenty.
    private static let cache: NSCache<Key, NSNumber> = {
        let cache = NSCache<Key, NSNumber>()
        cache.countLimit = 500
        return cache
    }()

    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        let key = Key(text: text, width: width)
        if let height = cache.object(forKey: key) {
            return CGFloat(height.doubleValue)
        }
        // Measurement must be observational. Resizing the live text container
        // causes NSTextView to invalidate its hosted size while SwiftUI's
        // LazyVStack is still asking for that size. The lazy stack then places
        // the row again, which measures it again, and so on without settling.
        // NSAttributedString's bounding calculation uses an independent layout
        // context and cannot feed back into the represented view.
        let bounds = text.boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let height = max(ceil(bounds.height), 1)
        cache.setObject(NSNumber(value: Double(height)), forKey: key)
        return height
    }
}

/// Reader scripture uses AppKit selection directly. SwiftUI's `.textSelection`
/// installs a `SelectionOverlay` that can enter an unbounded update loop when a
/// lazy scroll view materialises attributed text containing many metadata runs.
/// An ordinary non-editable `NSTextView` provides the same native selection and
/// contextual menu without involving that overlay.
/// Verse text, with the reader's margin beside it.
///
/// The text view reaches back past any indent and into the margin, so that
/// every mark sits in one column at the left of the reader, however the
/// poetry beside it is indented.
struct ReaderSelectableText: View {
    let attributedText: NSAttributedString
    var marks: ReaderMarginMarks = .none
    /// How far the text is set in from the reader's column.
    var indent: CGFloat = 0
    /// Whether the text carries the reader's margin. Side by side, the row
    /// draws the marks, and a margin on the right-hand column would reach
    /// back over the left.
    var showsMargin = true
    let openLink: (URL) -> Void
    var openNote: (Int) -> Void = { _ in }

    private var textLeading: CGFloat { (showsMargin ? ReaderMargin.width : 0) + indent }

    var body: some View {
        ReaderTextRepresentable(
            attributedText: attributedText,
            marks: marks,
            textLeading: textLeading,
            openLink: openLink,
            openNote: openNote
        )
        .padding(.leading, -textLeading)
    }
}

enum ReaderParallel {
    /// Between the columns side by side.
    static let columnGap: CGFloat = 28
    /// A companion set beneath each verse, in from the verse it follows.
    static let stackedIndent: CGFloat = 14
    /// Under this, a column wraps every few words, and the companions move
    /// beneath each verse instead.
    static let minimumColumnWidth: CGFloat = 280
    /// Four columns: more leave too little width for prose on most windows.
    static let maximumCompanions = 3
    /// The widest a column grows, about the measure one has on its own.
    static let maximumColumnWidth: CGFloat = 620

    /// Whether a passage this wide sets the companions beneath each verse,
    /// from the room each column would have.
    static func stacks(passageWidth: CGFloat, columns: Int) -> Bool {
        let gaps = columnGap * CGFloat(max(columns - 1, 0))
        // The rows' own padding, either side.
        return (passageWidth - 16 - gaps) / CGFloat(max(columns, 1)) < minimumColumnWidth
    }
}

/// Where the reader's text sits in its column.
enum ReaderTextInset {
    /// Each row's own inset either side, which leaves room for a highlight's
    /// ground to reach a little past the words. The title and headings take
    /// the same, so the left edge of everything on the page is one line.
    static let horizontal: CGFloat = 8
    /// Between a heading and the text it heads, whichever verse that text
    /// begins with. It used to depend on whether that verse opened a
    /// paragraph, so one heading sat further from its text than the next.
    static let belowHeading: CGFloat = 9
    /// One column's widest, padding included: about 70 characters of the
    /// reader's serif, the middle of the comfortable range for prose, at
    /// whatever size it is set. A fixed 780 ran the default size to 80 and
    /// more, and a large size down to 50.
    static func singleColumnWidth(fontSize: CGFloat) -> CGFloat {
        min(max(fontSize * 34.8, 520), 1_100) + horizontal * 2
    }
}

enum ReaderMargin {
    /// Room for two note icons and the selection bar, left of the column.
    static let width: CGFloat = 52
}

private struct ReaderTextRepresentable: NSViewRepresentable {
    let attributedText: NSAttributedString
    let marks: ReaderMarginMarks
    let textLeading: CGFloat
    let openLink: (URL) -> Void
    let openNote: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(openLink: openLink)
    }

    func makeNSView(context: Context) -> ReaderTextView {
        // TextKit 1: the margin reads its lines from the layout manager, and
        // asking a TextKit 2 view for one switches it over there and then.
        let textView = ReaderTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // Sized by the view, less the margin, rather than tracking its width.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.linkTextAttributes = [:]
        textView.textLeading = textLeading
        textView.textStorage?.setAttributedString(attributedText)
        textView.marks = marks
        textView.openNote = openNote
        textView.selectionStore = context.environment.readerTextSelection
        textView.highlighter = context.environment.readerHighlighter
        return textView
    }

    func updateNSView(_ textView: ReaderTextView, context: Context) {
        context.coordinator.openLink = openLink
        textView.openNote = openNote
        textView.selectionStore = context.environment.readerTextSelection
        textView.highlighter = context.environment.readerHighlighter
        textView.textLeading = textLeading
        if textView.attributedString() != attributedText {
            let selection = textView.selectedRange()
            // Put back, not chosen: it must not bring the highlight bar back.
            textView.isRestoringSelection = true
            textView.textStorage?.setAttributedString(attributedText)
            if selection.location != NSNotFound,
               NSMaxRange(selection) <= attributedText.length {
                textView.setSelectedRange(selection)
            }
            textView.isRestoringSelection = false
        }
        // After the text, which the marks' locations count in.
        textView.marks = marks
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: ReaderTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > textLeading else { return nil }

        return CGSize(
            width: width,
            height: ReaderTextHeights.height(of: attributedText, width: width - textLeading)
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var openLink: (URL) -> Void

        init(openLink: @escaping (URL) -> Void) {
            self.openLink = openLink
        }

        func textView(
            _ textView: NSTextView,
            clickedOnLink link: Any,
            at charIndex: Int
        ) -> Bool {
            let url: URL?
            if let value = link as? URL {
                url = value
            } else if let value = link as? String {
                url = URL(string: value)
            } else {
                url = nil
            }
            guard let url else { return false }
            openLink(url)
            return true
        }
    }
}

/// The reader's text view, with a margin left of the text where the reader
/// marks verses: a bar beside the selected verse's lines, and an icon beside
/// the line where a verse with notes begins.
///
/// Placed from the view's own layout, so a mark always sits on the line it
/// belongs to, at whatever width the text has wrapped to, and a change of
/// marks costs a redraw of the margin rather than a layout of the text.
private final class ReaderTextView: LampTextView {
    var marks = ReaderMarginMarks.none {
        didSet {
            guard marks != oldValue else { return }
            margin.needsDisplay = true
            window?.invalidateCursorRects(for: margin)
        }
    }
    /// Where the text starts: past the margin and any indent.
    var textLeading: CGFloat = ReaderMargin.width {
        didSet {
            guard textLeading != oldValue else { return }
            sizeTextContainer()
        }
    }
    var openNote: ((Int) -> Void)?
    /// Told what the reader selects here, for the reader chat.
    weak var selectionStore: ReaderTextSelectionStore?
    /// Shows the highlight controls by what the reader selects or clicks.
    weak var highlighter: ReaderHighlighter?
    /// Set while the view puts its own selection back after its text is
    /// replaced, which is not the reader choosing anything.
    var isRestoringSelection = false
    /// What was selected before a right-click, which selects the word under
    /// the pointer itself: that word is not what the reader chose to mark.
    private var selectionBeforeRightClick: NSRange?

    /// The strip the marks are drawn in. Drawn in the text view's own pass,
    /// after its text, they never reached the screen.
    private let margin = ReaderMarginView()

    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // Once a drag ends, and only for the reader's own selecting: the view
        // also puts a selection back itself, whenever its text is replaced.
        guard !stillSelecting, window?.firstResponder === self,
              let selectionStore, let textStorage else { return }
        selectionStore.textView(
            self, selected: ReaderTextMarks.passage(in: textStorage, range: selectedRange())
        )
        // A right-click's own word is not a selection to offer a bar for,
        // nor one put back after a redraw.
        guard selectionBeforeRightClick == nil, !isRestoringSelection else { return }
        highlighter?.selectionDidEnd(in: self)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { highlighter?.textViewWillLeave(self) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func rightMouseDown(with event: NSEvent) {
        selectionBeforeRightClick = selectedRange()
        highlighter?.close()
        defer { selectionBeforeRightClick = nil }
        super.rightMouseDown(with: event)
    }

    override var textContainerOrigin: NSPoint { NSPoint(x: textLeading, y: 0) }

    override func mouseDown(with event: NSEvent) {
        // Here rather than in the margin view: SwiftUI hands a click anywhere
        // in the text view to the text view, never asking its subviews.
        if let icon = icon(at: convert(event.locationInWindow, from: nil)) {
            openNote?(icon.reference)
            return
        }
        super.mouseDown(with: event)
        // A click that selected nothing: on a highlight, its controls.
        if event.clickCount == 1, selectedRange().length == 0 {
            highlighter?.didClick(in: self, at: character(under: convert(event.locationInWindow, from: nil)))
        }
    }

    /// What a text view offers for editing, which scripture is not: cut and
    /// paste, and the spelling, substitution, transformation and font menus.
    private static let editingActions: Set<String> = [
        "cut:", "paste:", "pasteAsPlainText:", "showGuessPanel:", "checkSpelling:",
        "toggleContinuousSpellChecking:", "orderFrontSubstitutionsPanel:",
        "toggleSmartInsertDelete:", "uppercaseWord:", "orderFrontFontPanel:", "toggleAutomaticQuoteSubstitution:",
    ]

    private static func removeEditingItems(from menu: NSMenu) {
        for item in menu.items.reversed() {
            let actions = ([item] + (item.submenu?.items ?? [])).compactMap { $0.action.map(NSStringFromSelector) }
            if actions.contains(where: editingActions.contains) { menu.removeItem(item) }
        }
        // No separators left doubled, or at either end.
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem, previousWasSeparator { menu.removeItem(item) } else { previousWasSeparator = item.isSeparatorItem }
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
    }

    /// The character under a point, or `NSNotFound` where there is none:
    /// past the end of a line, the nearest one is a word the reader did not
    /// click.
    private func character(under point: NSPoint) -> Int {
        guard let layoutManager, let textContainer else { return NSNotFound }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard box.insetBy(dx: -1, dy: -2).contains(inContainer) else { return NSNotFound }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        Self.removeEditingItems(from: menu)
        guard let highlighter else { return menu }
        let items = highlighter.menuItems(
            in: self,
            selection: selectionBeforeRightClick ?? selectedRange(),
            at: character(under: convert(event.locationInWindow, from: nil))
        )
        guard !items.isEmpty else { return menu }
        var at = 0
        for item in items {
            menu.insertItem(item, at: at)
            at += 1
        }
        menu.insertItem(.separator(), at: at)
        return menu
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeTextContainer()
    }

    private func sizeTextContainer() {
        if margin.superview !== self { addSubview(margin) }
        margin.frame = NSRect(x: 0, y: 0, width: min(ReaderMargin.width, textLeading), height: bounds.height)
        guard let textContainer else { return }
        let width = max(frame.width - textLeading, 0)
        guard textContainer.size.width != width else { return }
        textContainer.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    }

    fileprivate func drawMarks() {
        guard !marks.isEmpty else { return }
        // The accent, in the margin beside the text rather than in it: the
        // grey bar was too faint to say which verse the study pane is on.
        if let bar = selectionBar() {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
        for icon in placedIcons() {
            icon.image.draw(in: icon.rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// The note icon at a point in the margin, if one is there.
    fileprivate func icon(at point: NSPoint) -> PlacedIcon? {
        placedIcons().first { $0.hitRect.contains(point) }
    }

    // MARK: Placing the marks

    fileprivate struct PlacedIcon {
        let rect: NSRect
        let image: NSImage
        let reference: Int
        let help: String

        var hitRect: NSRect { rect.insetBy(dx: -4, dy: -4) }
    }

    /// The bar beside the selected verse's lines, a little in from the text.
    private func selectionBar() -> NSRect? {
        guard let range = marks.selectedRange,
              let first = lineBand(at: range.location),
              let last = lineBand(at: max(NSMaxRange(range) - 1, range.location))
        else { return nil }
        return NSRect(
            x: ReaderMargin.width - 10.5,
            y: first.minY + 1,
            width: 3,
            height: max(last.maxY - first.minY - 2, 3)
        )
    }

    fileprivate func placedIcons() -> [PlacedIcon] {
        guard !marks.notes.isEmpty else { return [] }
        var bands: [Int: LineBand] = [:]
        let lines = marks.notes.compactMap { note -> (line: Int, note: ReaderMarginMarks.Note)? in
            guard let band = lineBand(at: note.location) else { return nil }
            let line = Int(band.minY.rounded())
            bands[line] = band
            return (line, note)
        }
        var placed: [PlacedIcon] = []
        var slotsUsed: [Int: Int] = [:]
        for icon in ReaderMarginMarks.icons(for: lines) {
            guard let band = bands[icon.line] else { continue }
            let slot = slotsUsed[icon.line, default: 0]
            slotsUsed[icon.line] = slot + 1
            let size = (band.fontSize * 0.72).rounded()
            let image = Self.icon(for: icon.kind, size: size)
            // The reader's own note nearest the text, a little clear of the
            // strip the selection bar is drawn in.
            let centerX = ReaderMargin.width - 15 - size / 2 - CGFloat(slot) * (size + 4)
            let rect = NSRect(
                x: centerX - image.size.width / 2,
                y: band.midText - image.size.height / 2,
                width: image.size.width,
                height: image.size.height
            )
            // Naming the verse: two icons beside one line can open two.
            let verse = LampBibleReferenceFormatter.components(of: icon.reference).verse
            placed.append(PlacedIcon(
                rect: rect,
                image: image,
                reference: icon.reference,
                help: icon.kind == .personal
                    ? "Your note on verse \(verse)"
                    : "Study notes on verse \(verse)"
            ))
        }
        return placed
    }

    private struct LineBand {
        let minY: CGFloat
        let maxY: CGFloat
        /// Halfway up the text's small letters, where an icon looks level with it.
        let midText: CGFloat
        let fontSize: CGFloat
    }

    /// The line a character is set on: from the top of its glyphs to the foot
    /// of their descenders, leaving out the space set below the line.
    private func lineBand(at characterIndex: Int) -> LineBand? {
        guard let layoutManager, let textStorage, textStorage.length > 0 else { return nil }
        let index = min(max(characterIndex, 0), textStorage.length - 1)
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        var lineGlyphs = NSRange()
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        // The body text of the line, not the raised verse number at its start.
        let bodyCharacter = layoutManager.characterIndexForGlyph(at: max(NSMaxRange(lineGlyphs) - 1, lineGlyphs.location))
        let font = textStorage.attribute(.font, at: min(bodyCharacter, textStorage.length - 1), effectiveRange: nil) as? NSFont
            ?? NSFont.systemFont(ofSize: 17)
        let baseline = layoutManager.location(forGlyphAt: layoutManager.glyphIndexForCharacter(at: min(bodyCharacter, textStorage.length - 1))).y
        let originY = fragment.minY + textContainerOrigin.y
        return LineBand(
            minY: originY + baseline - font.ascender,
            maxY: originY + baseline - font.descender,
            midText: originY + baseline - font.xHeight / 2,
            fontSize: font.pointSize
        )
    }

    private static var icons: [String: NSImage] = [:]

    /// A note icon, coloured for its kind: each kind its own symbol as well as
    /// its own colour, so neither depends on telling the colours apart.
    private static func icon(for kind: ReaderMarginMarks.NoteKinds, size: CGFloat) -> NSImage {
        let name = kind == .personal ? "note.text" : "book.closed"
        let key = "\(name)-\(size)"
        if let image = icons[key] { return image }
        let color: NSColor = kind == .personal ? .systemOrange : .systemPurple
        let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.82, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        icons[key] = image
        return image
    }
}

/// The reader's margin beside its text, drawing what the text view places.
/// Clicks pass through it to the text view, which opens a note.
private final class ReaderMarginView: NSView {
    private var textView: ReaderTextView? { superview as? ReaderTextView }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        textView?.drawMarks()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func resetCursorRects() {
        removeAllToolTips()
        for icon in textView?.placedIcons() ?? [] {
            addCursorRect(icon.hitRect, cursor: .pointingHand)
            addToolTip(icon.hitRect, owner: icon.help as NSString, userData: nil)
        }
    }
}

struct PlanReadingChapterRequest: Equatable, Hashable {
    let translationID: String
    let readingID: Int
    let startReference: Int
    let endReference: Int
}

struct ReaderLexicalHoverDetails: Equatable {
    enum Kind: Equatable {
        case mapped(keys: [String])
        case unmapped
    }

    let word: String
    let kind: Kind

    var systemImage: String {
        switch kind {
        case .mapped: "character.book.closed"
        case .unmapped: "text.badge.xmark"
        }
    }

    var message: String {
        switch kind {
        case .mapped(let keys):
            "\(word)  ·  \(keys.joined(separator: " · "))"
        case .unmapped:
            "\(word)  ·  No direct original-language match"
        }
    }
}

@MainActor
final class ReaderLexicalHoverStore: ObservableObject {
    @Published var details: ReaderLexicalHoverDetails?
    let linkActivations = PassthroughSubject<URL, Never>()
    private weak var readerWindow: NSWindow?
    private var eventMonitor: Any?
    private var isDetailsEnabled = false
    private var isScrollFrozen = false
    private var clickTrackingGeneration = 0

    init() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown]
        ) { [weak self] event in
            self?.observe(event)
            return event
        }
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    func configure(isScrollFrozen: Bool) {
        if isScrollFrozen, !self.isScrollFrozen {
            cancelClickTracking()
        }
        self.isScrollFrozen = isScrollFrozen
    }

    func configure(isDetailsEnabled: Bool) {
        guard self.isDetailsEnabled != isDetailsEnabled else { return }
        self.isDetailsEnabled = isDetailsEnabled
        guard !isDetailsEnabled else { return }
        cancelClickTracking()
        details = nil
    }

    func attach(to window: NSWindow?) {
        guard let window else { return }
        if readerWindow !== window {
            cancelClickTracking()
        }
        readerWindow = window
        window.acceptsMouseMovedEvents = true
    }

    func clearForScrolling() {
        cancelClickTracking()
        if details != nil {
            details = nil
        }
    }

    private func observe(_ event: NSEvent) {
        guard isDetailsEnabled,
              let readerWindow,
              event.window === readerWindow else { return }

        switch event.type {
        case .mouseMoved:
            guard !isScrollFrozen else { return }
            updateDetails(for: textHit(at: event.locationInWindow, in: readerWindow))
        case .leftMouseDown:
            beginLinkClickTracking(for: event, in: readerWindow)
        default:
            break
        }
    }

    /// AppKit's selectable text enters its own mouse-tracking loop after mouse-down,
    /// so a local event monitor never sees the matching mouse-up. A block queued in
    /// the default run-loop mode resumes after that tracking loop has completed,
    /// without intercepting or replaying any native text event.
    private func beginLinkClickTracking(for event: NSEvent, in window: NSWindow) {
        cancelClickTracking()
        guard !isScrollFrozen,
              event.clickCount == 1,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let url = textHit(at: event.locationInWindow, in: window)?.link,
              LexiconLookupLink(url: url) != nil,
              let startPoint = event.cgEvent?.location ?? CGEvent(source: nil)?.location else {
            return
        }

        clickTrackingGeneration &+= 1
        let generation = clickTrackingGeneration
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.clickTrackingGeneration == generation else { return }
                let movedBeyondClickTolerance = (CGEvent(source: nil)?.location).map { point in
                    let deltaX = point.x - startPoint.x
                    let deltaY = point.y - startPoint.y
                    return (deltaX * deltaX) + (deltaY * deltaY) > 36
                } ?? false
                guard !movedBeyondClickTolerance,
                      !self.isScrollFrozen else { return }
                self.linkActivations.send(url)
            }
        }
    }

    private func cancelClickTracking() {
        clickTrackingGeneration &+= 1
    }

    private func updateDetails(for hit: ReaderTextHit?) {
        let newDetails: ReaderLexicalHoverDetails?
        if let hit,
           let link = hit.link,
           let lookup = LexiconLookupLink(url: link) {
            newDetails = ReaderLexicalHoverDetails(
                word: lookup.word ?? hit.word ?? lookup.keys.joined(separator: " · "),
                kind: .mapped(keys: lookup.keys)
            )
        } else if let hit, hit.link == nil, let word = hit.word {
            newDetails = ReaderLexicalHoverDetails(word: word, kind: .unmapped)
        } else {
            newDetails = nil
        }
        guard details != newDetails else { return }
        details = newDetails
    }

    private func textHit(at windowPoint: NSPoint, in window: NSWindow) -> ReaderTextHit? {
        for candidate in ReaderLexicalHoverRowRegistry.registeredRows(in: window) {
            guard let row = candidate as?
                    ReaderNativeContextMenuAugmenter.ContextMenuObservationView,
                  Self.isEffectivelyVisible(row) else { continue }
            let localPoint = row.convert(windowPoint, from: nil)
            guard row.visibleRect.insetBy(dx: -2, dy: -2).contains(localPoint) else { continue }
            if let hit = row.textHit(at: windowPoint, in: window) {
                return hit
            }
        }
        return nil
    }

    /// Whether `view` can be seen. SwiftUI hides a view at zero opacity, as the
    /// reader is while another section is shown, by setting a container's
    /// alpha, so the view itself still says it's visible.
    static func isEffectivelyVisible(_ view: NSView) -> Bool {
        var candidate: NSView? = view
        while let current = candidate {
            if current.isHidden || current.alphaValue <= 0 { return false }
            candidate = current.superview
        }
        return true
    }

}

struct ReaderLexicalHoverDetailsView: View {
    @ObservedObject var store: ReaderLexicalHoverStore

    var body: some View {
        if let details = store.details {
            Label(details.message, systemImage: details.systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.bar, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(.separator.opacity(0.45), lineWidth: 0.5)
                }
                .padding(.leading, 14)
                .padding(.bottom, 12)
                .allowsHitTesting(false)
                .accessibilityAddTraits(.isStaticText)
                .transition(.opacity)
        }
    }
}

struct ReaderContextMenuEntry {
    enum Kind {
        case action(() -> Void)
        case submenu([ReaderContextMenuEntry])
        case separator
    }

    let title: String
    let systemImage: String?
    let isEnabled: Bool
    let kind: Kind

    static func action(
        _ title: String,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        perform: @escaping () -> Void
    ) -> Self {
        Self(
            title: title,
            systemImage: systemImage,
            isEnabled: isEnabled,
            kind: .action(perform)
        )
    }

    static func submenu(
        _ title: String,
        systemImage: String? = nil,
        entries: [ReaderContextMenuEntry]
    ) -> Self {
        Self(
            title: title,
            systemImage: systemImage,
            isEnabled: true,
            kind: .submenu(entries)
        )
    }

    static var separator: Self {
        Self(title: "", systemImage: nil, isEnabled: false, kind: .separator)
    }
}

@MainActor
private enum ReaderLexicalHoverRowRegistry {
    private static let rows = NSHashTable<NSView>.weakObjects()

    static func update(_ view: NSView, participates: Bool) {
        rows.remove(view)
        if participates, view.window != nil {
            rows.add(view)
        }
    }

    static func registeredRows(in window: NSWindow) -> [NSView] {
        rows.allObjects.filter { $0.window === window }
    }
}

/// SwiftUI's selectable Text owns selection and the native contextual menu. This
/// non-intercepting sibling only augments that menu and marks lexical reader rows.
struct ReaderNativeContextMenuAugmenter: NSViewRepresentable {
    let entries: [ReaderContextMenuEntry]
    let openLink: (URL) -> Void
    let participatesInLexicalHover: Bool
    let showsLinkCursor: Bool

    init(
        entries: [ReaderContextMenuEntry],
        openLink: @escaping (URL) -> Void,
        participatesInLexicalHover: Bool = false,
        showsLinkCursor: Bool = false
    ) {
        self.entries = entries
        self.openLink = openLink
        self.participatesInLexicalHover = participatesInLexicalHover
        self.showsLinkCursor = showsLinkCursor
    }

    func makeCoordinator() -> Coordinator { Coordinator(entries: entries) }

    func makeNSView(context: Context) -> ContextMenuObservationView {
        let view = ContextMenuObservationView()
        view.menuAugmenter = context.coordinator.augment(menu:)
        view.linkHandler = openLink
        view.participatesInLexicalHover = participatesInLexicalHover
        view.showsLinkCursor = showsLinkCursor
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: ContextMenuObservationView, context: Context) {
        context.coordinator.entries = entries
        view.menuAugmenter = context.coordinator.augment(menu:)
        view.linkHandler = openLink
        view.participatesInLexicalHover = participatesInLexicalHover
        view.showsLinkCursor = showsLinkCursor
    }

    final class Coordinator: NSObject {
        private static let injectedIdentifierPrefix = "lamp.reader-context-menu."

        var entries: [ReaderContextMenuEntry]
        private var actions: [() -> Void] = []

        init(entries: [ReaderContextMenuEntry]) {
            self.entries = entries
        }

        func augment(menu nativeMenu: NSMenu) {
            actions = []
            for item in nativeMenu.items.reversed() where
                item.identifier?.rawValue.hasPrefix(Self.injectedIdentifierPrefix) == true {
                nativeMenu.removeItem(item)
            }

            let customMenu = menu(title: "Reader", entries: entries)
            var insertionIndex = 0
            while let item = customMenu.items.first {
                customMenu.removeItem(item)
                item.identifier = NSUserInterfaceItemIdentifier(
                    "\(Self.injectedIdentifierPrefix)item-\(insertionIndex)"
                )
                nativeMenu.insertItem(item, at: insertionIndex)
                insertionIndex += 1
            }
            if insertionIndex > 0 {
                let separator = NSMenuItem.separator()
                separator.identifier = NSUserInterfaceItemIdentifier(
                    "\(Self.injectedIdentifierPrefix)native-boundary"
                )
                nativeMenu.insertItem(separator, at: insertionIndex)
            }
        }

        private func menu(title: String, entries: [ReaderContextMenuEntry]) -> NSMenu {
            let menu = NSMenu(title: title)
            for entry in entries {
                switch entry.kind {
                case .separator:
                    menu.addItem(.separator())
                case .submenu(let children):
                    let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                    item.image = entry.systemImage.flatMap {
                        NSImage(systemSymbolName: $0, accessibilityDescription: entry.title)
                    }
                    item.submenu = self.menu(title: entry.title, entries: children)
                    menu.addItem(item)
                case .action(let perform):
                    let index = actions.count
                    actions.append(perform)
                    let item = NSMenuItem(
                        title: entry.title,
                        action: #selector(performMenuAction(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.tag = index
                    item.isEnabled = entry.isEnabled
                    item.image = entry.systemImage.flatMap {
                        NSImage(systemSymbolName: $0, accessibilityDescription: entry.title)
                    }
                    menu.addItem(item)
                }
            }
            return menu
        }

        @objc private func performMenuAction(_ sender: NSMenuItem) {
            guard actions.indices.contains(sender.tag) else { return }
            actions[sender.tag]()
        }
    }

    final class ContextMenuObservationView: NSView {
        var menuAugmenter: ((NSMenu) -> Void)?
        var linkHandler: ((URL) -> Void)?
        var showsLinkCursor = false {
            didSet {
                guard oldValue != showsLinkCursor else { return }
                if !showsLinkCursor { restoreLinkCursor() }
                enableMouseMovedEventsIfNeeded()
                updateTrackingAreas()
            }
        }
        var participatesInLexicalHover = false {
            didSet {
                guard oldValue != participatesInLexicalHover else { return }
                ReaderLexicalHoverRowRegistry.update(
                    self,
                    participates: participatesInLexicalHover
                )
            }
        }
        private var eventMonitor: Any?
        private var hasPendingContextClick = false
        private var pendingInternalContextLink = false
        private var pendingContextClickGeneration = 0
        private var linkTrackingArea: NSTrackingArea?
        private var isShowingLinkCursor = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(menuDidBeginTracking(_:)),
                name: NSMenu.didBeginTrackingNotification,
                object: nil
            )
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.rightMouseDown, .leftMouseDown]
            ) { [weak self] event in
                self?.observeMouseEvent(event)
                return event
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            restoreLinkCursor()
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
            NotificationCenter.default.removeObserver(self)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { restoreLinkCursor() }
            enableMouseMovedEventsIfNeeded()
            ReaderLexicalHoverRowRegistry.update(
                self,
                participates: participatesInLexicalHover
            )
        }

        /// `NSTrackingArea.mouseMoved` is only continuous when its window opts in
        /// to moved events. Without this, AppKit still sends occasional enter and
        /// cursor-update events, which makes link cursors appear to work for one
        /// run and then stop as the pointer moves within the same text field.
        private func enableMouseMovedEventsIfNeeded() {
            guard showsLinkCursor else { return }
            window?.acceptsMouseMovedEvents = true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let linkTrackingArea {
                removeTrackingArea(linkTrackingArea)
                self.linkTrackingArea = nil
            }
            guard showsLinkCursor else { return }
            let trackingArea = NSTrackingArea(
                rect: .zero,
                options: [
                    .activeInKeyWindow,
                    .inVisibleRect,
                    .mouseEnteredAndExited,
                    .mouseMoved,
                    .cursorUpdate,
                ],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            linkTrackingArea = trackingArea
        }

        override func mouseEntered(with event: NSEvent) {
            updateLinkCursor(for: event)
        }

        override func mouseMoved(with event: NSEvent) {
            updateLinkCursor(for: event)
        }

        override func cursorUpdate(with event: NSEvent) {
            updateLinkCursor(for: event)
        }

        override func mouseExited(with event: NSEvent) {
            restoreLinkCursor()
        }

        private func observeMouseEvent(_ event: NSEvent) {
            guard let window,
                  event.window === window else {
                return
            }

            switch event.type {
            case .rightMouseDown:
                guard contains(event.locationInWindow) else { return }
                rememberContextClick(
                    hit: textHit(at: event.locationInWindow, in: window)
                )
            case .leftMouseDown:
                guard contains(event.locationInWindow) else { return }
                if event.modifierFlags.contains(.control) {
                    rememberContextClick(
                        hit: textHit(at: event.locationInWindow, in: window)
                    )
                }
            default:
                break
            }
        }

        /// Only where the row can be seen: a hidden reader's rows lie under
        /// whatever section is shown, and must not take its clicks or add to
        /// its context menus.
        private func contains(_ windowPoint: NSPoint) -> Bool {
            bounds.contains(convert(windowPoint, from: nil))
                && ReaderLexicalHoverStore.isEffectivelyVisible(self)
        }

        private func updateLinkCursor(for event: NSEvent) {
            guard showsLinkCursor, let window, event.window === window,
                  contains(event.locationInWindow) else {
                restoreLinkCursor()
                return
            }
            let isOverLink = textHit(at: event.locationInWindow, in: window)?.link != nil
            if isOverLink {
                if !isShowingLinkCursor {
                    NSCursor.pointingHand.push()
                    isShowingLinkCursor = true
                } else {
                    NSCursor.pointingHand.set()
                }
            } else {
                restoreLinkCursor()
            }
        }

        private func restoreLinkCursor() {
            guard isShowingLinkCursor else { return }
            NSCursor.pop()
            isShowingLinkCursor = false
        }

        private func rememberContextClick(hit: ReaderTextHit?) {
            hasPendingContextClick = true
            pendingInternalContextLink = hit?.link.map { LexiconLookupLink(url: $0) != nil } ?? false
            pendingContextClickGeneration &+= 1
            let generation = pendingContextClickGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard self?.pendingContextClickGeneration == generation else { return }
                self?.hasPendingContextClick = false
                self?.pendingInternalContextLink = false
            }
        }

        func textHit(at windowPoint: NSPoint, in window: NSWindow) -> ReaderTextHit? {
            guard let contentView = window.contentView else { return nil }
            let contentPoint = contentView.convert(windowPoint, from: nil)
            var candidate = contentView.hitTest(contentPoint)
            while let view = candidate {
                if let textView = view as? NSTextView,
                   let hit = ReaderTextLinkHitTester.hit(
                        at: textView.convert(windowPoint, from: nil),
                        in: textView
                   ) {
                    return hit
                }
                if let textField = view as? NSTextField,
                   let hit = ReaderTextLinkHitTester.hit(
                        at: textField.convert(windowPoint, from: nil),
                        in: textField
                   ) {
                    return hit
                }
                candidate = view.superview
            }

            // SwiftUI's selectable Text and this non-intercepting representable
            // are sibling branches. Walk outward until their smallest common
            // ancestor is found, rather than searching the entire window first.
            // This also keeps unrelated labels (including the hover readout)
            // from being mistaken for passage text.
            var searchRoot = superview
            while let root = searchRoot {
                if let hit = descendantTextHit(
                    at: windowPoint,
                    in: root,
                    excluding: self
                ) {
                    return hit
                }
                guard root !== contentView else { break }
                searchRoot = root.superview
            }
            return nil
        }

        private func descendantTextHit(
            at windowPoint: NSPoint,
            in root: NSView,
            excluding excludedView: NSView
        ) -> ReaderTextHit? {
            for subview in root.subviews.reversed() where
                subview !== excludedView
                    && !subview.isHidden
                    && subview.alphaValue > 0 {
                let localPoint = subview.convert(windowPoint, from: nil)
                guard subview.bounds.insetBy(dx: -2, dy: -2).contains(localPoint) else {
                    continue
                }
                if let hit = descendantTextHit(
                    at: windowPoint,
                    in: subview,
                    excluding: excludedView
                ) {
                    return hit
                }
                if let textView = subview as? NSTextView,
                   let hit = ReaderTextLinkHitTester.hit(at: localPoint, in: textView) {
                    return hit
                }
                if let textField = subview as? NSTextField,
                   let hit = ReaderTextLinkHitTester.hit(at: localPoint, in: textField) {
                    return hit
                }
            }
            return nil
        }

        @objc private func menuDidBeginTracking(_ notification: Notification) {
            guard hasPendingContextClick,
                  let menu = notification.object as? NSMenu else { return }
            hasPendingContextClick = false
            if pendingInternalContextLink {
                for item in menu.items.reversed() where isNativeLinkCommand(item) {
                    menu.removeItem(item)
                }
            }
            pendingInternalContextLink = false
            menuAugmenter?(menu)
        }

        private func isNativeLinkCommand(_ item: NSMenuItem) -> Bool {
            let action = item.action.map(NSStringFromSelector) ?? ""
            let identifier = item.identifier?.rawValue ?? ""
            let description = "\(item.title) \(action) \(identifier)"
                .lowercased()
                .replacingOccurrences(of: " ", with: "")
            return description.contains("openlink") || description.contains("copylink")
        }
    }
}

/// One hover tracker for the reader. Passage rows remain lightweight markers;
/// the single observer resolves the row and its text immediately on mouse move.
struct ReaderLexicalHoverObserver: NSViewRepresentable {
    let interactionStore: ReaderLexicalHoverStore

    func makeNSView(context: Context) -> HoverObservationView {
        let view = HoverObservationView()
        view.interactionStore = interactionStore
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: HoverObservationView, context: Context) {
        view.interactionStore = interactionStore
    }

    final class HoverObservationView: NSView {
        fileprivate var interactionStore: ReaderLexicalHoverStore? {
            didSet {
                interactionStore?.attach(to: window)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            interactionStore?.attach(to: window)
        }
    }
}

// MARK: - Highlighting in place

/// Where the reader's own words begin in the text drawn for them, so a
/// selection or a click can be traced to a verse and to the `Character` a
/// highlight counts from.
///
/// Set over each run of a verse's words, holding the offset in the verse at
/// which that run begins: a poetry line drawn on its own starts part way in.
/// Verse numbers and note letters inside the run are apparatus, and not
/// counted. The space after a verse number carries no offset, so it is never
/// part of a highlight.
enum ReaderHighlightMarks {
    static let offset = NSAttributedString.Key("LampReaderVerseOffset")

    /// Part of one verse's words, in its `Character`s.
    struct Span: Equatable {
        let reference: Int
        let start: Int
        let end: Int
    }

    /// The verse words in `range`, a span per verse. Words of a companion
    /// translation are left out: highlights are made in the one being read.
    static func spans(in text: NSAttributedString, range: NSRange) -> [Span] {
        var spans: [Span] = []
        forEachBody(in: text) { reference, base, body in
            let overlap = NSIntersectionRange(body, range)
            guard overlap.length > 0 else { return }
            let start = base + characters(in: text, from: body.location, to: overlap.location)
            let end = base + characters(in: text, from: body.location, to: NSMaxRange(overlap))
            guard end > start else { return }
            if let last = spans.last, last.reference == reference, last.end == start {
                spans[spans.count - 1] = Span(reference: reference, start: last.start, end: end)
            } else {
                spans.append(Span(reference: reference, start: start, end: end))
            }
        }
        return spans
    }

    /// The verse and the `Character` in it at a character of the drawn text.
    static func position(in text: NSAttributedString, at index: Int) -> (reference: Int, offset: Int)? {
        var found: (Int, Int)?
        forEachBody(in: text) { reference, base, body in
            guard found == nil, NSLocationInRange(index, body) else { return }
            found = (reference, base + characters(in: text, from: body.location, to: index))
        }
        return found
    }

    /// The drawn range of part of a verse's words, for placing a control by it.
    static func drawnRange(of span: Span, in text: NSAttributedString) -> NSRange? {
        var result: NSRange?
        forEachBody(in: text) { reference, base, body in
            guard reference == span.reference else { return }
            var offset = base
            text.enumerateAttribute(ReaderTextMarks.apparatus, in: body) { value, run, _ in
                guard value == nil else { return }
                let piece = (text.string as NSString).substring(with: run)
                var location = run.location
                for character in piece {
                    let length = String(character).utf16.count
                    if offset >= span.start, offset < span.end {
                        let here = NSRange(location: location, length: length)
                        result = result.map { NSUnionRange($0, here) } ?? here
                    }
                    offset += 1
                    location += length
                }
            }
        }
        return result
    }

    private static func forEachBody(
        in text: NSAttributedString,
        _ visit: (_ reference: Int, _ base: Int, _ body: NSRange) -> Void
    ) {
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(offset, in: whole) { value, run, _ in
            guard let base = (value as? NSNumber)?.intValue,
                  text.attribute(ReaderTextMarks.translation, at: run.location, effectiveRange: nil) == nil,
                  let reference = (text.attribute(ReaderTextMarks.verse, at: run.location, effectiveRange: nil)
                    as? NSNumber)?.intValue else { return }
            visit(reference, base, run)
        }
    }

    /// The verse's own characters between two places in the drawn text.
    private static func characters(in text: NSAttributedString, from start: Int, to end: Int) -> Int {
        guard end > start else { return 0 }
        var count = 0
        text.enumerateAttribute(
            ReaderTextMarks.apparatus, in: NSRange(location: start, length: end - start)
        ) { value, run, _ in
            guard value == nil else { return }
            count += (text.string as NSString).substring(with: run).count
        }
        return count
    }
}

/// The reader's highlight controls, shown where the reader is: by the words
/// selected, by a highlight clicked, and in the right-click menu. The reader
/// view hands it what it needs to read and write highlights.
@MainActor
final class ReaderHighlighter: NSObject {
    struct Actions {
        /// The reader's own highlights on a verse, in the translation read.
        var highlights: (Int) -> [LampVerseHighlight]
        /// How many `Character`s a verse has.
        var verseLength: (Int) -> Int?
        var save: (ReaderHighlightMarks.Span, String, LampHighlightStyle) async throws -> Void
        /// Gives a highlight a new colour or style, keeping its words and set.
        var restyle: (LampVerseHighlight, String, LampHighlightStyle) async throws -> Void
        var delete: (LampVerseHighlight) async throws -> Void
        var openNote: (Int) -> Void
        var copy: ([ReaderHighlightMarks.Span], String) -> Void
        var moreOptions: (Int) -> Void
        var failed: (Error) -> Void
    }

    /// What the controls act on: words not yet highlighted, or highlights
    /// already made.
    enum Target {
        case words([ReaderHighlightMarks.Span], text: String)
        case existing([LampVerseHighlight])
    }

    var actions: Actions?
    private var panel: NSPanel?
    private var dismissMonitor: Any?
    /// What closes the bar when the words it is beside move: the page
    /// scrolling, the window resizing, the panes beside the reader opening.
    private var moveObservers: [NSObjectProtocol] = []
    /// Whether the bar showing is for selected words, not a highlight.
    private var isShowingForSelection = false

    /// The reader's named colours and styles in the set new highlights go
    /// to (`LampHighlightTheme`): "Promise" for green, say. Handed in by the
    /// reader, which reads them from the library.
    var themes: [LampHighlightTheme] = [] {
        didSet { themes = Self.byLastUse(themes) }
    }

    /// The themes used most lately first, so the few the bar has room for
    /// are the ones in use now (`reader.recentHighlightThemes`).
    private static func byLastUse(_ themes: [LampHighlightTheme]) -> [LampHighlightTheme] {
        let recent = UserDefaults.standard.stringArray(forKey: "reader.recentHighlightThemes") ?? []
        return themes.sorted { a, b in
            let ia = recent.firstIndex(of: a.id) ?? Int.max, ib = recent.firstIndex(of: b.id) ?? Int.max
            return ia != ib ? ia < ib : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func noteUse(color: String, style: LampHighlightStyle) {
        guard let used = theme(color: color, style: style) else { return }
        var recent = UserDefaults.standard.stringArray(forKey: "reader.recentHighlightThemes") ?? []
        recent.removeAll { $0 == used.id }
        recent.insert(used.id, at: 0)
        UserDefaults.standard.set(Array(recent.prefix(20)), forKey: "reader.recentHighlightThemes")
        themes = Self.byLastUse(themes)
    }

    /// The theme a colour and style carry, if the reader named them.
    func theme(color: String?, style: LampHighlightStyle) -> LampHighlightTheme? {
        guard let color else { return nil }
        let hex = color.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        return themes.first { $0.color == hex && $0.style == style }
    }

    /// The style a new highlight takes: the last one chosen, as a pen is
    /// picked up again where it was put down.
    var newStyle: LampHighlightStyle {
        get { LampHighlightStyle(rawValue: UserDefaults.standard.integer(forKey: "reader.highlightStyle")) ?? .highlight }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "reader.highlightStyle") }
    }
    private weak var barTextView: NSTextView?

    // MARK: From the text view

    func selectionDidEnd(in textView: NSTextView) {
        let range = textView.selectedRange()
        guard range.length > 0, let storage = textView.textStorage else {
            // Only the words' own bar goes with their selection. A click that
            // opened a highlight's bar also chooses its verse, which redraws
            // the text and puts the empty selection back.
            if isShowingForSelection { close() }
            return
        }
        let spans = ReaderHighlightMarks.spans(in: storage, range: range)
        guard !spans.isEmpty else { close(); return }
        let text = (storage.string as NSString).substring(with: range)
        show(.words(spans, text: text), in: textView, at: range)
    }

    /// A click that selected nothing: on a highlight, it opens that
    /// highlight's controls.
    func didClick(in textView: NSTextView, at index: Int) {
        guard let storage = textView.textStorage, index >= 0, index < storage.length,
              // A link's click is the link's: a verse number, a note's letter.
              storage.attribute(.link, at: index, effectiveRange: nil) == nil,
              let (reference, offset) = ReaderHighlightMarks.position(in: storage, at: index) else { return }
        let here = (actions?.highlights(reference) ?? []).filter { $0.startOffset <= offset && offset < $0.endOffset }
        guard !here.isEmpty else { close(); return }
        let span = ReaderHighlightMarks.Span(reference: reference, start: here[0].startOffset, end: here[0].endOffset)
        let range = ReaderHighlightMarks.drawnRange(of: span, in: storage) ?? NSRange(location: index, length: 1)
        show(.existing(here), in: textView, at: range)
    }

    /// The highlight items for a right-click at `index`: the words selected
    /// when the click is on them, otherwise the verse clicked.
    func menuItems(in textView: NSTextView, selection: NSRange, at index: Int) -> [NSMenuItem] {
        guard let storage = textView.textStorage, let actions else { return [] }
        let target: Target
        if selection.length > 0, NSLocationInRange(index, selection) {
            let spans = ReaderHighlightMarks.spans(in: storage, range: selection)
            guard !spans.isEmpty else { return [] }
            target = .words(spans, text: (storage.string as NSString).substring(with: selection))
        } else if let (reference, offset) = ReaderHighlightMarks.position(in: storage, at: index)
                    ?? verseNumber(in: storage, at: index).map({ ($0, 0) }) {
            let here = actions.highlights(reference).filter { $0.startOffset <= offset && offset < $0.endOffset }
            if !here.isEmpty {
                target = .existing(here)
            } else if let length = actions.verseLength(reference) {
                target = .words([ReaderHighlightMarks.Span(reference: reference, start: 0, end: length)], text: "")
            } else {
                return []
            }
        } else {
            return []
        }

        var items: [NSMenuItem] = []
        let header: String
        switch target {
        case .words(let spans, _):
            header = spans.count == 1 && spans[0].start == 0 && spans[0].end == actions.verseLength(spans[0].reference)
                ? "Highlight Verse" : "Highlight Selection"
        case .existing:
            header = "Highlight"
        }
        items.append(NSMenuItem.sectionHeader(title: header))
        let row = NSMenuItem()
        let palette = NSHostingView(rootView: ReaderHighlightPalette(
            color: currentColor(of: target),
            style: currentStyle(of: target),
            stacked: true,
            choose: { [weak self] hex, style in
                row.menu?.cancelTracking()
                self?.apply(hex, style: style, to: target)
            },
            chooseStyle: { [weak self] style in
                // A highlight takes the style at once; for words, it is the
                // style the colour chosen next is drawn in.
                guard let self else { return }
                if case .existing = target {
                    row.menu?.cancelTracking()
                }
                self.restyle(style, target)
            }
        ))
        palette.frame.size = palette.fittingSize
        row.view = palette
        items.append(row)
        // However many there are, one line: the menu lists them, each with
        // its mark and what it means.
        if !themes.isEmpty {
            let current = theme(color: currentColor(of: target), style: currentStyle(of: target))
            let submenu = NSMenu(title: "Theme")
            for theme in themes {
                let item = NSMenuItem(title: theme.name, action: #selector(menuTheme(_:)), keyEquivalent: "")
                item.target = self
                item.image = Self.themeImage(theme)
                item.subtitle = theme.description
                item.state = theme.id == current?.id ? .on : .off
                item.representedObject = ThemeChoice(theme: theme, target: target)
                submenu.addItem(item)
            }
            let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
            themeItem.image = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)
            themeItem.submenu = submenu
            items.append(themeItem)
        }
        if case .existing(let highlights) = target {
            let remove = NSMenuItem(title: "Remove Highlight", action: #selector(menuRemove(_:)), keyEquivalent: "")
            remove.target = self
            remove.image = NSImage(systemSymbolName: "eraser", accessibilityDescription: nil)
            remove.representedObject = highlights.map(\.id)
            items.append(remove)
        }
        return items
    }

    private func verseNumber(in storage: NSAttributedString, at index: Int) -> Int? {
        guard index >= 0, index < storage.length,
              storage.attribute(ReaderTextMarks.apparatus, at: index, effectiveRange: nil) != nil else { return nil }
        return (storage.attribute(ReaderTextMarks.verse, at: index, effectiveRange: nil) as? NSNumber)?.intValue
    }

    private final class ThemeChoice: NSObject {
        let theme: LampHighlightTheme
        let target: Target
        init(theme: LampHighlightTheme, target: Target) {
            self.theme = theme
            self.target = target
        }
    }

    @objc private func menuTheme(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ThemeChoice else { return }
        apply(choice.theme.color, style: choice.theme.style, to: choice.target)
    }

    /// A theme's mark as a menu image: a swatch of its colour, or a line
    /// under one, as its style draws.
    static func themeImage(_ theme: LampHighlightTheme) -> NSImage {
        markImage(color: theme.color, style: theme.style)
    }

    /// A colour drawn in a style, at a menu item's size: a theme's mark, or
    /// a highlight found.
    static func markImage(color hex: String, style: LampHighlightStyle) -> NSImage {
        let color = NSColor(Color(lampHex: hex) ?? .yellow)
        return NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            switch style {
            case .highlight:
                color.withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 2), xRadius: 3, yRadius: 3).fill()
            case .underlineSolid, .underlineDashed, .underlineDotted:
                color.setStroke()
                let line = NSBezierPath()
                line.lineWidth = 2.5
                line.move(to: NSPoint(x: 1, y: 3))
                line.line(to: NSPoint(x: 15, y: 3))
                if style == .underlineDashed { line.setLineDash([4, 2], count: 2, phase: 0) }
                if style == .underlineDotted {
                    line.lineCapStyle = .round
                    line.setLineDash([0.1, 3.5], count: 2, phase: 0)
                }
                line.stroke()
                NSColor.labelColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: 5, y: 7, width: 6, height: 6)).fill()
            }
            return true
        }
    }

    @objc private func menuRemove(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [Int64], let actions else { return }
        let all = Set(ids)
        Task {
            // The highlights named, wherever they are in the chapter.
            for highlight in highlightsNamed(all) {
                do { try await actions.delete(highlight) } catch { actions.failed(error) }
            }
        }
    }

    private var lastShownHighlights: [LampVerseHighlight] = []
    private func highlightsNamed(_ ids: Set<Int64>) -> [LampVerseHighlight] {
        lastShownHighlights.filter { ids.contains($0.id) }
    }

    // MARK: The bar

    private func show(_ target: Target, in textView: NSTextView, at range: NSRange) {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        close()
        if case .existing(let highlights) = target { lastShownHighlights = highlights }
        if case .words(_, let text) = target { isShowingForSelection = !text.isEmpty } else { isShowingForSelection = false }
        // The first line of what it acts on, so the bar sits just above the
        // words, where the reader is looking.
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var firstLine = NSRect.null
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
        ) { rect, stop in
            firstLine = rect
            stop.pointee = true
        }
        guard !firstLine.isNull else { return }
        firstLine.origin.x += textView.textContainerOrigin.x
        firstLine.origin.y += textView.textContainerOrigin.y

        let bar = ReaderHighlightBar(
            color: currentColor(of: target),
            style: currentStyle(of: target),
            themes: themes,
            // What a highlight means, where the reader said: its theme.
            caption: nil,
            canRemove: { if case .existing = target { return true } else { return false } }(),
            choose: { [weak self] hex, style in self?.apply(hex, style: style, to: target) },
            chooseStyle: { [weak self] style in self?.restyle(style, target) },
            remove: { [weak self] in self?.remove(target) },
            note: { [weak self] in self?.note(target) },
            copy: { [weak self] in self?.copy(target) },
            more: { [weak self] in self?.more(target) }
        )
        // A panel of its own over the page, solid and shadowed, rather than a
        // popover: the popover's glass let the verse beneath show through,
        // and on a white page its edge all but vanished.
        let host = NSHostingView(rootView: bar)
        host.frame.size = host.fittingSize
        let panel = ReaderHighlightPanel(
            contentRect: NSRect(origin: .zero, size: host.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = host
        guard let window = textView.window else { return }
        let onScreen = window.convertToScreen(textView.convert(firstLine, to: nil))
        let size = host.frame.size
        // Centred over the words and clear of them, above their first line,
        // or below it where the window has no room above.
        let margin = ReaderHighlightBar.margin
        var origin = NSPoint(x: onScreen.midX - size.width / 2, y: onScreen.maxY + 6 - margin)
        if origin.y + size.height - margin > window.frame.maxY - 60 {
            origin.y = onScreen.minY - size.height - 6 + margin
        }
        origin.x = min(max(origin.x, window.frame.minX + 8), window.frame.maxX - size.width - 8)
        panel.setFrameOrigin(origin)
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
        barTextView = textView
        // Gone at the next click, scroll or key anywhere else, as a menu is.
        dismissMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
        ) { [weak self] event in
            if event.window !== self?.panel { self?.close() }
            return event
        }
        // Left where it was, it would mark words that are no longer there.
        let center = NotificationCenter.default
        var moved: [(NSNotification.Name, AnyObject)] = [
            (NSWindow.didResizeNotification, window),
            (NSView.frameDidChangeNotification, textView),
        ]
        textView.postsFrameChangedNotifications = true
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            moved.append((NSView.boundsDidChangeNotification, clip))
        }
        moveObservers = moved.map { name, object in
            center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
    }

    /// Closes the bar if it belongs to this text view, which is leaving.
    func textViewWillLeave(_ textView: NSTextView) {
        if barTextView === textView { close() }
    }

    func close() {
        if let dismissMonitor { NSEvent.removeMonitor(dismissMonitor) }
        dismissMonitor = nil
        moveObservers.forEach(NotificationCenter.default.removeObserver)
        moveObservers = []
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
    }

    private func currentStyle(of target: Target) -> LampHighlightStyle {
        if case .existing(let highlights) = target, let first = highlights.first { return first.style }
        return newStyle
    }

    private func restyle(_ style: LampHighlightStyle, _ target: Target) {
        guard case .existing(let highlights) = target else {
            newStyle = style
            return
        }
        guard let actions else { return }
        newStyle = style
        close()
        Task {
            for highlight in highlights where highlight.style != style {
                do {
                    try await actions.restyle(highlight, highlight.color ?? "FFCC00", style)
                } catch {
                    actions.failed(error)
                }
            }
        }
    }

    private func currentColor(of target: Target) -> String? {
        switch target {
        case .existing(let highlights):
            highlights.first?.color.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased() }
        case .words:
            nil
        }
    }

    private func apply(_ hex: String, style: LampHighlightStyle, to target: Target) {
        guard let actions else { return }
        newStyle = style
        noteUse(color: hex, style: style)
        let textView = barTextView
        close()
        Task {
            do {
                switch target {
                case .words(let spans, _):
                    for span in spans {
                        // Highlights wholly inside the words are replaced, so a
                        // colour chosen again reads as a change, not a layer.
                        for old in actions.highlights(span.reference)
                        where old.startOffset >= span.start && old.endOffset <= span.end {
                            try await actions.delete(old)
                        }
                        try await actions.save(span, hex, style)
                    }
                case .existing(let highlights):
                    for highlight in highlights { try await actions.restyle(highlight, hex, style) }
                }
            } catch {
                actions.failed(error)
            }
        }
        // Done with the words: the highlight now marks them.
        if let textView { textView.setSelectedRange(NSRange(location: textView.selectedRange().location, length: 0)) }
    }

    private func remove(_ target: Target) {
        guard let actions, case .existing(let highlights) = target else { return }
        close()
        Task {
            for highlight in highlights {
                do { try await actions.delete(highlight) } catch { actions.failed(error) }
            }
        }
    }

    private func reference(of target: Target) -> Int? {
        switch target {
        case .words(let spans, _): spans.first?.reference
        case .existing(let highlights): highlights.first?.reference
        }
    }

    private func note(_ target: Target) {
        guard let reference = reference(of: target) else { return }
        close()
        actions?.openNote(reference)
    }

    private func copy(_ target: Target) {
        close()
        switch target {
        case .words(let spans, let text): actions?.copy(spans, text)
        case .existing(let highlights):
            let spans = highlights.map {
                ReaderHighlightMarks.Span(reference: $0.reference, start: $0.startOffset, end: $0.endOffset)
            }
            actions?.copy(spans, "")
        }
    }

    private func more(_ target: Target) {
        guard let reference = reference(of: target) else { return }
        close()
        actions?.moreOptions(reference)
    }
}

/// The bar's window: never key, so the text keeps its selection and the
/// reader's keyboard while the bar is up, and a click on it goes straight to
/// the control under the pointer.
private final class ReaderHighlightPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct ReaderHighlighterKey: EnvironmentKey {
    static let defaultValue: ReaderHighlighter? = nil
}

extension EnvironmentValues {
    var readerHighlighter: ReaderHighlighter? {
        get { self[ReaderHighlighterKey.self] }
        set { self[ReaderHighlighterKey.self] = newValue }
    }
}

/// The palette: its colours, the one in use ticked, and the four ways a
/// passage can be marked. A colour marks the words in the style chosen
/// beside it.
struct ReaderHighlightPalette: View {
    let color: String?
    @State var style: LampHighlightStyle
    /// Styles on a line of their own, under the colours: a menu is narrow.
    var stacked = false
    let themes: [LampHighlightTheme]
    let choose: (String, LampHighlightStyle) -> Void
    let chooseStyle: (LampHighlightStyle) -> Void

    init(
        color: String?,
        style: LampHighlightStyle,
        stacked: Bool = false,
        themes: [LampHighlightTheme] = [],
        choose: @escaping (String, LampHighlightStyle) -> Void,
        chooseStyle: @escaping (LampHighlightStyle) -> Void
    ) {
        self.color = color
        _style = State(initialValue: style)
        self.stacked = stacked
        self.themes = themes
        self.choose = choose
        self.chooseStyle = chooseStyle
    }

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: 6) {
                colors
                styles
                if !themes.isEmpty { themeMenu }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
        } else {
            // One row, so the bar covers as little of the passage as it can.
            HStack(spacing: 8) {
                styles
                Divider().frame(height: 20)
                colors
                if !themes.isEmpty { themeMenu }
            }
        }
    }

    /// The reader's named marks, in one pill that says which is in use and
    /// lists them all, the most lately used first: chips took a second row
    /// over the text, and had room for only a few.
    private var themeMenu: some View {
        let current = themes.first { $0.color == color && $0.style == style }
        return Menu {
            ForEach(themes) { theme in
                Button {
                    choose(theme.color, theme.style)
                } label: {
                    Label {
                        Text(theme.name)
                        if let description = theme.description { Text(description) }
                    } icon: {
                        Image(nsImage: ReaderHighlighter.themeImage(theme))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "tag")
                    .font(.system(size: 11))
                Text(current?.name ?? "Themes")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .help(current.map { [$0.name, $0.description].compactMap { $0 }.joined(separator: " — ") }
            ?? "Mark with a theme")
    }

    private func themeName(_ hex: String) -> String? {
        themes.first { $0.color == hex && $0.style == style }?.name
    }

    private var colors: some View {
        HStack(spacing: 4) {
            ForEach(StudyHighlightPalette.colors) { item in
                Button {
                    choose(item.hex, style)
                } label: {
                    HighlightSwatch(color: item.color, isSelected: color == item.hex, size: 20)
                }
                .buttonStyle(.plain)
                // The reader's name for the colour, where they gave it one.
                .help(themeName(item.hex).map { "\($0) (\(item.name))" } ?? item.name)
                .accessibilityLabel("\(item.name) highlight")
            }
        }
    }

    private var styles: some View {
        HStack(spacing: 2) {
            ForEach(LampHighlightStyle.allCases, id: \.self) { option in
                Button {
                    style = option
                    chooseStyle(option)
                } label: {
                    Self.glyph(option, color: Color(lampHex: color ?? "FFCC00") ?? .yellow)
                        .frame(width: 30, height: 28)
                        .background(
                            style == option ? AnyShapeStyle(Color.primary.opacity(0.1)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Self.name(option))
                .accessibilityLabel(Self.name(option))
                .accessibilityAddTraits(style == option ? .isSelected : [])
            }
        }
    }

    static func name(_ style: LampHighlightStyle) -> String {
        switch style {
        case .highlight: "Highlight"
        case .underlineSolid: "Underline"
        case .underlineDashed: "Dashed Underline"
        case .underlineDotted: "Dotted Underline"
        }
    }

    /// The letter "a" marked as the style marks words, in the colour in use,
    /// with the line drawn heavy enough to tell solid, dashed and dotted apart
    /// at a glance.
    @ViewBuilder
    static func glyph(_ style: LampHighlightStyle, color: Color) -> some View {
        // Shapes, not four letters "a" told apart by a hairline: a block of
        // colour for a highlight, and the line itself for each underline.
        switch style {
        case .highlight:
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(0.55))
                .frame(width: 18, height: 13)
        case .underlineSolid, .underlineDashed, .underlineDotted:
            StyleLine(style: style)
                .fill(color)
                .frame(width: 20, height: 3.5)
        }
    }
}

/// The line under a style's sample: solid, three dashes, or five dots.
private struct StyleLine: Shape {
    let style: LampHighlightStyle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch style {
        case .underlineDashed:
            let dash = rect.width / 4
            for i in 0..<3 {
                path.addRect(CGRect(x: CGFloat(i) * dash * 1.5, y: rect.minY, width: dash, height: rect.height))
            }
        case .underlineDotted:
            let step = rect.width / 5
            for i in 0..<5 {
                path.addEllipse(in: CGRect(
                    x: CGFloat(i) * step + (step - rect.height) / 2, y: rect.minY,
                    width: rect.height, height: rect.height
                ))
            }
        default:
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: 1, height: 1))
        }
        return path
    }
}

/// The controls by the words selected or the highlight clicked: how to mark
/// them, then what else one does with a passage one has marked.
struct ReaderHighlightBar: View {
    let color: String?
    let style: LampHighlightStyle
    let themes: [LampHighlightTheme]
    let caption: String?
    let canRemove: Bool
    let choose: (String, LampHighlightStyle) -> Void
    let chooseStyle: (LampHighlightStyle) -> Void
    let remove: () -> Void
    let note: () -> Void
    let copy: () -> Void
    let more: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let caption {
                Text(caption)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.lampSecondaryText)
                    .lineLimit(2)
                    .frame(maxWidth: 420, alignment: .leading)
            }
            row
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // Solid, edged and lifted off the page: it is a control over the
        // text, and must not read as part of it.
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.16))
        )
        // Its own shadow, in the clear margin of its window, so it is drawn
        // the same wherever the window lands.
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .padding(ReaderHighlightBar.margin)
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 4) {
            ReaderHighlightPalette(color: color, style: style, themes: themes, choose: choose, chooseStyle: chooseStyle)
            Divider().frame(height: 20).padding(.horizontal, 4)
            if canRemove {
                // Named: an eraser alone was read as one more style.
                Button("Remove", systemImage: "eraser", action: remove)
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
                    .buttonStyle(.borderless)
                    .font(.system(size: 13))
                    .help("Remove this highlight")
                    .padding(.trailing, 4)
            }
            barButton("Add Note", systemImage: "square.and.pencil", action: note)
            barButton("Copy as Citation", systemImage: "doc.on.doc", action: copy)
            barButton("More Highlight Options", systemImage: "ellipsis.circle", action: more)
        }
    }

    /// The clear margin round the bar that its shadow is drawn in.
    static let margin: CGFloat = 14

    private func barButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.system(size: 14))
            .frame(width: 26, height: 24)
            .help(title)
    }
}
