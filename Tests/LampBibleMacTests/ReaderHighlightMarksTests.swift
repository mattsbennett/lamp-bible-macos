import AppKit
import LampBibleMacSupport
import Testing
@testable import LampBibleMac

/// Selections and clicks in the reader's drawn text, traced to the verse and
/// the `Character` a highlight counts from: verse numbers and note letters
/// are drawn among the words and are not counted, and a companion
/// translation's words are never highlighted in the one being read.
struct ReaderHighlightMarksTests {
    private static let john16 = 43_003_016
    private static let john17 = 43_003_017
    /// With a decomposed é: two scalars, one Character.
    private static let loved = "lov\u{65}\u{301}d"

    /// "16 For God sᵃo loved 17 For God sent" with a companion's line after,
    /// marked as the reader marks it. The second verse is a poetry line that
    /// starts four characters into its verse.
    private func chapter() -> (NSAttributedString, String) {
        let text = NSMutableAttributedString()
        func run(_ string: String, verse: Int?, offset: Int? = nil, apparatus: Bool = false, companion: Bool = false) {
            var attributes: [NSAttributedString.Key: Any] = [:]
            if let verse { attributes[ReaderTextMarks.verse] = NSNumber(value: verse) }
            if apparatus {
                attributes[ReaderTextMarks.apparatus] = true
                attributes[.link] = URL(string: "lampbible://verse")!
            }
            if companion { attributes[ReaderTextMarks.translation] = "KJV" }
            text.append(NSAttributedString(string: string, attributes: attributes))
            if let offset {
                text.addAttribute(
                    ReaderHighlightMarks.offset, value: NSNumber(value: offset),
                    range: NSRange(location: text.length - string.utf16.count, length: string.utf16.count)
                )
            }
        }
        run("16", verse: Self.john16, apparatus: true)
        run(" ", verse: Self.john16)
        // One body, a note letter inside it, as `verseBodyText` draws one.
        let bodyStart = text.length
        run("For God s", verse: Self.john16)
        run("ᵃ", verse: Self.john16, apparatus: true)
        run("o " + Self.loved, verse: Self.john16)
        text.addAttribute(
            ReaderHighlightMarks.offset, value: NSNumber(value: 0),
            range: NSRange(location: bodyStart, length: text.length - bodyStart)
        )
        run(" ", verse: nil)
        run("17", verse: Self.john17, apparatus: true)
        run(" ", verse: Self.john17)
        run("God sent", verse: Self.john17, offset: 4)
        run("\nFor God so loved", verse: Self.john16, offset: 0, companion: true)
        return (text, text.string)
    }

    private func range(of needle: String, in string: String) -> NSRange {
        (string as NSString).range(of: needle)
    }

    @Test func aSelectionIsCountedInTheVersesOwnCharacters() {
        let (text, string) = chapter()
        // "God so" across the note letter: seven characters of the verse, not eight.
        let spans = ReaderHighlightMarks.spans(in: text, range: range(of: "God sᵃo", in: string))
        #expect(spans == [.init(reference: Self.john16, start: 4, end: 10)])
        // A decomposed é is one Character, as a highlight counts it.
        let loved = ReaderHighlightMarks.spans(in: text, range: range(of: Self.loved, in: string))
        #expect(loved == [.init(reference: Self.john16, start: 11, end: 16)])
    }

    @Test func aSelectionAcrossVersesIsASpanForEachAndLeavesTheNumbersOut() {
        let (text, string) = chapter()
        let start = range(of: Self.loved, in: string).location
        let end = NSMaxRange(range(of: "God sent", in: string))
        let spans = ReaderHighlightMarks.spans(in: text, range: NSRange(location: start, length: end - start))
        #expect(spans == [
            .init(reference: Self.john16, start: 11, end: 16),
            // A poetry line starts part way into its verse.
            .init(reference: Self.john17, start: 4, end: 12),
        ])
        // Only a verse number, or only the companion, is nothing to highlight.
        #expect(ReaderHighlightMarks.spans(in: text, range: range(of: "17", in: string)).isEmpty)
        #expect(ReaderHighlightMarks.spans(in: text, range: range(of: "\nFor God so loved", in: string)).isEmpty)
    }

    @Test func aClickIsTracedToItsVerseAndCharacter() {
        let (text, string) = chapter()
        let o = range(of: "o lov", in: string).location
        #expect(ReaderHighlightMarks.position(in: text, at: o).map { [$0.reference, $0.offset] } == [Self.john16, 9])
        #expect(ReaderHighlightMarks.position(in: text, at: range(of: "16", in: string).location) == nil)
        #expect(ReaderHighlightMarks.position(in: text, at: range(of: "\nFor", in: string).location + 1) == nil)
        let sent = range(of: "sent", in: string).location
        #expect(ReaderHighlightMarks.position(in: text, at: sent).map { [$0.reference, $0.offset] } == [Self.john17, 8])
    }

    @Test func aHighlightIsFoundAgainWhereItIsDrawn() {
        let (text, string) = chapter()
        let drawn = ReaderHighlightMarks.drawnRange(of: .init(reference: Self.john16, start: 11, end: 16), in: text)
        #expect(drawn == range(of: Self.loved, in: string))
        let across = ReaderHighlightMarks.drawnRange(of: .init(reference: Self.john16, start: 4, end: 10), in: text)
        #expect(across == range(of: "God sᵃo", in: string))
        // Drawn in the translation read, never on the companion's line.
        let whole = ReaderHighlightMarks.drawnRange(of: .init(reference: Self.john16, start: 0, end: 3), in: text)
        #expect(whole == range(of: "For", in: string))
    }
}
