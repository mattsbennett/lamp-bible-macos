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
    /// A chart was held back while Studio could draw one but not build one.
    /// It has an editor now, so every role is offered again.
    @Test func everyRoleCanBeAddedNowThatChartsHaveAnEditor() {
        #expect(LampPresentationBlockKind.authorableHere.contains(.chart))
        #expect(
            LampPresentationBlockKind.authorableHere.count
                == LampPresentationBlockKind.allCases.count
        )
    }

    /// The invariant that outlives whatever is held back: a picker bound to a
    /// block must list that block's own role. Without it SwiftUI finds no tag
    /// matching the selection, draws blank, and can reset the value — turning
    /// one kind of block into another just by looking at it.
    ///
    /// Written over every role rather than over the chart, because the next
    /// role to be held back is the one nobody will think to test.
    @Test func apickerAlwaysListsTheBlocksOwnRole() {
        for kind in LampPresentationBlockKind.allCases {
            let offered = LampPresentationBlockKind.authorableHere(including: kind)
            #expect(offered.contains(kind), "\(kind) must appear in its own picker")
            #expect(
                Set(offered).count == offered.count,
                "\(kind) must not be listed twice"
            )
        }
    }
}

/// Showing a verse around the word that carries the key.
struct StrongsContextTests {
    @Test func theverseIsSplitAroundTheTaggedWord() {
        let snippet = LampStrongsContext.snippet(
            of: "In the beginning was the Word, and the Word was with God.",
            from: 25,
            to: 29
        )

        #expect(snippet.before == "In the beginning was the ")
        #expect(snippet.word == "Word")
        #expect(snippet.after == ", and the Word was with God.")
        #expect(!snippet.isTrimmedAtStart)
        #expect(!snippet.isTrimmedAtEnd)
    }

    /// Offsets count Characters, not Unicode scalars. A decomposed accent
    /// earlier in the verse makes the two disagree, and slicing by scalars
    /// moves the highlight off the word — the same mistake the book readers
    /// made in the other direction.
    @Test func adecomposedAccentEarlierInTheVerseDoesNotMoveTheWord() {
        // "Café" with a combining acute: five scalars, four characters.
        let verse = "Cafe\u{301} and love abide"
        #expect(verse.unicodeScalars.count != Array(verse).count, "the two must disagree here")

        let characters = Array(verse)
        let start = 9
        let end = 13
        #expect(String(characters[start..<end]) == "love", "the fixture's own offsets")

        let snippet = LampStrongsContext.snippet(of: verse, from: start, to: end)
        #expect(snippet.word == "love")
        #expect(snippet.after == " abide")
    }

    /// An offset past the end of the verse. Clamped, because a tag that
    /// disagrees with its verse must not take a row down — and must not
    /// silently highlight the wrong words either.
    @Test func offsetsPastTheEndAreClampedRatherThanTrusted() {
        let verse = "Short verse."

        let past = LampStrongsContext.snippet(of: verse, from: 400, to: 500)
        #expect(past.before == verse)
        #expect(past.word.isEmpty)
        #expect(past.after.isEmpty)

        let straddling = LampStrongsContext.snippet(of: verse, from: 6, to: 900)
        #expect(straddling.before == "Short ")
        #expect(straddling.word == "verse.")
        #expect(straddling.after.isEmpty)
    }

    @Test func negativeAndReversedOffsetsGiveNoWordRatherThanACrash() {
        let verse = "In the beginning"

        let negative = LampStrongsContext.snippet(of: verse, from: -5, to: 2)
        #expect(negative.before.isEmpty)
        #expect(negative.word == "In")

        let reversed = LampStrongsContext.snippet(of: verse, from: 9, to: 3)
        #expect(reversed.word.isEmpty, "an end before its start describes nothing")
        #expect(reversed.before == "In the be")
    }

    @Test func alongVerseIsTrimmedEitherSideAndSaysSo() {
        let filler = String(repeating: "word ", count: 60)
        let snippet = LampStrongsContext.snippet(
            of: filler + "LOVE " + filler,
            from: filler.count,
            to: filler.count + 4,
            window: 20
        )

        #expect(snippet.word == "LOVE")
        #expect(snippet.isTrimmedAtStart)
        #expect(snippet.isTrimmedAtEnd)
        #expect(snippet.before.count <= 20)
        #expect(snippet.after.count <= 20)
    }

