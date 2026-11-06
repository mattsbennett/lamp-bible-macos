import Foundation
import SwiftUI
import Testing

@testable import LampBibleMacSupport

private func runs(_ texts: String...) -> [WritingPreviewRun] {
    texts.enumerated().map { WritingPreviewRun(id: $0.offset, text: $0.element) }
}

@Suite("Finding text in a writing preview")
struct WritingPreviewFindSupportTests {
    @Test("A match carries the run it is in, so it can be drawn there")
    func matchesCarryTheirRun() {
        let found = WritingPreviewFind.matches(
            of: "grace",
            in: runs("Grace abounds", "No mention here", "grace again")
        )
        #expect(found.map(\.runID) == [0, 2])
        #expect(found.first?.range == NSRange(location: 0, length: 5))
    }

    @Test("Case is ignored unless the reader asks for it")
    func caseIsIgnoredByDefault() {
        let text = runs("Grace and grace")
        #expect(WritingPreviewFind.matches(of: "grace", in: text).count == 2)
        #expect(
            WritingPreviewFind.matches(
                of: "grace", in: text, options: .init(matchesCase: true)
            ).count == 1
        )
    }

    @Test("Whole words is the preview's too, not only the editor's")
    func wholeWordsApplies() {
        let text = runs("the law and the lawless")
        #expect(WritingPreviewFind.matches(of: "law", in: text).count == 2)
        #expect(
            WritingPreviewFind.matches(
                of: "law", in: text, options: .init(wholeWords: true)
            ).count == 1
        )
    }

    @Test("Nothing is found for an empty query")
    func emptyQueryFindsNothing() {
        #expect(WritingPreviewFind.matches(of: "", in: runs("Grace abounds")).isEmpty)
    }

    @Test("A fresh search makes the first match current")
    func firstMatchIsCurrent() {
        let result = WritingPreviewFind.result(of: "grace", in: runs("grace", "grace"))
        #expect(result.current == 0)
        #expect(result.status == WritingFindStatus(count: 2, current: 1))
    }

    @Test("A search with nothing found says so")
    func nothingFoundIsNoMatches() {
        let result = WritingPreviewFind.result(of: "mercy", in: runs("grace"))
        #expect(result.current == nil)
        #expect(result.status == .noMatches)
        #expect(result.currentRunID == nil)
    }

    @Test("Stepping forward wraps round the end, as a Mac find bar does")
    func nextWrapsAround() {
        var result = WritingPreviewFind.result(of: "grace", in: runs("grace", "grace"))
        result = WritingPreviewFind.next(result)
        #expect(result.current == 1)
        result = WritingPreviewFind.next(result)
        #expect(result.current == 0)
    }

    @Test("Stepping back wraps round the start")
    func previousWrapsAround() {
        var result = WritingPreviewFind.result(of: "grace", in: runs("grace", "grace"))
        result = WritingPreviewFind.previous(result)
        #expect(result.current == 1)
    }

    @Test("Stepping with nothing found stays at nothing found")
    func steppingNothingStaysNothing() {
        let empty = WritingPreviewFindResult.none
        #expect(WritingPreviewFind.next(empty) == .none)
        #expect(WritingPreviewFind.previous(empty) == .none)
    }

    @Test("Only the current match is the current one, and only in its own run")
    func currentRangeBelongsToOneRun() {
        var result = WritingPreviewFind.result(of: "grace", in: runs("grace", "grace"))
        #expect(result.currentRange(inRun: 0) != nil)
        #expect(result.currentRange(inRun: 1) == nil)
        result = WritingPreviewFind.next(result)
        #expect(result.currentRange(inRun: 0) == nil)
        #expect(result.currentRange(inRun: 1) != nil)
        #expect(result.currentRunID == 1)
    }

    @Test("A run draws every match it holds, current or not")
    func rangesCoverTheWholeRun() {
        let result = WritingPreviewFind.result(of: "grace", in: runs("grace and grace"))
        #expect(result.ranges(inRun: 0).count == 2)
        #expect(result.ranges(inRun: 1).isEmpty)
    }

    @Test("Searching again after an edit keeps the reader on the same match")
    func keepsItsPlaceAcrossAnEdit() {
        var result = WritingPreviewFind.result(of: "grace", in: runs("grace", "grace", "grace"))
        result = WritingPreviewFind.next(result)
        #expect(result.current == 1)
        let again = WritingPreviewFind.result(
            of: "grace",
            in: runs("grace", "grace", "grace", "grace"),
            keepingPositionOf: result
        )
        #expect(again.current == 1)
    }

    @Test("When an edit leaves fewer matches, the last one is current")
    func clampsWhenMatchesGoAway() {
        var result = WritingPreviewFind.result(of: "grace", in: runs("grace", "grace", "grace"))
        result = WritingPreviewFind.next(WritingPreviewFind.next(result))
        #expect(result.current == 2)
        let again = WritingPreviewFind.result(
            of: "grace", in: runs("grace"), keepingPositionOf: result
        )
        #expect(again.current == 0)
    }

    @Test("When an edit takes every match away, nothing is current")
    func nothingLeftIsNothingCurrent() {
        let result = WritingPreviewFind.result(of: "grace", in: runs("grace"))
        let again = WritingPreviewFind.result(
            of: "grace", in: runs("mercy"), keepingPositionOf: result
        )
        #expect(again == .none)
    }
}

