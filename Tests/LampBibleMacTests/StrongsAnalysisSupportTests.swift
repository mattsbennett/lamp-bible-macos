import Foundation
import LampCore
import Testing
@testable import LampBibleMacSupport

/// Narrowing an analysis to the occurrences behind one of its figures.
///
/// These are the sums the pane does for itself. Core counts; the pane decides
/// which occurrences a reader meant when they clicked a number, and getting
/// that wrong shows them a list that disagrees with the figure they clicked.
struct StrongsAnalysisSupportTests {
    private static func reference(book: Int, chapter: Int, verse: Int) -> Int {
        book * 1_000_000 + chapter * 1_000 + verse
    }

    private static func occurrence(
        book: Int = 43,
        chapter: Int = 1,
        verse: Int = 1,
        renderingID: String = "word",
        form: String? = "λόγος",
        morphology: String? = nil
    ) -> LampStrongsAnalysis.Occurrence {
        LampStrongsAnalysis.Occurrence(
            reference: reference(book: book, chapter: chapter, verse: verse),
            startOffset: 0,
            endOffset: 4,
            text: "Word",
            renderingID: renderingID,
            form: form,
            morphology: morphology
        )
    }

    private static func analysis(
        translationID: String,
        occurrences: [LampStrongsAnalysis.Occurrence] = []
    ) -> LampStrongsAnalysis {
        LampStrongsAnalysis(
            key: "G3056",
            translationID: translationID,
            translationName: translationID,
            translationAbbreviation: translationID,
            wordCount: 1_000,
            taggedVerseCount: 10,
            occurrences: occurrences,
            references: occurrences.map(\.reference),
            renderings: [],
            forms: [],
            parsings: [],
            grammar: [],
            books: [],
            sections: [],
            companions: []
        )
    }

    private static func division(
        id: Int,
        name: String,
        occurrenceCount: Int,
        wordCount: Int,
        keyness: Double = 0
    ) -> LampStrongsAnalysis.Division {
        LampStrongsAnalysis.Division(
            id: id,
            name: name,
            bookRange: id...id,
            occurrenceCount: occurrenceCount,
            verseCount: occurrenceCount,
            wordCount: wordCount,
            expectedCount: 0,
            keyness: keyness,
            chapters: []
        )
    }

    // MARK: - Filtering

    @Test func arenderingKeepsOnlyItsOwnOccurrences() {
        let analysis = Self.analysis(
            translationID: "BSBs",
            occurrences: [
                Self.occurrence(renderingID: "word"),
                Self.occurrence(verse: 2, renderingID: "saying"),
                Self.occurrence(verse: 3, renderingID: "word"),
            ]
        )

        let kept = analysis.occurrences(
            matching: .rendering(id: "word", text: "Word")
        )
        #expect(kept.count == 2)
        #expect(kept.allSatisfy { $0.renderingID == "word" })
    }

    @Test func nofilterKeepsEverything() {
        let analysis = Self.analysis(
            translationID: "BSBs",
            occurrences: [Self.occurrence(), Self.occurrence(verse: 2)]
        )
        #expect(analysis.occurrences(matching: nil).count == 2)
    }

