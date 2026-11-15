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
        return textView
    }

    func updateNSView(_ textView: ReaderTextView, context: Context) {
        context.coordinator.openLink = openLink
        textView.openNote = openNote
        textView.selectionStore = context.environment.readerTextSelection
        textView.textLeading = textLeading
        if textView.attributedString() != attributedText {
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(attributedText)
            if selection.location != NSNotFound,
               NSMaxRange(selection) <= attributedText.length {
                textView.setSelectedRange(selection)
            }
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
