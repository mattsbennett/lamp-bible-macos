import Foundation
import Testing
@testable import LampBibleMacSupport

struct WritingFindSupportTests {
    private func found(
        _ query: String,
        in text: String,
        _ options: WritingFindOptions = .init()
    ) -> [String] {
        WritingFind.matches(of: query, in: text, options: options)
            .map { (text as NSString).substring(with: $0) }
    }

    @Test func caseIsIgnoredUnlessMatched() {
        #expect(found("grace", in: "Grace upon grace") == ["Grace", "grace"])
        #expect(found("grace", in: "Grace upon grace", .init(matchesCase: true)) == ["grace"])
    }

    @Test func wholeWordsMissAWordInsideAnother() {
        let text = "The law, the lawless, and the law."
        #expect(found("law", in: text).count == 3)
        #expect(WritingFind.matches(of: "law", in: text, options: .init(wholeWords: true))
            .map(\.location) == [4, 30])

        // Punctuation at an edge needs no boundary.
        #expect(found("Cain", in: "Cain's offering", .init(wholeWords: true)) == ["Cain"])
        #expect(found("law.", in: text, .init(wholeWords: true)) == ["law."])
    }

    @Test func matchesNeverOverlap() {
        #expect(WritingFind.matches(of: "aa", in: "aaaaa").map(\.location) == [0, 2])
    }

    @Test func composedAndDecomposedAccentsAreTheSameLetter() {
        let decomposed = "the cafe\u{0301} door"
        let matches = WritingFind.matches(of: "caf\u{00E9}", in: decomposed)
        #expect(matches == [NSRange(location: 4, length: 5)])
    }

    @Test func aMatchNeverSplitsALetter() {
        // The accent belongs to the e, so "grace" is not a prefix here.
        #expect(found("grace", in: "grace\u{0301}d").isEmpty)
        // Pointed Hebrew: the points travel with their letters.
        let pointed = "\u{05D1}\u{05B0}\u{05BC}\u{05E8}\u{05B5}\u{05D0}\u{05E9}\u{05B4}\u{05C1}\u{05D9}\u{05EA}"
        #expect(found(pointed, in: "\(pointed) \u{05D1}\u{05B8}\u{05BC}\u{05E8}\u{05B8}\u{05D0}") == [pointed])
    }

    @Test func rangesCountAsATextViewDoes() {
        // The emoji is two UTF-16 units, and a text view's ranges count those.
        #expect(WritingFind.matches(of: "grace", in: "🙏 grace") == [NSRange(location: 3, length: 5)])
    }

    @Test func anEmptyQueryFindsNothing() {
        #expect(WritingFind.matches(of: "", in: "anything").isEmpty)
    }

    @Test func aSearchStartsAtTheCaretAndWraps() {
        let matches = [0, 10, 20].map { NSRange(location: $0, length: 3) }
        #expect(WritingFind.index(startingAt: 5, in: matches) == 1)
        #expect(WritingFind.index(startingAt: 10, in: matches) == 1)
        #expect(WritingFind.index(startingAt: 25, in: matches) == 0)
        #expect(WritingFind.index(startingAt: 0, in: []) == nil)
    }

    @Test func theStatusReadsAsAFindBarShowsIt() {
        #expect(WritingFindStatus(count: 12, current: 3).description == "3 of 12")
        #expect(WritingFindStatus.noMatches.description == "No matches")
        #expect(WritingFindStatus(count: 1, current: 0).description == "1 match")
    }
}