    /// A book takes all of its chapters; a chapter takes only its own. Both
    /// read the book out of the verse reference, so a filter that compared the
    /// wrong digits would pass one of these and fail the other.
    @Test func abookTakesItsChaptersAndAChapterTakesOnlyItsOwn() {
        let analysis = Self.analysis(
            translationID: "BSBs",
            occurrences: [
                Self.occurrence(book: 43, chapter: 1, verse: 1),
                Self.occurrence(book: 43, chapter: 3, verse: 16),
                Self.occurrence(book: 41, chapter: 1, verse: 1),
            ]
        )

        #expect(analysis.occurrences(matching: .book(number: 43)).count == 2)
        #expect(analysis.occurrences(matching: .book(number: 41)).count == 1)
        #expect(
            analysis.occurrences(matching: .chapter(book: 43, number: 1)).count == 1,
            "John 1 must not collect Mark 1"
        )
        #expect(analysis.occurrences(matching: .chapter(book: 41, number: 1)).count == 1)
        #expect(analysis.occurrences(matching: .chapter(book: 43, number: 2)).isEmpty)
    }

    /// Grammar is read through core's own parser, because the counts this
    /// filter narrows were produced by that parser. The filter must compare
    /// the feature as well as the value, and a word with no parsing belongs to
    /// no grammatical value at all.
    @Test func grammarMatchesThroughCoresParserAndNeedsBothHalves() throws {
        let aorist = try #require(
            LampGreekMorphology.features(of: "V-AAI-3S").first { $0.feature == .tense }
        )
        let analysis = Self.analysis(
            translationID: "KJVs",
            occurrences: [
                Self.occurrence(verse: 1, morphology: "V-AAI-3S"),
                Self.occurrence(verse: 2, morphology: "V-PAI-3S"),
                Self.occurrence(verse: 3, morphology: nil),
            ]
        )

        let kept = analysis.occurrences(
            matching: .grammar(feature: aorist.feature, value: aorist.value)
        )
        #expect(kept.count == 1, "only the aorist occurrence")
        #expect(kept.first?.morphology == "V-AAI-3S")

        #expect(
            analysis.occurrences(
                matching: .grammar(feature: .gender, value: aorist.value)
            ).isEmpty,
            "the same value under another feature must not match"
        )
    }

    @Test func aformMatchesTheTaggedWordAndNeverAnUntaggedOne() {
        let analysis = Self.analysis(
            translationID: "BSBs",
            occurrences: [
                Self.occurrence(verse: 1, form: "λόγος"),
                Self.occurrence(verse: 2, form: "λόγου"),
                Self.occurrence(verse: 3, form: nil),
            ]
        )

        #expect(analysis.occurrences(matching: .form("λόγος")).count == 1)
        #expect(analysis.occurrences(matching: .form("λόγου")).count == 1)
    }

    // MARK: - The chip

    /// The chip is the only thing telling a reader what the list has been
    /// narrowed to, so every case has to name itself in words — a rendering by
    /// its text and never its id.
    @Test func everyfilterNamesItselfForTheChip() {
        #expect(LampStrongsFilter.rendering(id: "word-1", text: "Word").label == "“Word”")
        #expect(LampStrongsFilter.form("λόγος").label == "λόγος")
        #expect(LampStrongsFilter.grammar(feature: .tense, value: "Aorist").label
            == "Tense: Aorist")
        #expect(LampStrongsFilter.book(number: 43).label == "John")
        #expect(LampStrongsFilter.chapter(book: 43, number: 3).label == "John 3")
    }

    // MARK: - The spread chart

    @Test func barsAreScaledAgainstTheLongestOne() {
        let bars = LampStrongsSpread.bars(
            [
                Self.division(id: 41, name: "Mark", occurrenceCount: 5, wordCount: 1_000),
                Self.division(id: 43, name: "John", occurrenceCount: 20, wordCount: 1_000),
            ],
            measure: .occurrences
        )

        #expect(bars.map(\.name) == ["Mark", "John"], "the order given is kept")
        #expect(bars[1].share == 1)
        #expect(bars[0].share == 0.25)
    }

    /// Per 1,000 words is a different ranking, not a rescaling: a short book
    /// with few occurrences can outrank a long one with many.
    @Test func therateCanRankABookAboveOneWithMoreOccurrences() {
        let divisions = [
            Self.division(id: 43, name: "John", occurrenceCount: 20, wordCount: 100_000),
            Self.division(id: 65, name: "Jude", occurrenceCount: 2, wordCount: 1_000),
        ]

        let byCount = LampStrongsSpread.bars(divisions, measure: .occurrences)
        #expect(byCount[0].share == 1, "John has the most occurrences")

        let byRate = LampStrongsSpread.bars(divisions, measure: .perThousandWords)
        #expect(byRate[1].share == 1, "but Jude uses it far more densely")
        #expect(byRate[0].value == 0.2)
        #expect(byRate[1].value == 2)
    }

    /// A key that occurs nowhere in range. Every bar is zero, and the longest
    /// of them is zero, so the share has to be decided rather than divided.
    @Test func akeyThatOccursNowhereDrawsNoBarsRatherThanFullOnes() {
        for measure in LampStrongsSpreadMeasure.allCases {
            let bars = LampStrongsSpread.bars(
                [
                    Self.division(id: 41, name: "Mark", occurrenceCount: 0, wordCount: 1_000),
                    Self.division(id: 43, name: "John", occurrenceCount: 0, wordCount: 0),
                ],
                measure: measure
            )
            #expect(bars.allSatisfy { $0.share == 0 }, "\(measure.title) must draw nothing")
            #expect(bars.allSatisfy { $0.value.isFinite }, "\(measure.title) must not be NaN")
        }
    }

    @Test func divisionsWithNoWordsDoNotDivideByZero() {
        let bars = LampStrongsSpread.bars(
            [
                Self.division(id: 43, name: "John", occurrenceCount: 4, wordCount: 0),
                Self.division(id: 41, name: "Mark", occurrenceCount: 2, wordCount: 1_000),
            ],
            measure: .perThousandWords
        )
        #expect(bars[0].value == 0, "no tagged words means no rate, not infinity")
        #expect(bars.allSatisfy { $0.value.isFinite })
        #expect(bars[1].share == 1)
    }

    @Test func anotableDivisionCarriesItsStanding() {
        let bars = LampStrongsSpread.bars(
            [
                Self.division(
                    id: 43, name: "John", occurrenceCount: 40, wordCount: 1_000,
                    keyness: LampStrongsAnalysis.notableKeyness + 1
                ),
                Self.division(
                    id: 41, name: "Mark", occurrenceCount: 1, wordCount: 1_000,
                    keyness: -(LampStrongsAnalysis.notableKeyness + 1)
                ),
                Self.division(id: 42, name: "Luke", occurrenceCount: 10, wordCount: 1_000),
            ],
            measure: .occurrences
        )

        #expect(bars[0].expectation == .more)
        #expect(bars[1].expectation == .fewer)
        #expect(bars[2].expectation == .asExpected, "below the threshold is not news")
    }

    // MARK: - Which translation leads

    /// The pane shows the translation being read before the others have been
    /// worked out, so the settled order has to begin with that same one.
    @Test func thetranslationBeingReadComesFirst() {
        let analyses = ["BSBs", "KJVs", "WEBs"].map { Self.analysis(translationID: $0) }

        let ordered = LampStrongsAnalysisOrder.ordered(analyses, activeTranslationID: "WEBs")
        #expect(ordered.map(\.translationID) == ["WEBs", "BSBs", "KJVs"])
        #expect(
            LampStrongsAnalysisOrder.ordered(analyses, activeTranslationID: "BSBs")
                .map(\.translationID) == ["BSBs", "KJVs", "WEBs"],
            "one already in front stays there, and the rest keep installed order"
        )
    }

    /// Reading a translation that tags nothing for this key: it has no
    /// analysis, and the rest must not be reshuffled on its account.
    @Test func atranslationWithNoAnalysisLeavesTheOrderAlone() {
        let analyses = ["BSBs", "KJVs"].map { Self.analysis(translationID: $0) }

        for active in ["ESVs", nil] {
            #expect(
                LampStrongsAnalysisOrder.ordered(analyses, activeTranslationID: active)
                    .map(\.translationID) == ["BSBs", "KJVs"]
            )
        }
        #expect(LampStrongsAnalysisOrder.ordered([], activeTranslationID: "BSBs").isEmpty)
    }
}

