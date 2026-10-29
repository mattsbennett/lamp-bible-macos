import Foundation
import LampCore
import Testing
@testable import LampBibleMacSupport

/// Checking and deriving a deck from its text, with no folder and no `python3`.
///
/// This is what the skill could not do before: an app with no working
/// directory could not run it at all, and a Mac without the developer tools
/// has no `python3` to run the validator with — so the check was already
/// failing inside Lamp's own workspace.
struct DeckToolTests {
    /// A conforming deck, close to the skill's own example. Two slides, so a
    /// report has somewhere to disagree with itself.
    private func deckJSON(
        title: String = "Living Hope",
        notesSource: String? = nil,
        notesAnchor: String? = nil,
        chart: [String: Any]? = nil,
        bareChartBlock: Bool = false
    ) -> Data {
        var deck: [String: Any] = [
            "schemaVersion": 1,
            "id": "60910124-99b3-48ca-9310-11c63ed118c0",
            "title": title,
            "aspectRatio": "widescreen",
            // Required, and taken from the skill's own example so the fixture
            // is a deck Lamp would really accept.
            "theme": [
                "id": "lamp-dark",
                "accentColor": "#F59E0B",
                "backgroundColor": "#111827",
                "foregroundColor": "#F9FAFB",
                "typeface": "system-serif",
            ],
            "source": ["id": "60910124-99b3-48ca-9310-11c63ed118c1", "kind": "devotional"],
            "slides": [
                [
                    "id": "3b184129-31c5-48c8-962e-fe79e2862cc8",
                    "layout": "title",
                    "isHidden": false,
                    "speakerNotes": "Welcome the audience and set the question.",
                    "blocks": [
                        [
                            "id": "3921b8a7-335a-4424-945b-bcb9d949bd64",
                            "kind": "title",
                            "text": title,
                        ],
                    ],
                ] as [String: Any],
                [
                    "id": "aa184129-31c5-48c8-962e-fe79e2862cc9",
                    "layout": "title-and-body",
                    "isHidden": false,
                    "speakerNotes": "",
                    "blocks": [
                        [
                            "id": "bb21b8a7-335a-4424-945b-bcb9d949bd65",
                            "kind": "title",
                            "text": "The question",
                        ],
                        [
                            "id": "cc21b8a7-335a-4424-945b-bcb9d949bd66",
                            "kind": "body",
                            "text": "What does a living hope ask of us today?",
                        ],
                    ],
                    "notesAnchor": notesAnchor,
                ].compactMapValues { $0 } as [String: Any],
            ],
        ]
        if let notesSource { deck["speakerNotesSource"] = notesSource }
        // On the *second* slide, so a chart issue has to be filed under slide
        // two rather than wherever a zero-based path happens to land.
        if chart != nil || bareChartBlock, var slides = deck["slides"] as? [[String: Any]] {
            var blocks = slides[1]["blocks"] as? [[String: Any]] ?? []
            var block: [String: Any] = [
                "id": "dd21b8a7-335a-4424-945b-bcb9d949bd67",
                "kind": "chart",
                "text": "Where it is found",
            ]
            // Without `chart`, which is the error both validators report.
            if let chart { block["chart"] = chart }
            blocks.append(block)
            slides[1]["blocks"] = blocks
            deck["slides"] = slides
        }
        return try! JSONSerialization.data(withJSONObject: deck, options: [.sortedKeys])
    }

    /// A chart source naming a key and a translation, with no values yet —
    /// which is what an agent writes.
    private func chartSource(
        strongs: String = "G26",
        translationID: String = "ESVs",
        by: String = "section",
        measure: String = "occurrences"
    ) -> [String: Any] {
        [
            "source": ["strongs": strongs, "translationID": translationID],
            "by": by,
            "measure": measure,
        ]
    }

    /// Stands in for a library, so the chart reporting can be tested without
    /// one holding Strong's-tagged translations. It fills every chart with one
    /// value and reports whatever issues it was given.
    private func chartWorker(
        value: Double = 71,
        issues: [LampPresentationDeckIssue] = []
    ) -> LampDeckChartWorker {
        { deck in
            var filled = deck
            var changed = false
            for slideIndex in filled.slides.indices {
                for blockIndex in filled.slides[slideIndex].blocks.indices
                where filled.slides[slideIndex].blocks[blockIndex].kind == .chart {
                    filled.slides[slideIndex].blocks[blockIndex].chart?.values = [
                        .init(label: "Paul’s Letters", value: value, standing: .more),
                    ]
                    changed = true
                }
            }
            return LampPresentationChartReport(
                deck: filled, issues: issues, changed: changed
            )
        }
    }

