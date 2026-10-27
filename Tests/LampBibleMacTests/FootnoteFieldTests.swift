import Foundation
import Testing
@testable import LampBibleMacSupport

/// Clicking a marker whose note lives in the Footnotes field has to put the
/// writer on that line, so the Mac needs to know where in the field it is.
struct FootnoteFieldTests {
    private let field = """
    [^lewis]: Lewis, *The Weight of Glory*, p. 26.
    [^pinker-48]: Pinker, p. 48,
        and the page after it.
    [^a,b]: Both of them.
    """

    @Test func findsEveryDefinitionInTheOrderWritten() {
        #expect(LampFootnoteField.locations(in: field).map(\.label)
            == ["lewis", "pinker-48", "a,b"])
    }

    @Test func pointsAtWhatTheNoteSaysRatherThanItsLabel() throws {
        let found = try #require(LampFootnoteField.location(of: "lewis", in: field))
        let text = field as NSString
        #expect(text.substring(with: found.content) == "Lewis, *The Weight of Glory*, p. 26.")
        #expect(text.substring(with: found.definition)
            == "[^lewis]: Lewis, *The Weight of Glory*, p. 26.")
    }

    /// A note running onto an indented line is one note, so revealing it has
    /// to reveal all of it.
    @Test func keepsTheLinesOfANoteThatRunsOn() throws {
        let found = try #require(LampFootnoteField.location(of: "pinker-48", in: field))
        #expect((field as NSString).substring(with: found.content)
            == "Pinker, p. 48,\n    and the page after it.")
    }

    @Test func readsALabelWithPunctuationInIt() throws {
        let found = try #require(LampFootnoteField.location(of: "a,b", in: field))
        #expect((field as NSString).substring(with: found.content) == "Both of them.")
    }

    /// The ordinary case for a writing that keeps its notes in the prose: the
    /// field has nothing for that marker, and the Mac must not act.
    @Test func findsNothingForAMarkerTheFieldDoesNotDefine() {
        #expect(LampFootnoteField.location(of: "missing", in: field) == nil)
        #expect(LampFootnoteField.locations(in: "").isEmpty)
        #expect(LampFootnoteField.locations(in: "Prose with no definitions at all.").isEmpty)
    }

    /// Anything written above the definitions shifts them along, so the
    /// offsets have to come from the text rather than be counted from zero.
    @Test func locatesADefinitionBelowAPreamble() throws {
        let withPreamble = "Sources consulted.\n\n" + field
        let found = try #require(LampFootnoteField.location(of: "lewis", in: withPreamble))
        #expect((withPreamble as NSString).substring(with: found.content)
            == "Lewis, *The Weight of Glory*, p. 26.")
    }

    @Test func doesNotTakeAnIndentedCodeBlockForADefinition() {
        #expect(LampFootnoteField.locations(in: "    [^code]: four spaces in.").isEmpty)
    }

    /// An empty note is still a note: the caret goes where its text would be.
    @Test func pointsAtTheEndOfAnEmptyNote() throws {
        let found = try #require(LampFootnoteField.location(of: "blank", in: "[^blank]:"))
        #expect(found.content.length == 0)
        #expect(found.content.location == 9)
    }
}

/// A footnote being added needs a label nothing else has taken, wherever the
/// writing keeps its notes.
struct FootnoteLabelTests {
    @Test func numbersOnFromTheWritingsOwnNumbers() {
        #expect(LampFootnoteLabels.next(
            content: "One[^1], two[^2], three[^3].", field: ""
        ) == "4")
    }

    @Test func startsAtOneWhenTheLabelsAreWords() {
        #expect(LampFootnoteLabels.next(
            content: "A claim[^lewis].", field: "[^lewis]: Lewis, p. 26."
        ) == "1")
    }

    /// The gap matters: a writing that has lost its second note should reuse
    /// the number rather than leave it empty for ever.
    @Test func fillsAGapRatherThanCountingPastIt() {
        #expect(LampFootnoteLabels.next(content: "One[^1], three[^3].", field: "") == "2")
    }

    /// The field's labels count too, or a new note would collide with one the
    /// editor cannot see.
    @Test func doesNotTakeALabelTheFieldIsUsing() {
        #expect(LampFootnoteLabels.next(content: "One[^1].", field: "[^2]: Kept aside.") == "3")
    }

    @Test func startsAtOneForAWritingWithNoFootnotes() {
        #expect(LampFootnoteLabels.next(content: "Plain prose.", field: "") == "1")
    }

    @Test func readsLabelsFromMarkersAndDefinitionsAlike() {
        let used = LampFootnoteLabels.used(
            content: "Cited[^a] and[^b].\n\n[^a]: Here.",
            field: "[^c]: And there."
        )
        #expect(used == ["a", "b", "c"])
    }
}

