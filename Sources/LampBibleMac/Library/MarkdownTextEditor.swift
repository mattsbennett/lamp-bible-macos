import AppKit
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI

/// A plain-text markdown editor backed by `NSTextView`.
///
/// SwiftUI's `TextEditor` exposes no selection, which is why the old formatting
/// buttons could only append to the end of the document. Everything here exists to
/// get the caret and the current selection back out.
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var fontSize: Double = 15
    var isEditable: Bool = true
    /// Bumped to put the caret in this text view and bring `selection` into
    /// sight. A token rather than a flag: revealing the same line twice is two
    /// requests, and a flag would only answer the first.
    var revealToken: Int = 0
    /// What the writing editor's find bar searches this text view through.
    var finder: MarkdownTextFinder?
    /// The longest line, in characters, before the text is held to a centred
    /// column. Nil runs it the full width, as a small field wants.
    var measure: Int?
    /// Set in the system's text face rather than monospaced, for a field of
    /// notes beside prose rather than a source to edit.
    var monospaced = true
    /// What the writing assistant changed that the writer has not yet read
    /// (`LampWritingReview.highlightedRanges`), drawn with a dotted rule
    /// beneath. A rule rather than a tint: the find bar clears every tint
    /// in the text each time it draws its matches.
    var reviewRanges: [NSRange] = []
    /// Offered on the context menu as "Mark as Reviewed", with the selected
    /// range, while there is anything marked. Nil offers nothing.
    var onMarkAsReviewed: ((NSRange) -> Void)?
    /// Offers to put the assistant's wording back over what `range` covers.
    /// The host shows what would come back before anything changes.
    var onRestoreWording: ((NSRange) -> Void)?
    /// Edits the host wants put in place as one change the writer's Undo
    /// takes back. Asked for by token, so a view made again does not make
    /// them a second time.
    var pendingEdits: WritingTextEdits?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        // TextKit 1, as `scrollableTextView()` would set it up with TextKit 2:
        // the find bar tints matches with temporary attributes, which TextKit 1
        // redraws as they change. TextKit 2's rendering attributes stayed on
        // screen as they were before a match moved.
        let textView = MeasuredTextView(usingTextLayoutManager: false)
        textView.measure = measureWidth
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView

        textView.delegate = context.coordinator
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainerInset = NSSize(width: 12, height: 14)
        textView.string = text

        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        textView.drawsBackground = false
        finder?.attach(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        finder?.attach(textView)

        // Each of these relays out the whole document, so only touch them when they
        // actually changed — reapplying them every update keeps the window in a
        // constraints pass it never finishes.
        let font: NSFont = monospaced
            ? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : .systemFont(ofSize: fontSize)
        if textView.font != font {
            textView.font = font
        }
        if let measured = textView as? MeasuredTextView, measured.measure != measureWidth {
            measured.measure = measureWidth
        }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }

        // Only push text down when it genuinely differs, or every keystroke would
        // reset the caret to the end of the document.
        if textView.string != text {
            textView.string = text
            let limit = (text as NSString).length
            let caret = min(context.coordinator.pendingSelection?.location ?? limit, limit)
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            context.coordinator.pendingSelection = textView.selectedRange()
            finder?.textDidChange()
        }

        // Drawn only when they changed: this runs on every host update.
        if context.coordinator.drawnReviewRanges != reviewRanges {
            context.coordinator.drawnReviewRanges = reviewRanges
            Self.drawReviewRanges(reviewRanges, in: textView)
        }

        // A formatting command moves the selection out from under the text view;
        // adopt it, but never fight the user's own caret movements.
        let current = textView.selectedRange()
        if selection != current, context.coordinator.pendingSelection != selection {
            let limit = (textView.string as NSString).length
            guard selection.location >= 0, selection.location + selection.length <= limit else { return }
            context.coordinator.pendingSelection = selection
            textView.setSelectedRange(selection)
            textView.scrollRangeToVisible(selection)
        }

        if let pendingEdits, context.coordinator.appliedEditsToken != pendingEdits.token {
            context.coordinator.appliedEditsToken = pendingEdits.token
            Self.apply(pendingEdits, in: textView)
        }

        // Asked for by a host that has just moved the selection somewhere the
        // writer hasn't looked — a footnote's line in the Footnotes field —
        // where leaving the caret behind in another view would mean the line
        // is selected and still not typeable.
        if context.coordinator.revealedToken != revealToken {
            context.coordinator.revealedToken = revealToken
            textView.scrollRangeToVisible(textView.selectedRange())
            if let window = textView.window, window.firstResponder !== textView {
                window.makeFirstResponder(textView)
            }
        }
    }

    /// The host's edits, made in the text view rather than by setting its
    /// string, so they are one entry in the writer's own Undo and the host
    /// hears about the new text the way it hears about typing.
    ///
    /// The edits come last first, so each range still means in the text what
    /// it meant when they were worked out.
    private static func apply(_ pending: WritingTextEdits, in textView: NSTextView) {
        guard textView.isEditable, let storage = textView.textStorage,
              textView.shouldChangeText(
                  inRanges: pending.edits.map { NSValue(range: $0.range) },
                  replacementStrings: pending.edits.map(\.replacement)
              )
        else { return }
        storage.beginEditing()
        for edit in pending.edits {
            storage.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        storage.endEditing()
        textView.undoManager?.setActionName(pending.actionName)
        textView.didChangeText()
    }

    /// The column's width in points: a monospaced character is 0.6 of the
    /// point size across.
    private var measureWidth: CGFloat? {
        measure.map { CGFloat($0) * CGFloat(fontSize) * (monospaced ? 0.6 : 0.5) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor
        var pendingSelection: NSRange?
        /// The last reveal this view has answered.
        var revealedToken = 0
        /// The review marks last drawn.
        var drawnReviewRanges: [NSRange] = []
        /// The host edits last put in place.
        var appliedEditsToken = 0

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard !parent.reviewRanges.isEmpty else { return menu }
            var inserted = 0
            if parent.onMarkAsReviewed != nil {
                let item = NSMenuItem(
                    title: "Mark as Reviewed", action: #selector(markAsReviewed(_:)), keyEquivalent: ""
                )
                item.target = self
                item.representedObject = view
                menu.insertItem(item, at: inserted)
                inserted += 1
            }
            if parent.onRestoreWording != nil {
                // Its ellipsis is the promise that nothing changes yet: what
                // would come back is shown first, which for a passage the
                // assistant only took words out of is the one way to see it.
                let item = NSMenuItem(
                    title: "Restore Original Wording…", action: #selector(restoreWording(_:)), keyEquivalent: ""
                )
                item.target = self
                item.representedObject = view
                menu.insertItem(item, at: inserted)
                inserted += 1
            }
            guard inserted > 0 else { return menu }
            menu.insertItem(.separator(), at: inserted)
            return menu
        }

        @objc private func markAsReviewed(_ item: NSMenuItem) {
            guard let view = item.representedObject as? NSTextView else { return }
            parent.onMarkAsReviewed?(view.selectedRange())
        }

        @objc private func restoreWording(_ item: NSMenuItem) {
            guard let view = item.representedObject as? NSTextView else { return }
            parent.onRestoreWording?(view.selectedRange())
        }

        init(_ parent: MarkdownTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let updated = textView.string
            let range = textView.selectedRange()
            pendingSelection = range
            parent.finder?.textDidChange()
            Task { @MainActor in
                parent.text = updated
                parent.selection = range
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            pendingSelection = range
            Task { @MainActor in
                parent.selection = range
            }
        }
    }
}

/// One text put in the place of another, in the Markdown text view.
struct WritingTextEdit: Equatable {
    let range: NSRange
    let replacement: String
}

/// Edits a host asks the Markdown text view to make, as one undoable change.
struct WritingTextEdits: Equatable {
    /// Raised for each new set, so the view makes each once.
    let token: Int
    /// What the writer sees in Edit ▸ Undo.
    let actionName: String
    /// Last first.
    let edits: [WritingTextEdit]
}

/// Finds in the Markdown text view, for the writing editor's find bar.
///
/// Held by the editor window, which outlives any one text view, so a search
/// carries on when the Markdown surface comes back or shows another file.
@MainActor
final class MarkdownTextFinder: WritingReplaceTarget {
    var onFindStatusChanged: ((WritingFindStatus) -> Void)?
    private weak var textView: NSTextView?
    private var query = ""
    private var options = WritingFindOptions()
    private var matches: [NSRange] = []
    private var currentIndex: Int?
    /// Where the next match is looked for once a replacement's edit lands:
    /// after the replacement, so a replacement that contains the query is
    /// never found again.
    private var anchorAfterEdit: Int?

    private var status: WritingFindStatus {
        WritingFindStatus(count: matches.count, current: currentIndex.map { $0 + 1 } ?? 0)
    }

    /// Called by the text view as it is made and updated.
    func attach(_ textView: NSTextView) {
        guard textView !== self.textView else { return }
        self.textView = textView
        guard !query.isEmpty else { return }
        refresh(from: textView.selectedRange().location, revealing: true)
        onFindStatusChanged?(status)
    }

    /// Called after the text changes, whether typed, replaced or set.
    func textDidChange() {
        guard !query.isEmpty, let textView else { return }
        let anchor = anchorAfterEdit
            ?? currentIndex.map { matches[$0].location }
            ?? textView.selectedRange().location
        anchorAfterEdit = nil
        refresh(from: anchor, revealing: false)
        onFindStatusChanged?(status)
    }

    func setSearch(
        _ query: String,
        options: WritingFindOptions,
        completion: @escaping (WritingFindStatus) -> Void
    ) {
        self.query = query
        self.options = options
        guard let textView else {
            completion(.noMatches)
            return
        }
        refresh(from: textView.selectedRange().location, revealing: true)
        completion(status)
    }

    func findNext(completion: @escaping (WritingFindStatus) -> Void) {
        step(by: 1)
        completion(status)
    }

    func findPrevious(completion: @escaping (WritingFindStatus) -> Void) {
        step(by: -1)
        completion(status)
    }

    func replaceCurrent(with replacement: String, completion: @escaping (WritingFindStatus) -> Void) {
        guard let textView, textView.isEditable, let currentIndex,
              let storage = textView.textStorage else {
            completion(status)
            return
        }
        let range = matches[currentIndex]
        guard textView.shouldChangeText(in: range, replacementString: replacement) else {
            completion(status)
            return
        }
        storage.replaceCharacters(in: range, with: replacement)
        textView.undoManager?.setActionName("Replace")
        finishEdit(in: textView, nextSearchFrom: range.location + (replacement as NSString).length)
        reveal(indicating: true)
        completion(status)
    }

    func replaceAll(with replacement: String, completion: @escaping (Int) -> Void) {
        let ranges = matches
        guard let textView, textView.isEditable, !ranges.isEmpty,
              let storage = textView.textStorage,
              textView.shouldChangeText(
                  inRanges: ranges.map { NSValue(range: $0) },
                  replacementStrings: ranges.map { _ in replacement }
              )
        else {
            completion(0)
            return
        }
        storage.beginEditing()
        for range in ranges.reversed() {
            storage.replaceCharacters(in: range, with: replacement)
        }
        storage.endEditing()
        textView.undoManager?.setActionName("Replace All")
        finishEdit(in: textView, nextSearchFrom: ranges[0].location)
        completion(ranges.count)
    }

    /// Announces a replacement, so the host takes the new text, and finds the
    /// matches in it. The host's delegate usually has the finder find them as
    /// the change is announced; if nothing did, the finder does it here, since
    /// matches left over from before the edit point at the wrong text.
    private func finishEdit(in textView: NSTextView, nextSearchFrom location: Int) {
        anchorAfterEdit = location
        textView.didChangeText()
        if anchorAfterEdit != nil { textDidChange() }
    }

    func endSearch(selectingCurrent: Bool) {
        if selectingCurrent, let textView, let currentIndex {
            textView.setSelectedRange(matches[currentIndex])
            textView.scrollRangeToVisible(matches[currentIndex])
            textView.window?.makeFirstResponder(textView)
        }
        query = ""
        matches = []
        currentIndex = nil
        anchorAfterEdit = nil
        drawHighlights()
    }

    private func refresh(from location: Int, revealing: Bool) {
        matches = textView.map { WritingFind.matches(of: query, in: $0.string, options: options) } ?? []
        currentIndex = WritingFind.index(startingAt: location, in: matches)
        drawHighlights()
        if revealing { reveal(indicating: false) }
    }

    private func step(by offset: Int) {
        guard !matches.isEmpty else { return }
        currentIndex = currentIndex.map { ($0 + offset + matches.count) % matches.count }
            ?? (offset > 0 ? 0 : matches.count - 1)
        drawHighlights()
        reveal(indicating: true)
    }

    private func reveal(indicating: Bool) {
        guard let textView, let currentIndex else { return }
        textView.scrollRangeToVisible(matches[currentIndex])
        if indicating { textView.showFindIndicator(for: matches[currentIndex]) }
    }

    /// Every match tinted, and the current one in the find colour, drawn as
    /// temporary attributes so the text itself is never touched.
    private func drawHighlights() {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let whole = NSRange(location: 0, length: (textView.string as NSString).length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        let others = NSColor.findHighlightColor.withAlphaComponent(0.35)
        for (index, match) in matches.enumerated() {
            if index == currentIndex {
                layoutManager.addTemporaryAttributes([
                    .backgroundColor: NSColor.findHighlightColor,
                    .foregroundColor: NSColor.black,
                ], forCharacterRange: match)
            } else {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: others, forCharacterRange: match)
            }
        }
    }
}

extension MarkdownTextEditor {
    static func drawReviewRanges(_ ranges: [NSRange], in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        let whole = NSRange(location: 0, length: length)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: whole)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: whole)
        let rule: [NSAttributedString.Key: Any] = [
            .underlineStyle: NSUnderlineStyle([.single, .patternDot]).rawValue,
            .underlineColor: NSColor.systemOrange,
        ]
        for range in ranges {
            // A place words were taken out is ruled under the character
            // after it, the nearest there is to rule.
            let ruled = range.length > 0 ? range : NSRange(location: range.location, length: 1)
            guard NSMaxRange(ruled) <= length else { continue }
            layoutManager.addTemporaryAttributes(rule, forCharacterRange: ruled)
        }
    }
}

