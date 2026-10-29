import Foundation
import Testing
@testable import LampBibleMacSupport

/// The contract between the book converters and the two readers: an offset
/// counts Unicode scalars.
///
/// Both apps indexed by `Character` instead, which is the same number right up
/// until a block contains a scalar that joins the one before it — then every
/// offset after it in the block is early. Pointed Hebrew does it, and so does
/// any decomposed accent.
struct BookReaderTextOffsetsTests {
    /// "אֱלֹהִים" — each consonant is followed by its points, and a Character
    /// swallows them into the letter it belongs to.
    private let pointed = "בְּרֵאשִׁית bara"

    @Test func anOffsetCountsScalarsNotCharacters() {
        let value = AttributedString(pointed)

        #expect(
            pointed.unicodeScalars.count != pointed.count,
            "the fixture has to disagree, or it proves nothing"
        )

        let index = BookReaderTextOffsets.insertionIndex(
            at: pointed.unicodeScalars.count, in: value
        )
        #expect(index == value.endIndex, "the last scalar is the end of the text")

        // Counting Characters, this offset is past the end and the whole
        // Hebrew word would be skipped.
        let afterWord = try? #require(
            BookReaderTextOffsets.insertionIndex(
                at: "בְּרֵאשִׁית".unicodeScalars.count, in: value
            )
        )
        #expect(
            afterWord.map { String(value.characters[..<$0]) } == "בְּרֵאשִׁית",
            "a marker after the word belongs after all of it"
        )
    }

    @Test func acombiningAccentIsItsOwnStep() {
        let value = AttributedString("e\u{0301}tude")
        let index = BookReaderTextOffsets.insertionIndex(at: 2, in: value)

        #expect(
            index.map { String(value.characters[..<$0]) } == "e\u{0301}",
            "two scalars in, which is one Character"
        )
    }

    // MARK: - Overruns

    /// rome-3 carries footnote offsets a step past the end of their block. A
    /// marker is something the reader puts in, so it goes at the end rather
    /// than being dropped: the alternative is a footnote the text points at
    /// and nothing on screen to open.
    @Test func amarkerPastTheEndLandsAtTheEnd() {
        let value = AttributedString("Short line.")

        #expect(BookReaderTextOffsets.insertionIndex(at: 11, in: value) == value.endIndex)
        #expect(BookReaderTextOffsets.insertionIndex(at: 12, in: value) == value.endIndex)
        #expect(BookReaderTextOffsets.insertionIndex(at: 5_000, in: value) == value.endIndex)
    }

    @Test func anegativeOffsetIsNotAPlace() {
        let value = AttributedString("Short line.")
        #expect(BookReaderTextOffsets.insertionIndex(at: -1, in: value) == nil)
        #expect(BookReaderTextOffsets.range(from: -1, to: 4, in: value) == nil)
    }

    /// A span is not an insertion point: there is nothing to style past the
    /// end, so it is dropped rather than clamped onto an empty range.
    @Test func aspanThatBeginsPastTheEndIsDropped() {
        let value = AttributedString("Short line.")
        #expect(BookReaderTextOffsets.range(from: 11, to: 14, in: value) == nil)
        #expect(BookReaderTextOffsets.range(from: 40, to: 44, in: value) == nil)
    }

    @Test func aspanThatEndsPastTheEndStylesWhatIsThere() {
        let value = AttributedString("Short line.")
        let range = BookReaderTextOffsets.range(from: 6, to: 99, in: value)

        #expect(range.map { String(value.characters[$0]) } == "line.")
    }

    @Test func anEmptySpanIsNoSpan() {
        let value = AttributedString("Short line.")
        #expect(BookReaderTextOffsets.range(from: 3, to: 3, in: value) == nil)
        #expect(BookReaderTextOffsets.range(from: 4, to: 3, in: value) == nil)
    }

    @Test func aspanWithinTheTextIsTheTextItNames() {
        let value = AttributedString("Short line.")
        let range = BookReaderTextOffsets.range(from: 0, to: 5, in: value)

        #expect(range.map { String(value.characters[$0]) } == "Short")
    }
}