    /// Trimming stops at a space, so a row never opens or closes on half a
    /// word.
    @Test func trimmingDoesNotCutAWordInHalf() {
        let snippet = LampStrongsContext.snippet(
            of: "Jerusalem Jerusalem Jerusalem LOVE Jerusalem Jerusalem",
            from: 30,
            to: 34,
            window: 15
        )

        #expect(snippet.word == "LOVE")
        #expect(!snippet.before.hasPrefix("salem"), "it must not start mid-word")
        #expect(!snippet.after.hasSuffix("Jerus"), "nor end mid-word")
    }

    /// A verse that was never asked for. The pane only requests verses for the
    /// translation being read, so the rest have none and must simply show no
    /// snippet.
    @Test func atranslationWithNoVersesKeptHasNoSnippets() {
        let analysis = LampStrongsAnalysis(
            key: "G3056", translationID: "KJVs", translationName: "KJV",
            translationAbbreviation: "KJV", wordCount: 10, taggedVerseCount: 1,
            occurrences: [], references: [], renderings: [], forms: [],
            parsings: [], grammar: [], books: [], sections: [], companions: []
        )
        #expect(analysis.verseTexts.isEmpty)
    }
}

/// Spotting a Strong's key typed into the search box.
struct StrongsQueryTests {
    @Test(arguments: [
        ("H7225", "H7225"),
        ("h7225", "H7225"),
        (" G26 ", "G26"),
        ("G0026", "G26"),
        ("G1234a", "G1234A"),
        ("TH1234", "TH1234"),
    ])
    func akeyIsRecognisedAndNormalised(typed: String, expected: String) {
        #expect(LampStrongsQuery.key(in: typed) == expected)
    }

    /// The costly mistake: a word that happens to start with H or G being
    /// taken for a key would hijack an ordinary search.
    @Test(arguments: [
        "Genesis", "God", "grace", "Hebrews", "Hebrews 1", "hope",
        "holy", "H", "G", "", "   ", "John 1:1", "7225", "G 26", "G26x9",
    ])
    func wordsAreNotMistakenForKeys(typed: String) {
        #expect(
            LampStrongsQuery.key(in: typed) == nil,
            "\(typed.debugDescription) must stay an ordinary search"
        )
    }
}

/// The other readings of one set of numbers.
struct StrongsChartStyleTests {
    private static func division(
        id: Int, name: String, occurrences: Int, chapters: [(Int, Int)] = []
    ) -> LampStrongsAnalysis.Division {
        LampStrongsAnalysis.Division(
            id: id, name: name, bookRange: id...id,
            occurrenceCount: occurrences, verseCount: occurrences, wordCount: 1_000,
            expectedCount: 0, keyness: 0,
            chapters: chapters.map {
                LampStrongsAnalysis.Chapter(
                    number: $0.0, occurrenceCount: $0.1, wordCount: 500
                )
            }
        )
    }

    // MARK: - Putting the gaps back

    /// The shape is made of its gaps. The analysis leaves out a book the key
    /// never reaches, so drawing straight from it moves Romans next to
    /// Matthew and invents a cluster.
    @Test func theshapeIncludesBooksTheKeyNeverReaches() {
        let sparse = [
            Self.division(id: 40, name: "Matthew", occurrences: 3),
            Self.division(id: 45, name: "Romans", occurrences: 9),
        ]

        let padded = LampStrongsSpread.everyBook(from: sparse, in: 40...45)
        #expect(padded.count == 6, "Matthew through Romans is six books")
        #expect(padded.map(\.id) == [40, 41, 42, 43, 44, 45])
        #expect(padded.map(\.occurrenceCount) == [3, 0, 0, 0, 0, 9])
    }

    /// A book core left out is one whose absence it did not find notable, so
    /// the filler must not claim otherwise.
    @Test func afilledBookIsNotMarkedAsFewerThanExpected() {
        let padded = LampStrongsSpread.everyBook(
            from: [Self.division(id: 40, name: "Matthew", occurrences: 3)],
            in: 40...42
        )
        #expect(padded.dropFirst().allSatisfy { $0.expectation == .asExpected })
        #expect(padded.allSatisfy { $0.ratePerThousandWords.isFinite })
    }

    @Test func nopaddingHappensOutsideTheChosenRange() {
        let padded = LampStrongsSpread.everyBook(
            from: [Self.division(id: 1, name: "Genesis", occurrences: 5)],
            in: 40...41
        )
        #expect(padded.map(\.id) == [40, 41], "Genesis is out of range and is dropped")
    }