/// Which block roles Slide Studio offers.
struct StudioBlockKindTests {
    /// Studio draws a chart but cannot yet build one, and a chart block with no
    /// chart in it is invalid the moment it is added.
    @Test func achartIsNotOfferedAsSomethingToAdd() {
        #expect(!LampPresentationBlockKind.authorableHere.contains(.chart))
        #expect(
            LampPresentationBlockKind.authorableHere.count
                == LampPresentationBlockKind.allCases.count - 1,
            "only the chart is held back"
        )
        for kind in LampPresentationBlockKind.allCases where kind != .chart {
            #expect(LampPresentationBlockKind.authorableHere.contains(kind))
        }
    }

    /// A picker bound to an existing chart has to list `chart`, or SwiftUI
    /// finds no tag matching the selection and can reset it — turning an
    /// agent's chart into whatever role comes first.
    @Test func anexistingChartKeepsItsOwnRoleInThePicker() {
        #expect(LampPresentationBlockKind.authorableHere(including: .chart).contains(.chart))
        #expect(
            !LampPresentationBlockKind.authorableHere(including: .title).contains(.chart),
            "a title block is not an excuse to offer charts"
        )
        #expect(
            LampPresentationBlockKind.authorableHere(including: .chart).count
                == LampPresentationBlockKind.allCases.count
        )
    }
}
