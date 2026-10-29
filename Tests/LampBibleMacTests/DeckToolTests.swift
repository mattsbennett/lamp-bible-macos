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
        notesAnchor: String? = nil
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
        return try! JSONSerialization.data(withJSONObject: deck, options: [.sortedKeys])
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
    @Test func buildingReturnsTheFilledInDeckAndItsReport() throws {
        let built = try LampDeckTools.build(deckJSON: deckJSON(), manuscript: nil)

        #expect(built.resolved)
        #expect(!built.deckJSON.isEmpty)
        let deck = try LampPresentationDeckStore.decodeUnvalidated(built.deckJSON)
        #expect(deck.slides.count == 2)
        #expect(deck.title == "Living Hope")
        let report = try JSONSerialization.jsonObject(with: built.reportJSON) as? [String: Any]
        #expect(report?["resolved"] as? Bool == true)
    }

    @Test func buildingTwiceChangesNothing() throws {
        let once = try LampDeckTools.build(deckJSON: deckJSON(), manuscript: nil)
        let twice = try LampDeckTools.build(deckJSON: once.deckJSON, manuscript: nil)

        #expect(once.deckJSON == twice.deckJSON)
    }

    /// An anchor the manuscript no longer holds is the one failure worth
    /// reporting as one: the slide's notes have stopped being the writing's.
    @Test func abrokenAnchorIsNotResolved() throws {
        let deck = deckJSON(
            notesSource: "manuscript",
            notesAnchor: "A sentence that is not in the manuscript at all."
        )

        let built = try LampDeckTools.build(
            deckJSON: deck,
            manuscript: "# Living Hope\n\nSomething else entirely was written here.\n"
        )

        #expect(built.resolved == false)
    }

    @Test func amatchingAnchorTakesItsNotesFromTheManuscript() throws {
        let anchor = "What does a living hope ask of us today?"
        let built = try LampDeckTools.build(
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