    // MARK: - Share

    @Test func sharesAreProportionsOfTheWhole() {
        let slices = LampStrongsShare.slices(
            from: [
                Self.division(id: 1, name: "Gospels", occurrences: 25),
                Self.division(id: 2, name: "Paul", occurrences: 75),
            ]
        )
        #expect(slices.map(\.name) == ["Paul", "Gospels"], "largest first")
        #expect(slices[0].fraction == 0.75)
        #expect(slices[1].fraction == 0.25)
        #expect(abs(slices.reduce(0) { $0 + $1.fraction } - 1) < 0.000_001)
    }

    /// A ring of twenty-seven slivers answers nothing, so the tail is
    /// gathered — and the gathered slice still has to carry its real count.
    @Test func thetailIsGatheredIntoOther() {
        let divisions = (1...10).map {
            Self.division(id: $0, name: "Book \($0)", occurrences: 11 - $0)
        }

        let slices = LampStrongsShare.slices(from: divisions, limit: 3)
        #expect(slices.count == 4)
        #expect(slices.last?.isOther == true)
        #expect(slices.last?.name == "Other")
        // 10+9+8 named, the remaining 7...1 gathered.
        #expect(slices.last?.value == 28)
        #expect(abs(slices.reduce(0) { $0 + $1.fraction } - 1) < 0.000_001)
    }

    @Test func nothingToShareDrawsNoSlices() {
        #expect(LampStrongsShare.slices(from: []).isEmpty)
        #expect(
            LampStrongsShare.slices(
                from: [Self.division(id: 1, name: "Gospels", occurrences: 0)]
            ).isEmpty,
            "a slice of nothing is invisible but still takes a label"
        )
    }

    @Test func anexactFitAddsNoOtherSlice() {
        let slices = LampStrongsShare.slices(
            from: [
                Self.division(id: 1, name: "A", occurrences: 2),
                Self.division(id: 2, name: "B", occurrences: 1),
            ],
            limit: 6
        )
        #expect(slices.count == 2)
        #expect(slices.contains { $0.isOther } == false)
    }

    // MARK: - Grid

    /// Shaded against the busiest chapter anywhere, not the busiest in each
    /// row. Per-row shading would paint a book with one occurrence as darkly
    /// as the book with twenty.
    @Test func thegridIsShadedAgainstTheBusiestChapterAnywhere() {
        let rows = LampStrongsGrid.rows(from: [
            Self.division(id: 43, name: "John", occurrences: 2, chapters: [(1, 1), (2, 1)]),
            Self.division(id: 62, name: "1 John", occurrences: 21, chapters: [(1, 1), (4, 20)]),
        ])

        #expect(rows.count == 2)
        let john = try! #require(rows.first { $0.name == "John" })
        let first = try! #require(rows.first { $0.name == "1 John" })
        #expect(first.cells.last?.intensity == 1, "the busiest chapter anchors the ramp")
        #expect(john.cells.first?.intensity == 0.05, "one against twenty, not one against one")
    }

    @Test func booksWithNoChaptersOrNoOccurrencesAreLeftOut() {
        let rows = LampStrongsGrid.rows(from: [
            Self.division(id: 43, name: "John", occurrences: 2, chapters: [(1, 2)]),
            Self.division(id: 41, name: "Mark", occurrences: 0, chapters: [(1, 0)]),
            Self.division(id: 40, name: "Matthew", occurrences: 5),
        ])
        #expect(rows.map(\.name) == ["John"])
    }

    @Test func anemptyGridDoesNotDivideByZero() {
        let rows = LampStrongsGrid.rows(
            from: [Self.division(id: 43, name: "John", occurrences: 0, chapters: [(1, 0)])],
            includingEmptyBooks: true
        )
        #expect(rows.first?.cells.allSatisfy { $0.intensity == 0 } == true)
    }

    @Test func onlybarsAndColumnsHaveARate() {
        #expect(LampStrongsChartStyle.bars.usesMeasure)
        #expect(LampStrongsChartStyle.columns.usesMeasure)
        #expect(!LampStrongsChartStyle.grid.usesMeasure)
        #expect(!LampStrongsChartStyle.share.usesMeasure)
        #expect(LampStrongsChartStyle.grid.needsBooks)
    }
}
