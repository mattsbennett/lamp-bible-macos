import Foundation

/// Reading a writing's footnotes: where one definition sits in the Footnotes
/// field, and which label a new footnote can take.
///
/// A writing can keep its notes in either of two places: as `[^label]:` lines
/// beneath the prose, where the editor shows them itself, or in the Footnotes
/// field beside it, where the editor never sees them. Clicking a marker whose
/// note is in the field is reported out to the Mac, which has to show the
/// writer the line it refers to — and for that it needs to know where in the
/// field that line is.
///
/// The field is Markdown as the writer typed it, so this reads it the way
/// `LampDevotionalFootnotes` does: a definition opens with up to three spaces,
/// `[^`, a label with no space or closing bracket, `]:`, and runs on through
/// any following line that does not open a definition of its own.
public enum LampFootnoteField {
    /// Where one definition sits in the field's text.
    public struct Location: Equatable, Sendable {
        /// The label as the writing spells it, which is what a marker carries.
        public let label: String
        /// The whole definition, from `[^` to the end of its last line.
        public let definition: NSRange
        /// Just what the note says, after `]:` and the space that follows it.
        /// Where the caret goes: the phone puts it at the start of the note
        /// rather than selecting it, and a selection here would be wiped by
        /// the first keystroke.
        public let content: NSRange

        public init(label: String, definition: NSRange, content: NSRange) {
            self.label = label
            self.definition = definition
            self.content = content
        }
    }

    private static let opening = try! NSRegularExpression(
        pattern: #"^[ ]{0,3}\[\^([^\]\s]+)\]:[ \t]*"#,
        options: [.anchorsMatchLines]
    )

    /// Every definition in `field`, in the order they are written.
    public static func locations(in field: String) -> [Location] {
        let text = field as NSString
        let openings = opening.matches(
            in: field, range: NSRange(location: 0, length: text.length)
        )
        guard !openings.isEmpty else { return [] }

        return openings.enumerated().compactMap { index, match in
            guard let label = Range(match.range(at: 1), in: field)
                .map({ String(field[$0]) })
            else { return nil }
            // A definition runs to the line before the next one opens, or to
            // the end of the field. Trailing newlines are not part of it.
            let end = index + 1 < openings.count
                ? openings[index + 1].range.location
                : text.length
            var definitionEnd = end
            while definitionEnd > match.range.location,
                  let last = text.substring(
                      with: NSRange(location: definitionEnd - 1, length: 1)
                  ).first,
                  last == "\n" || last == "\r" {
                definitionEnd -= 1
            }
            let start = match.range.location
            let contentStart = match.range.location + match.range.length
            return Location(
                label: label,
                definition: NSRange(
                    location: start, length: max(0, definitionEnd - start)
                ),
                content: NSRange(
                    location: min(contentStart, definitionEnd),
                    length: max(0, definitionEnd - contentStart)
                )
            )
        }
    }

    /// Where the note labelled `label` sits, or nil when the field has no
    /// definition for it — which is the ordinary case for a marker whose note
    /// was written in the prose instead.
    public static func location(of label: String, in field: String) -> Location? {
        locations(in: field).first { $0.label == label }
    }
}


/// Choosing a label for a footnote being added.
///
/// A writing's labels can be any run of characters, and the number a reader
/// sees comes from reading order rather than from the label — but a new one
/// still has to be a label nothing else is using, in the prose or in the
/// field. Numbers, as both apps have always written them.
public enum LampFootnoteLabels {
    private static let marker = try! NSRegularExpression(pattern: #"\[\^([^\]\s]+)\]"#)

    /// Every label the writing uses, from its markers and from both places a
    /// definition can be written.
    public static func used(content: String, field: String) -> Set<String> {
        var labels = Set(LampFootnoteField.locations(in: field).map(\.label))
        for text in [content, field] where text.contains("[^") {
            let range = NSRange(location: 0, length: (text as NSString).length)
            for match in marker.matches(in: text, range: range) {
                guard let found = Range(match.range(at: 1), in: text) else { continue }
                labels.insert(String(text[found]))
            }
        }
        return labels
    }

    /// The lowest number no label is using. A writing numbering its notes 1, 2,
    /// 3 gets 4; one whose labels are words gets 1; one that has taken "3" for
    /// something of its own is not given it twice.
    public static func next(content: String, field: String) -> String {
        let taken = used(content: content, field: field)
        var candidate = 1
        while taken.contains(String(candidate)) { candidate += 1 }
        return String(candidate)
    }
}