/// A translation marks its notes at character offsets in a verse, and the
/// reader draws that verse in runs. Putting each marker in the right run, at
/// the right place in it, is counting that is easy to get wrong by one.
struct ReaderFootnoteMarkTests {
    private let verse = "In the beginning God created the heavens and the earth."

    @Test func marksTheWholeVerseFurthestFirst() {
        let found = LampReaderFootnoteMarks.insertions(
            in: verse, from: 0, to: verse.count, markedAt: [3, 21]
        )
        #expect(found.map(\.index) == [1, 0], "the later marker is inserted first")
        #expect(found.map(\.location) == [21, 3])
    }

    /// Inserting from the back is the whole point: done in the other order,
    /// the second marker would land a character late.
    @Test func everyLocationStillHoldsAfterTheOneBeforeIt() {
        let found = LampReaderFootnoteMarks.insertions(
            in: verse, from: 0, to: verse.count, markedAt: [3, 21]
        )
        let result = NSMutableAttributedString(string: verse)
        for insertion in found {
            result.insert(NSAttributedString(string: "·"), at: insertion.location)
        }
        // Offset 3 is the "t" of "the" and 21 the "c" of "created": a marker
        // goes before the character its note is about.
        #expect(result.string == "In ·the beginning God ·created the heavens and the earth.")
    }

    /// A verse drawn as poetry is several runs of one string, and a marker
    /// belongs to exactly one of them.
    @Test func keepsEachMarkerToTheRunItFallsIn() {
        let first = LampReaderFootnoteMarks.insertions(
            in: verse, from: 0, to: 18, markedAt: [3, 21]
        )
        let second = LampReaderFootnoteMarks.insertions(
            in: verse, from: 18, to: verse.count, markedAt: [3, 21]
        )
        #expect(first.map(\.index) == [0])
        #expect(second.map(\.index) == [1])
        #expect(second.first?.location == 3, "counted from the start of its own run")
    }

    /// Offsets count characters and a text view counts UTF-16 units, which part
    /// company at the first word that isn't plain ASCII.
    @Test func countsCharactersWhereTheTextViewCountsUnits() {
        let accented = "Sí, Yahweh 𝕲 said"        // 𝕲 is two UTF-16 units
        let afterTheSymbol = LampReaderFootnoteMarks.insertions(
            in: accented, from: 0, to: accented.count, markedAt: [13]
        )
        #expect(afterTheSymbol.first?.location == 14, "the symbol counts twice in a text view")

        let result = NSMutableAttributedString(string: accented)
        for insertion in afterTheSymbol {
            result.insert(NSAttributedString(string: "a"), at: insertion.location)
        }
        #expect(result.string == "Sí, Yahweh 𝕲 asaid")
    }

    @Test func marksTheVeryStartAndTheVeryEnd() {
        let found = LampReaderFootnoteMarks.insertions(
            in: verse, from: 0, to: verse.count, markedAt: [0, verse.count - 1]
        )
        #expect(found.map(\.location) == [verse.count - 1, 0])
    }

    @Test func leavesOutWhatTheRunDoesNotHold() {
        #expect(LampReaderFootnoteMarks.insertions(
            in: verse, from: 0, to: 5, markedAt: [40]
        ).isEmpty)
        #expect(LampReaderFootnoteMarks.insertions(
            in: verse, from: 0, to: verse.count, markedAt: [-1, 9_999]
        ).isEmpty)
        #expect(LampReaderFootnoteMarks.insertions(
            in: "", from: 0, to: 0, markedAt: [0]
        ).isEmpty)
    }
}
