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
