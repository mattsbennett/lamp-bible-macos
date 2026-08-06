import Foundation

/// The result of a formatting command: the new document and where the caret or
/// selection should end up in it.
public struct MarkdownEditResult: Equatable, Sendable {
    public let text: String
    public let selection: NSRange

    public init(text: String, selection: NSRange) {
        self.text = text
        self.selection = selection
    }
}

/// Selection-aware markdown editing.
///
/// Kept free of AppKit so the behaviour that is easy to get subtly wrong — where
/// the caret lands, whether a second press undoes the first — can be tested without
/// standing up a text view.
public enum MarkdownEditor {
    /// Wrap the selection in `marker`, or unwrap it when it is already wrapped.
    ///
    /// With nothing selected this inserts an empty pair and puts the caret between
    /// the markers, so typing continues inside the emphasis rather than after it.
    public static func toggleWrap(
        _ marker: String,
        in text: String,
        selection: NSRange
    ) -> MarkdownEditResult {
        guard !marker.isEmpty, let range = Range(selection, in: text) else {
            return MarkdownEditResult(text: text, selection: selection)
        }
        let selected = String(text[range])

        // Markers inside the selection: "**word**" selected.
        if selected.count >= marker.count * 2,
           selected.hasPrefix(marker),
           selected.hasSuffix(marker) {
            let stripped = String(selected.dropFirst(marker.count).dropLast(marker.count))
            return replacing(range, in: text, with: stripped, selectingReplacement: true)
        }

        // Markers around the selection: "word" selected inside "**word**".
        let before = text[text.startIndex..<range.lowerBound]
        let after = text[range.upperBound...]
        if before.hasSuffix(marker), after.hasPrefix(marker) {
            let outerStart = text.index(range.lowerBound, offsetBy: -marker.count)
            let outerEnd = text.index(range.upperBound, offsetBy: marker.count)
            return replacing(outerStart..<outerEnd, in: text, with: selected, selectingReplacement: true)
        }

        let wrapped = marker + selected + marker
        if selected.isEmpty {
            var updated = text
            updated.replaceSubrange(range, with: wrapped)
            let caret = selection.location + (marker as NSString).length
            return MarkdownEditResult(text: updated, selection: NSRange(location: caret, length: 0))
        }
        return replacing(range, in: text, with: wrapped, selectingReplacement: true)
    }

    /// Add `prefix` to every line the selection touches, or strip it when every one
    /// of those lines already has it.
    public static func togglePrefix(
        _ prefix: String,
        in text: String,
        selection: NSRange
    ) -> MarkdownEditResult {
        guard !prefix.isEmpty, let range = Range(selection, in: text) else {
            return MarkdownEditResult(text: text, selection: selection)
        }
        let lineRange = text.lineRange(for: range)
        let block = String(text[lineRange])
        // A trailing newline belongs to the next line, not this block.
        let hasTrailingNewline = block.hasSuffix("\n")
        let body = hasTrailingNewline ? String(block.dropLast()) : block
        let lines = body.components(separatedBy: "\n")

        let meaningfulLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allPrefixed = !meaningfulLines.isEmpty && meaningfulLines.allSatisfy {
            $0.hasPrefix(prefix)
        }

        let updatedLines = lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            if allPrefixed { return String(line.dropFirst(prefix.count)) }
            return prefix + line
        }
        let replacement = updatedLines.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        return replacing(lineRange, in: text, with: replacement, selectingReplacement: true)
    }

    /// Drop `snippet` in at the caret, replacing anything selected.
    ///
    /// Media links and similar go in on their own line: a devotional's image sitting
    /// mid-sentence renders as an inline run rather than a block.
    public static func insert(
        _ snippet: String,
        in text: String,
        selection: NSRange,
        onOwnLine: Bool = false
    ) -> MarkdownEditResult {
        guard let range = Range(selection, in: text) else {
            return MarkdownEditResult(text: text, selection: selection)
        }
        var replacement = snippet
        if onOwnLine {
            let before = text[text.startIndex..<range.lowerBound]
            if !before.isEmpty, !before.hasSuffix("\n") { replacement = "\n" + replacement }
            let after = text[range.upperBound...]
            if !after.hasPrefix("\n") { replacement += "\n" }
        }
        var updated = text
        updated.replaceSubrange(range, with: replacement)
        let caret = selection.location + (replacement as NSString).length
        return MarkdownEditResult(text: updated, selection: NSRange(location: caret, length: 0))
    }

    private static func replacing(
        _ range: Range<String.Index>,
        in text: String,
        with replacement: String,
        selectingReplacement: Bool
    ) -> MarkdownEditResult {
        var updated = text
        updated.replaceSubrange(range, with: replacement)
        let location = (String(text[text.startIndex..<range.lowerBound]) as NSString).length
        let length = selectingReplacement ? (replacement as NSString).length : 0
        return MarkdownEditResult(
            text: updated,
            selection: NSRange(location: location, length: length)
        )
    }
}
