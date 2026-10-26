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
    /// What the writing editor's find bar searches this text view through.
    var finder: MarkdownTextFinder?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        // TextKit 1, as `scrollableTextView()` would set it up with TextKit 2:
        // the find bar tints matches with temporary attributes, which TextKit 1
        // redraws as they change. TextKit 2's rendering attributes stayed on
        // screen as they were before a match moved.
        let textView = NSTextView(usingTextLayoutManager: false)
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
        if textView.font?.pointSize != CGFloat(fontSize) {
            textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
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

        // A formatting command moves the selection out from under the text view;
        // adopt it, but never fight the user's own caret movements.
        let current = textView.selectedRange()
        if selection != current, context.coordinator.pendingSelection != selection {
            let limit = (textView.string as NSString).length
            guard selection.location >= 0, selection.location + selection.length <= limit else { return }
            context.coordinator.pendingSelection = selection
            textView.setSelectedRange(selection)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor
        var pendingSelection: NSRange?

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

/// Finds in the Markdown text view, for the writing editor's find bar.
///
/// Held by the editor window, which outlives any one text view, so a search
/// carries on when the Markdown surface comes back or shows another file.
@MainActor
final class MarkdownTextFinder: WritingFindTarget {
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