    // MARK: - Validate

    @Test func aconformingDeckValidates() throws {
        let report = LampDeckTools.validate(deckJSON: deckJSON())

        #expect(report.valid)
        #expect(report.errorCount == 0)
        #expect(report.deckTitle == "Living Hope")
        #expect(report.slideCount == 2)
    }

    /// "This is not a deck" is the most useful validation result there is, so
    /// it comes back as a report rather than a thrown error an agent cannot
    /// read.
    @Test func somethingThatIsNotADeckIsReportedNotThrown() {
        for rubbish in [Data("{ not json".utf8), Data("{}".utf8), Data()] {
            let report = LampDeckTools.validate(deckJSON: rubbish)
            #expect(report.valid == false)
            #expect(report.errorCount >= 1)
            #expect(report.issues.isEmpty == false, "a refusal has to say something")
        }
    }

    /// A deck being written by hand is missing a key far more often than it
    /// is malformed, and the format requires several a writer would take for
    /// optional. Saying only "this is not a deck" leaves the agent to guess
    /// which of them it is.
    @Test func amissingFieldIsNamedRatherThanCalledMalformed() throws {
        var deck = try #require(
            try JSONSerialization.jsonObject(with: deckJSON()) as? [String: Any]
        )
        var slides = try #require(deck["slides"] as? [[String: Any]])
        slides[1].removeValue(forKey: "speakerNotes")
        deck["slides"] = slides

        let report = LampDeckTools.validate(
            deckJSON: try JSONSerialization.data(withJSONObject: deck)
        )

