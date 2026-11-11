import Foundation
import LampCore
import Testing
@testable import LampBibleMacSupport

/// The Search pane's tabs, and whether they come back.
///
/// The pane's filters used to live in `@SceneStorage`, which a clean quit
/// wipes, so a search never saw the next launch; and one bag of values per
/// scene meant one search at a time. These hold the store that replaced it.
struct SearchTabTests {
    private func defaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "search-tabs-\(name)")!
        defaults.removePersistentDomain(forName: "search-tabs-\(name)")
        return defaults
    }

    /// Every field set to something of its own, so a field dropped on the
    /// way to disk or into a copy fails rather than passing unnoticed. A
    /// Codex review pointed out that the first round trip set three.
    private func fullyFilledTab(name: String? = "Named") -> SearchTab {
        SearchTab(
            name: name,
            query: "grace",
            kind: .commentary,
            moduleID: "nic",
            bookScopeRawValue: "New Testament",
            strongsKey: "G5485",
            highlightColor: "#ffcc00",
            devotionalDate: "12-25",
            devotionalTag: "advent",
            devotionalCategory: "writing"
        )
    }

    private func expectSameSearch(_ a: SearchTab, _ b: SearchTab, _ note: String) {
        #expect(a.name == b.name, "name: \(note)")
        #expect(a.query == b.query, "query: \(note)")
        #expect(a.kind == b.kind, "kind: \(note)")
        #expect(a.moduleID == b.moduleID, "moduleID: \(note)")
        #expect(a.bookScopeRawValue == b.bookScopeRawValue, "bookScope: \(note)")
        #expect(a.strongsKey == b.strongsKey, "strongsKey: \(note)")
        #expect(a.highlightColor == b.highlightColor, "highlightColor: \(note)")
        #expect(a.devotionalDate == b.devotionalDate, "devotionalDate: \(note)")
        #expect(a.devotionalTag == b.devotionalTag, "devotionalTag: \(note)")
        #expect(a.devotionalCategory == b.devotionalCategory, "devotionalCategory: \(note)")
    }

    @Test func aCollectionAlwaysHasATabAndASelectionThatNamesOne() {
        #expect(SearchTabCollection().tabs.count == 1)

        // No tabs at all is not a state the pane can draw.
        let empty = SearchTabCollection(tabs: [])
        #expect(empty.tabs.count == 1)
        #expect(empty.selectedID == empty.tabs[0].id)

        // A selection naming a tab that is not there would show nothing
        // while the bar showed a rank.
        let first = SearchTab(query: "grace")
        let adrift = SearchTabCollection(tabs: [first], selectedID: UUID())
        #expect(adrift.selectedID == first.id)
    }

    @Test func aNewTabOpensBesideTheOneItCameFromAndIsShown() {
        var tabs = SearchTabCollection(tabs: [
            SearchTab(query: "first"), SearchTab(query: "second"), SearchTab(query: "third"),
        ])
        tabs.select(tabs.tabs[0].id)
        let opened = tabs.open(SearchTab(query: "new"))
        #expect(tabs.selectedID == opened)
        #expect(tabs.tabs.map(\.query) == ["first", "new", "second", "third"])
    }

    @Test func closingATabSelectsItsNeighbour() {
        var tabs = SearchTabCollection(tabs: [
            SearchTab(query: "a"), SearchTab(query: "b"), SearchTab(query: "c"),
        ])
        tabs.select(tabs.tabs[1].id)
        tabs.close(tabs.tabs[1].id)
        // The one to its right, as a window of tabs does.
        #expect(tabs.selected.query == "c")

        tabs.select(tabs.tabs[1].id)
        tabs.close(tabs.tabs[1].id)
        // Last in the rank, so the one to its left.
        #expect(tabs.selected.query == "a")

        // Closing the only tab empties it: the pane always shows one.
        tabs.close(tabs.tabs[0].id)
        #expect(tabs.tabs.count == 1)
        #expect(tabs.selected.query.isEmpty)
    }

    @Test func closingAnUnselectedTabLeavesTheSelectionAlone() {
        var tabs = SearchTabCollection(tabs: [
            SearchTab(query: "a"), SearchTab(query: "b"), SearchTab(query: "c"),
        ])
        tabs.select(tabs.tabs[2].id)
        tabs.close(tabs.tabs[0].id)
        #expect(tabs.selected.query == "c")
    }

    @Test func aDuplicateIsItsOwnTabWithTheSameSearch() {
        var tabs = SearchTabCollection(tabs: [fullyFilledTab(name: "Mine")])
        let original = tabs.tabs[0]
        tabs.duplicate(original.id)
        #expect(tabs.tabs.count == 2)
        let copy = tabs.selected
        #expect(copy.id != original.id)
        expectSameSearch(copy, fullyFilledTab(name: "Mine"), "in a duplicate")
    }

    @Test func aBlankNameIsNoName() {
        var tabs = SearchTabCollection()
        let id = tabs.selectedID
        tabs.rename(id, to: "  Kept  ")
        #expect(tabs.selected.name == "Kept")
        tabs.rename(id, to: "   ")
        #expect(tabs.selected.name == nil)
    }

    @Test func tabsComeBackForTheSameWindow() {
        let store = defaults()
        let session = UUID()
        var saved = SearchTabCollection(tabs: [SearchTab(query: "first"), fullyFilledTab()])
        saved.select(saved.tabs[1].id)
        SearchTabSessionStore.save(saved, session: session, defaults: store)

        let loaded = SearchTabSessionStore.load(
            session: session, resumingLastSession: false, defaults: store
        )
        #expect(loaded == saved)
        #expect(loaded.selectedID == saved.selectedID)
        expectSameSearch(loaded.selected, fullyFilledTab(), "after a round trip to disk")
    }

    @Test func aWindowResumingTakesTheLastTabsAndASecondWindowStartsFresh() {
        let store = defaults()
        let first = UUID()
        SearchTabSessionStore.save(
            SearchTabCollection(tabs: [SearchTab(query: "grace")]), session: first, defaults: store
        )

        // A relaunch: a session of its own has nothing, so it picks up where
        // the app left off.
        let resumed = SearchTabSessionStore.load(
            session: UUID(), resumingLastSession: true, defaults: store
        )
        #expect(resumed.tabs.map(\.query) == ["grace"])

        // A second window beside one starts empty rather than mirroring it,
        // which is how two windows came to share one set and save over each
        // other in the reader.
        let beside = SearchTabSessionStore.load(
            session: UUID(), resumingLastSession: false, defaults: store
        )
        #expect(beside.tabs.count == 1)
        #expect(beside.selected.isEmpty)
    }

    @Test func sessionsAreRememberedMostRecentFirstAndCapped() {
        let store = defaults()
        var sessions: [UUID] = []
        for index in 0..<(SearchTabSessionStore.keptSessions + 3) {
            let session = UUID()
            sessions.append(session)
            SearchTabSessionStore.save(
                SearchTabCollection(tabs: [SearchTab(query: "q\(index)")]),
                session: session, defaults: store
            )
        }
        let kept = SearchTabSessionStore.sessions(defaults: store)
        #expect(kept.count == SearchTabSessionStore.keptSessions)
        #expect(kept.first == sessions.last)
        // The ones dropped off the end take their tabs with them, so sessions
        // cannot pile up for as long as the app is installed.
        for forgotten in sessions.prefix(3) {
            #expect(store.data(forKey: SearchTabSessionStore.key(for: forgotten)) == nil)
        }
    }

    @Test func aTabSurvivesAFieldItCannotRead() throws {
        // A kind written by a later Lamp, in a tab otherwise readable. The
        // whole window's tabs are in one value, so failing the decode would
        // lose every tab over one filter.
        let json = """
        {"tabs":[{"id":"\(UUID().uuidString)","query":"grace","kind":"hymnal",
        "strongsKey":"G5485"}],"selectedID":null}
        """
        let decoded = try JSONDecoder().decode(SearchTabCollection.self, from: Data(json.utf8))
        #expect(decoded.tabs.count == 1)
        #expect(decoded.selected.query == "grace")
        #expect(decoded.selected.strongsKey == "G5485")
        #expect(decoded.selected.kind == nil)
    }

    @Test func aTabWithNoIDIsNotATab() throws {
        // The one field worth failing over: without an id a tab cannot be
        // selected, closed, or told from its neighbour. The collection comes
        // back empty-but-usable rather than wrong.
        let json = #"{"tabs":[{"query":"grace"}],"selectedID":null}"#
        let decoded = try JSONDecoder().decode(SearchTabCollection.self, from: Data(json.utf8))
        #expect(decoded.tabs.count == 1)
        #expect(decoded.selected.isEmpty)
    }

    @Test func anEmptyTabIsTheOneWorthReusing() {
        #expect(SearchTab().isEmpty)
        #expect(SearchTab(query: "   ").isEmpty)
        // A kind alone is not a search: it is the filter a new tab opens with
        // when one was chosen in the pane.
        #expect(SearchTab(kind: .commentary).isEmpty)
        #expect(!SearchTab(query: "grace").isEmpty)
        #expect(!SearchTab(strongsKey: "G5485").isEmpty)
        #expect(!SearchTab(highlightColor: "#ffcc00").isEmpty)
        #expect(!SearchTab(devotionalTag: "advent").isEmpty)
    }

    /// A search asked for from the reader — ⌘L, a word looked up, a key
    /// followed — is shown without taking over a search in progress. These
    /// used to be written to the scene storage the pane has stopped reading,
    /// so every one of them was silently dropped until a Codex review found
    /// it.
    @Test func aSearchAskedForElsewhereReusesAnEmptyTabAndOtherwiseOpensOne() {
        var tabs = SearchTabCollection()
        let empty = tabs.selectedID
        tabs.show(SearchTab(query: "grace"))
        #expect(tabs.tabs.count == 1, "an empty tab is the one worth reusing")
        #expect(tabs.selectedID == empty, "a reused tab is still that tab")
        #expect(tabs.selected.query == "grace")

        // Now it holds a search, so the next one gets a tab of its own.
        tabs.show(SearchTab(query: "faith", kind: .translation, strongsKey: "G4102"))
        #expect(tabs.tabs.count == 2)
        #expect(tabs.selected.query == "faith")
        #expect(tabs.selected.strongsKey == "G4102")
        #expect(tabs.selected.kind == .translation)
        // And the search it was opened from is untouched.
        #expect(tabs.tabs[0].query == "grace")
    }

    @Test func aReusedTabKeepsItsNameAndLosesTheFiltersItHadNone() {
        var tabs = SearchTabCollection(tabs: [SearchTab(name: "Kept", kind: .commentary)])
        let id = tabs.selectedID
        // A kind alone is not a search, so this tab is still the empty one.
        tabs.show(SearchTab(query: "grace", kind: .translation))
        #expect(tabs.tabs.count == 1)
        #expect(tabs.selectedID == id)
        #expect(tabs.selected.name == "Kept")
        #expect(tabs.selected.query == "grace")
        // The kind came with the search, replacing the one that was set.
        #expect(tabs.selected.kind == .translation)
    }
}
