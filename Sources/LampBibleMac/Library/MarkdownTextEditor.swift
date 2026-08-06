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

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

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
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self

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