        #expect(report.valid == false)
        let issue = try #require(report.issues.first)
        #expect(issue.path == "slides[1].speakerNotes")
        #expect(issue.message.contains("missing"))
    }

    /// Decoding stops at the first fault, so a deck short of two required
    /// fields is told about one of them and has to come back — where
    /// `validate_deck.py` walks the whole deck and lists both.
    ///
    /// Pinned rather than merely written down: if core's decoder ever fills
    /// defaults and lets the validator report these properly, this fails, and
    /// that is the moment to stop saying "one at a time".
    @Test func adeckShortOfTwoFieldsIsToldAboutOne() throws {
        var deck = try #require(
            try JSONSerialization.jsonObject(with: deckJSON()) as? [String: Any]
        )
        var slides = try #require(deck["slides"] as? [[String: Any]])
        slides[1].removeValue(forKey: "speakerNotes")
        slides[1].removeValue(forKey: "isHidden")
        deck["slides"] = slides

        let report = LampDeckTools.validate(
            deckJSON: try JSONSerialization.data(withJSONObject: deck)
        )

        #expect(report.valid == false)
        #expect(report.issues.count == 1, "decoding reports the first fault, not every one")
    }

    @Test func thereportCarriesTheSameIssuesCoresValidatorFinds() throws {
        // A title far past the ceiling, so the validator has something to say
        // and both sides can be compared.
        let long = String(repeating: "A living hope that is set before us. ", count: 40)
        let report = LampDeckTools.validate(deckJSON: deckJSON(title: long))
        let deck = try LampPresentationDeckStore.decodeUnvalidated(deckJSON(title: long))

        #expect(report.issues == LampPresentationDeckValidator.validate(deck))
        #expect(report.errorCount + report.warningCount == report.issues.count)
    }

    // MARK: - Build

    /// The deck comes back as well as the report: a caller with no folder
    /// cannot read it off disk the way the command line does.
    @Test func buildingReturnsTheFilledInDeckAndItsReport() async throws {
        let built = try await LampDeckTools.build(deckJSON: deckJSON(), manuscript: nil)

        #expect(built.resolved)
        #expect(!built.deckJSON.isEmpty)
        let deck = try LampPresentationDeckStore.decodeUnvalidated(built.deckJSON)
        #expect(deck.slides.count == 2)
        #expect(deck.title == "Living Hope")
        let report = try JSONSerialization.jsonObject(with: built.reportJSON) as? [String: Any]
        #expect(report?["resolved"] as? Bool == true)
    }

    @Test func buildingTwiceChangesNothing() async throws {
        let once = try await LampDeckTools.build(deckJSON: deckJSON(), manuscript: nil)
        let twice = try await LampDeckTools.build(deckJSON: once.deckJSON, manuscript: nil)

        #expect(once.deckJSON == twice.deckJSON)
    }

    /// An anchor the manuscript no longer holds is the one failure worth
    /// reporting as one: the slide's notes have stopped being the writing's.
    @Test func abrokenAnchorIsNotResolved() async throws {
        let deck = deckJSON(
            notesSource: "manuscript",
            notesAnchor: "A sentence that is not in the manuscript at all."
        )

        let built = try await LampDeckTools.build(
            deckJSON: deck,
            manuscript: "# Living Hope\n\nSomething else entirely was written here.\n"
        )

        #expect(built.resolved == false)
    }

    @Test func amatchingAnchorTakesItsNotesFromTheManuscript() async throws {
        let anchor = "What does a living hope ask of us today?"
        let built = try await LampDeckTools.build(
            deckJSON: deckJSON(notesSource: "manuscript", notesAnchor: anchor),
            manuscript: """
            # Living Hope

            \(anchor) It asks that we hold to it when nothing has changed yet.
            """
        )

        #expect(built.resolved)
        let deck = try LampPresentationDeckStore.decodeUnvalidated(built.deckJSON)
        let notes = deck.slides.compactMap(\.speakerNotes).joined(separator: "\n")
        #expect(
            notes.contains("nothing has changed yet"),
            "the manuscript's words should have reached the slide's notes"
        )
    }

    // MARK: - Charts

    @Test func chartValuesAreFilledFromTheLibrary() async throws {
        let built = try await LampDeckTools.build(
            deckJSON: deckJSON(chart: chartSource()),
            manuscript: nil,
            charts: chartWorker()
        )

        let deck = try LampPresentationDeckStore.decodeUnvalidated(built.deckJSON)
        let chart = try #require(
            deck.slides[1].blocks.first { $0.kind == .chart }?.chart
        )
        #expect(chart.values?.first?.value == 71)
        #expect(chart.values?.first?.standing == .more)
        let report = try JSONSerialization.jsonObject(with: built.reportJSON) as? [String: Any]
        #expect(report?["chartsUpdated"] as? Bool == true)
    }

    /// A deck whose notes are written by hand still has charts to fill. The
    /// authored-notes case returns early — before this test it returned before
    /// the charts were touched, so every hand-written deck drew empty bars.
    @Test func chartsAreWorkedOutEvenWhenTheNotesAreAuthored() async throws {
        let built = try await LampDeckTools.build(
            deckJSON: deckJSON(notesSource: "authored", chart: chartSource()),
            manuscript: nil,
            charts: chartWorker(value: 9)
        )

        let deck = try LampPresentationDeckStore.decodeUnvalidated(built.deckJSON)
        let chart = try #require(
            deck.slides[1].blocks.first { $0.kind == .chart }?.chart
        )
        #expect(
            chart.values?.first?.value == 9,
            "authored notes mean nothing to derive from a manuscript, not nothing to do"
        )
    }

    /// The chart is on slide two. Core's issue paths are zero-based and a
    /// report's slide numbers are one-based, so an off-by-one here files the
    /// problem under the slide next door — where it is invisible, because that
    /// slide has no chart on it.
    @Test func achartIssueIsFiledUnderItsOwnSlide() async throws {
        let built = try await LampDeckTools.build(
            deckJSON: deckJSON(chart: chartSource()),
            manuscript: nil,
            charts: chartWorker(issues: [
                .init(
                    severity: .warning,
                    path: "slides[1].blocks[2].chart.source",
                    message: "G26 in ESVs has nothing to chart in this range."
                ),
            ])
        )

        let report = try #require(
            try JSONSerialization.jsonObject(with: built.reportJSON) as? [String: Any]
        )
        let slides = try #require(report["slides"] as? [[String: Any]])
        #expect((slides[0]["chartProblems"] as? [String])?.isEmpty == true)
        #expect(
            (slides[1]["chartProblems"] as? [String])?.first?.contains("nothing to chart") == true
        )
        #expect(report["slidesWithProblems"] as? [Int] == [2], "one-based, and only slide two")
    }

    /// A chart that could not be worked out is a warning, not a failure: the
    /// exit status means "the notes are no longer the manuscript's", and a
    /// library without that translation installed says nothing about the notes.
    @Test func achartWarningDoesNotFailTheBuild() async throws {
        let built = try await LampDeckTools.build(
            deckJSON: deckJSON(chart: chartSource()),
            manuscript: nil,
            charts: chartWorker(issues: [
                .init(
                    severity: .warning,
                    path: "slides[1].blocks[2].chart.source",
                    message: "This library has no tagged ESVs."
                ),
            ])
        )

        #expect(built.resolved)
    }

    @Test func adeckWithChartsAndNoLibrarySaysWhatToPass() async throws {
        let built = try await LampDeckTools.build(
            deckJSON: deckJSON(chart: chartSource()),
            manuscript: nil
        )

        let report = try #require(
            try JSONSerialization.jsonObject(with: built.reportJSON) as? [String: Any]
        )
        let problems = try #require(report["problems"] as? [String])
        #expect(
            problems.contains { $0.contains("--library") },
            "a chart with no library to fill it from has to say so, and name the flag"
        )
        #expect(report["chartsUpdated"] as? Bool == false)
    }

    /// A deck with no charts at all must not be told to pass --library.
    @Test func adeckWithNoChartsIsToldNothingAboutLibraries() async throws {
        let built = try await LampDeckTools.build(deckJSON: deckJSON(), manuscript: nil)

        let report = try #require(
            try JSONSerialization.jsonObject(with: built.reportJSON) as? [String: Any]
        )
        #expect((report["problems"] as? [String])?.contains { $0.contains("--library") } != true)
    }

    /// The skill's `validate_deck.py` and this Swift check are two validators
    /// over one format, and they have disagreed before. These are the chart
    /// cases the Python script was given, asserted here so a change to either
    /// shows up as a disagreement rather than as an agent being told different
    /// things depending on which one it ran.
    @Test func thetwoValidatorsAgreeAboutCharts() throws {
        let missing = LampDeckTools.validate(deckJSON: deckJSON(bareChartBlock: true))
        #expect(
            missing.issues.contains {
                $0.severity == .error && $0.path.hasSuffix("chart")
            },
            "a chart block with no chart is an error in both"
        )

        let unfilled = LampDeckTools.validate(deckJSON: deckJSON(chart: chartSource()))
        #expect(
            unfilled.issues.allSatisfy { $0.severity == .warning },
            "a chart with no values yet is a warning in both, never an error"
        )
        #expect(
            unfilled.issues.contains { $0.path.contains("chart") },
            "and it is reported against the chart"
        )
    }

    @Test(arguments: [
        ("slides[0].blocks[1].chart", 0),
        ("slides[11].blocks[0].chart.values", 11),
    ])
    func aslideIndexIsReadFromAnIssuePath(path: String, expected: Int) {
        #expect(LampDeckBuild.slideIndex(inPath: path) == expected)
    }

    /// A path that names no slide gives nothing, rather than slide zero —
    /// which would quietly attach a deck-wide issue to the first slide.
    @Test(arguments: [
        "theme.accentColor",
        "slides[].blocks[0]",
        "slides[two].blocks[0]",
        "",
    ])
    func apathThatNamesNoSlideGivesNothing(path: String) {
        #expect(LampDeckBuild.slideIndex(inPath: path) == nil)
    }

    /// The deck and the manuscript are the writer's prose, so the directory
    /// they pass through is removed however the call ends — including when it
    /// throws, which is when a leftover would otherwise go unnoticed.
    ///
    /// Tested on the scratch helper itself rather than by counting what is in
    /// the temporary directory: the suite runs in parallel, and every other
    /// test here creates one of these too.
    @Test func thescratchDirectoryIsRemovedHoweverTheCallEnds() throws {
        struct Boom: Error {}

        var returned: URL?
        _ = try LampDeckTools.inScratchDirectory { url -> Int in
            returned = url
            #expect(FileManager.default.fileExists(atPath: url.path), "it has to exist first")
            try Data("deck".utf8).write(to: url.appendingPathComponent("presentation.lampdeck"))
            return 0
        }
        #expect(FileManager.default.fileExists(atPath: try #require(returned).path) == false)

        var thrown: URL?
        #expect(throws: Boom.self) {
            try LampDeckTools.inScratchDirectory { url -> Int in
                thrown = url
                try Data("deck".utf8).write(to: url.appendingPathComponent("presentation.lampdeck"))
                throw Boom()
            }
        }
        #expect(FileManager.default.fileExists(atPath: try #require(thrown).path) == false)
    }
}
