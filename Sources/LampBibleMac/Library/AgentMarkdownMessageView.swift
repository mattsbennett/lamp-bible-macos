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
///
/// The prose between code blocks is one text view, so a selection can run from
/// one paragraph, list or table into the next. Code keeps its own panel.
struct AgentMarkdownMessageView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(AgentProseText.segments(of: markdown).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let blocks):
                    SelectableProseView(blocks: blocks)
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Prose shown in an AppKit text view, which — unlike separate SwiftUI texts —
/// selects across everything it holds.
private struct SelectableProseView: NSViewRepresentable {
    let blocks: [DevotionalProseBlock]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        // TextKit 1: quotes and tables are text blocks, which TextKit 2 doesn't draw.
        let textView = ProseTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.delegate = context.coordinator
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.openURL = context.environment.openURL
        guard context.coordinator.blocks != blocks else { return }
        context.coordinator.blocks = blocks
        textView.textStorage?.setAttributedString(AgentProseText.attributedString(for: blocks))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView textView: NSTextView, context: Context) -> CGSize? {
        guard let container = textView.textContainer,
              let layoutManager = textView.layoutManager
        else { return nil }
        // Without a width on offer, the bubble's own limit, less its padding.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 596
        // Measuring lays the text out at the width on offer; afterwards it goes
        // back to the view's own width, which may not change to match.
        defer {
            if textView.frame.width > 0 {
                container.containerSize = NSSize(width: textView.frame.width, height: .greatestFiniteMagnitude)
            }
        }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return CGSize(
            width: proposal.width == nil ? ceil(used.width) : width,
            height: ceil(used.height)
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var blocks: [DevotionalProseBlock]?
        var openURL: OpenURLAction?

        /// Links open as they did when replies were SwiftUI text, through the
        /// app's handler, so Lamp's own links stay in Lamp.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url, let openURL else { return false }
            openURL(url)
            return true
        }
    }
}

/// Copies a table as rows of tab-separated cells, and without the lines that
/// only space blocks apart. Rich text keeps the table as a table.
private final class ProseTextView: NSTextView {
    /// Copying asks for plain text by its legacy name.
    private static let plainTextTypes: Set<NSPasteboard.PasteboardType> = [
        .string, NSPasteboard.PasteboardType("NSStringPboardType"),
    ]

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard Self.plainTextTypes.contains(type), let textStorage else {
            return super.writeSelection(to: pboard, type: type)
        }
        let text = selectedRanges
            .map { AgentProseText.plainText(of: textStorage, in: $0.rangeValue) }
            .joined(separator: "\n")
        return pboard.setString(text, forType: type)
    }
}