/// The marks drawn on found text. These sit over an `AttributedString`, whose
/// indices count characters, while a match is a UTF-16 range — so the mapping
/// between them is what these hold to.
@Suite("Marking what a preview found")
struct WritingPreviewMarkingTests {
    /// The text that is marked, which is also the text that is searched: the
    /// inline Markdown is already resolved, so the asterisks are not in it.
    private func drawn(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }

    private func marked(_ text: AttributedString) -> [String] {
        text.runs.compactMap { run in
            run.backgroundColor == nil ? nil : String(text[run.range].characters)
        }
    }

    @Test("Nothing is marked when nothing was found")
    func nothingFoundMarksNothing() {
        let text = drawn("Grace abounds")
        #expect(text.markingFindMatches([], current: nil) == text)
    }

    @Test("The found words are the words that get marked")
    func marksTheFoundWords() {
        let text = drawn("grace and grace")
        let found = WritingFind.matches(of: "grace", in: String(text.characters))
        #expect(marked(text.markingFindMatches(found, current: found.first)) == ["grace", "grace"])
    }

    @Test("A match inside bold text is marked where it is drawn, not where it was written")
    func marksThroughResolvedMarkdown() {
        // "**Grace** abounds" draws as "Grace abounds": the asterisks are gone
        // by the time there is anything to mark, so a range counted on the
        // drawn text would land two characters late on the written one.
        let text = drawn("**Grace** abounds")
        #expect(String(text.characters) == "Grace abounds")
        let found = WritingFind.matches(of: "abounds", in: String(text.characters))
        #expect(marked(text.markingFindMatches(found, current: nil)) == ["abounds"])
    }

    @Test("The current match is drawn differently from the others")
    func currentMatchStandsOut() {
        let text = drawn("grace and grace")
        let found = WritingFind.matches(of: "grace", in: String(text.characters))
        let result = text.markingFindMatches(found, current: found.last)
        let colours = result.runs.compactMap(\.backgroundColor)
        #expect(colours.count == 2)
        #expect(colours.first != colours.last)
    }

    @Test("A match after an accent is marked on the right letters")
    func marksPastACombiningMark() {
        // A decomposed "é" is two UTF-16 units and one character. A mapping
        // that confused the two would mark one letter to the left here.
        let text = drawn("Noe\u{0301}l brings grace")
        let found = WritingFind.matches(of: "grace", in: String(text.characters))
        #expect(marked(text.markingFindMatches(found, current: nil)) == ["grace"])
    }

    @Test("A range that is not in the text marks nothing, rather than crashing")
    func anImpossibleRangeIsIgnored() {
        let text = drawn("Grace")
        let past = NSRange(location: 40, length: 5)
        #expect(marked(text.markingFindMatches([past], current: nil)).isEmpty)
    }
}
