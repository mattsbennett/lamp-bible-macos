import Foundation
import LampCore
import Testing
@testable import LampBibleMacSupport

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

/// Spotting a Strong's key typed into the search box.
///
/// The rule lives in core (`LampStrongsKey.typedKey`) so that the Mac, iOS
/// and the agent tools agree on it. These stay because they pin what the
/// Mac's search box depends on: loosen the rule and an ordinary search for
/// "Genesis" would be hijacked into a Strong's analysis.
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
        #expect(LampStrongsKey.typedKey(typed) == expected)
    }

    /// The costly mistake: a word that happens to start with H or G being
    /// taken for a key would hijack an ordinary search.
    @Test(arguments: [
        "Genesis", "God", "grace", "Hebrews", "Hebrews 1", "hope",
        "holy", "H", "G", "", "   ", "John 1:1", "7225", "G 26", "G26x9",
    ])
    func wordsAreNotMistakenForKeys(typed: String) {
        #expect(
            LampStrongsKey.typedKey(typed) == nil,
            "\(typed.debugDescription) must stay an ordinary search"
        )
    }
}

/// Carrying the Mac's search history into core's.
struct SearchHistoryMigrationTests {
    @Test func theolderEntriesAreCarriedOverOnce() throws {
        // Written out as the old Mac wrote it. Nothing encodes this shape
        // any more, so the fixture cannot borrow a writer for it.
        let old = Data("""
        [
          {"query": "grace", "kind": "translation", "moduleID": "ASVs",
           "searchedAt": 782012345.0},
          {"query": "hope", "searchedAt": 782012300.0}
        ]
        """.utf8)

        let history = LampSearchHistoryMigration.history(from: old)
        #expect(history.entries.map(\.query) == ["grace", "hope"])
        #expect(history.entries.first?.kinds == [.translation])
        #expect(history.entries.first?.moduleIDs == ["ASVs"])
        #expect(history.entries.last?.kinds == nil, "an entry with no kind keeps none")
    }

    /// Core's format wins where it is present. Reading the old shape over a
    /// real history would replace it with whatever the old decode made of
    /// the bytes.
    @Test func acurrentHistoryIsNotReinterpreted() throws {
        var history = LampSearchHistory()
        history.record(.init(query: "mercy", kinds: [.translation]), resultCount: 3)
        let data = history.encoded()

        let read = LampSearchHistoryMigration.history(from: data)
        #expect(read.entries.map(\.query) == ["mercy"])
        #expect(read.entries.first?.kinds == [.translation])
    }

    @Test func nothingSavedGivesAnEmptyHistory() {
        #expect(LampSearchHistoryMigration.history(from: Data()).entries.isEmpty)
        #expect(
            LampSearchHistoryMigration.history(from: Data("not json".utf8)).entries.isEmpty,
            "unreadable bytes must not throw or invent entries"
        )
    }
}

/// What leaves the app as words rather than markup.
struct SearchSnippetTests {
    /// Core wraps every matched term, so a copied result would otherwise
    /// paste tags into someone's notes.
    @Test func copiedTextCarriesNoMarkup() {
        let snippet = "In the beginning was the <mark>Word</mark>, and the "
            + "<mark>Word</mark> was with God."
        let plain = LampSearchSnippet.plainText(snippet)

        #expect(plain == "In the beginning was the Word, and the Word was with God.")
        #expect(!plain.contains("<"))
    }

    @Test func asnippetWithNoMatchesIsUnchanged() {
        let snippet = "And God said, Let there be light."
        #expect(LampSearchSnippet.plainText(snippet) == snippet)
        #expect(LampSearchSnippet.plainText("") == "")
    }

    /// Scripture a translation renders with its own angle brackets must not
    /// lose them: only the two mark tags go.
    @Test func otherAngleBracketsSurvive() {
        let snippet = "a <note> and a <mark>match</mark>"
        #expect(LampSearchSnippet.plainText(snippet) == "a <note> and a match")
    }
}

/// Reading the item out of a search result's identifier.
struct SearchResultIdentityTests {
    @Test func theentryIsWhatFollowsTheKindAndModule() {
        #expect(
            LampSearchResultIdentity.entryID(
                in: "devotional:personal-devotionals:living-hope",
                kind: "devotional", moduleID: "personal-devotionals"
            ) == "living-hope"
        )
    }

    /// An entry id may itself contain colons — a writing named by a path —
    /// so only the first two segments are the
    /// prefix and the rest is the entry, whole.
    @Test func anentryKeepsItsOwnColons() {
        #expect(
            LampSearchResultIdentity.entryID(
                in: "devotional:mod:2026-01-01:morning",
                kind: "devotional", moduleID: "mod"
            ) == "2026-01-01:morning"
        )
    }

    /// Guessing would send the reader to the wrong writing, so a shape that
    /// does not match gives nothing.
    @Test func amismatchedShapeGivesNothing() {
        #expect(
            LampSearchResultIdentity.entryID(
                in: "plan:daily-light", kind: "devotional", moduleID: "mod"
            ) == nil
        )
        #expect(
            LampSearchResultIdentity.entryID(
                in: "devotional:other:x", kind: "devotional", moduleID: "mod"
            ) == nil
        )
        #expect(
            LampSearchResultIdentity.entryID(
                in: "devotional:mod:", kind: "devotional", moduleID: "mod"
            ) == nil,
            "a prefix with nothing after it names no item"
        )
    }
}