/// The formatting actions the devotional editor offers, in toolbar order.
enum MarkdownCommand: String, CaseIterable, Identifiable {
    case bold
    case italic
    case heading
    case quote
    case bulletList
    case numberedList

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .heading: "Heading"
        case .quote: "Quote"
        case .bulletList: "Bulleted List"
        case .numberedList: "Numbered List"
        }
    }

    var systemImage: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .heading: "textformat.size"
        case .quote: "text.quote"
        case .bulletList: "list.bullet"
        case .numberedList: "list.number"
        }
    }

    var keyboardShortcut: KeyEquivalent? {
        switch self {
        case .bold: "b"
        case .italic: "i"
        default: nil
        }
    }

    func apply(to text: String, selection: NSRange) -> MarkdownEditResult {
        switch self {
        case .bold: MarkdownEditor.toggleWrap("**", in: text, selection: selection)
        case .italic: MarkdownEditor.toggleWrap("_", in: text, selection: selection)
        case .heading: MarkdownEditor.togglePrefix("## ", in: text, selection: selection)
        case .quote: MarkdownEditor.togglePrefix("> ", in: text, selection: selection)
        case .bulletList: MarkdownEditor.togglePrefix("- ", in: text, selection: selection)
        case .numberedList: MarkdownEditor.togglePrefix("1. ", in: text, selection: selection)
        }
    }
}

/// A text view that keeps its lines to a measure by widening its side
/// insets as it grows, so the source of a writing is set in a column as the
/// visual editor sets it, rather than in lines the width of the window.
final class MeasuredTextView: LampTextView {
    /// The widest the text runs, in points; nil for the full width.
    var measure: CGFloat? {
        didSet { if measure != oldValue { updateInset(for: frame.width) } }
    }

    private static let minimumInset: CGFloat = 12

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInset(for: newSize.width)
    }

    private func updateInset(for width: CGFloat) {
        let side: CGFloat
        if let measure, width > measure + 2 * Self.minimumInset {
            side = ((width - measure) / 2).rounded()
        } else {
            side = Self.minimumInset
        }
        guard textContainerInset.width != side else { return }
        textContainerInset = NSSize(width: side, height: textContainerInset.height)
    }
}
