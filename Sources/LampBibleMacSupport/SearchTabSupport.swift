import Foundation
import LampCore
import LampModuleKit

/// One search a window is keeping: its words and every filter around them.
///
/// The Search pane held all of this in `@SceneStorage`, which kept a search
/// alive while the window went to the reader and back — opening a result
/// moves the window off the pane, which took the search down with it. What
/// `@SceneStorage` does **not** do is survive a clean quit, so a search was
/// gone by the next launch; and being one bag of values per scene, there
/// could only ever be one search at a time. Both follow from where the state
/// lived, which is why tabs and remembering are one change.
///
/// Decoded defensively, field by field, for the reason `ReaderTab` is: a
/// field that cannot be read falls back rather than failing, because a failed
/// decode loses the whole window's tabs and not the one value. A `kind`
/// written by a later Lamp costs this tab its filter, no more.
public struct SearchTab: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID

    /// What the reader called this tab, or nil to be named after what it
    /// searches for. As `ReaderTab.name`: a named tab keeps its name while
    /// the search in it changes, which is the point of naming one.
    public var name: String?

    public var query: String
    public var kind: LampModuleKind?
    public var moduleID: String?

    /// The book range, as its own `rawValue`. The scope is the Search pane's
    /// own enum and belongs there rather than out here, and this is the
    /// spelling `@SceneStorage` kept it in, so nothing is lost by holding it
    /// as written: the pane reads it back and falls to its default.
    public var bookScopeRawValue: String

    public var strongsKey: String
    public var highlightColor: String
    public var devotionalDate: String
    public var devotionalTag: String
    public var devotionalCategory: String

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        query: String = "",
        kind: LampModuleKind? = nil,
        moduleID: String? = nil,
        bookScopeRawValue: String = "",
        strongsKey: String = "",
        highlightColor: String = "",
        devotionalDate: String = "",
        devotionalTag: String = "",
        devotionalCategory: String = ""
    ) {
        self.id = id
        self.name = name
        self.query = query
        self.kind = kind
        self.moduleID = moduleID
        self.bookScopeRawValue = bookScopeRawValue
        self.strongsKey = strongsKey
        self.highlightColor = highlightColor
        self.devotionalDate = devotionalDate
        self.devotionalTag = devotionalTag
        self.devotionalCategory = devotionalCategory
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, query, kind, moduleID, bookScopeRawValue
        case strongsKey, highlightColor
        case devotionalDate, devotionalTag, devotionalCategory
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // The id is the one field worth failing over: without it a tab cannot
        // be selected, closed or told from its neighbour.
        id = try values.decode(UUID.self, forKey: .id)
        name = (try? values.decodeIfPresent(String.self, forKey: .name)) ?? nil
        query = ((try? values.decodeIfPresent(String.self, forKey: .query)) ?? nil) ?? ""
        kind = (try? values.decodeIfPresent(LampModuleKind.self, forKey: .kind)) ?? nil
        moduleID = (try? values.decodeIfPresent(String.self, forKey: .moduleID)) ?? nil
        bookScopeRawValue = ((try? values.decodeIfPresent(String.self, forKey: .bookScopeRawValue)) ?? nil) ?? ""
        strongsKey = ((try? values.decodeIfPresent(String.self, forKey: .strongsKey)) ?? nil) ?? ""
        highlightColor = ((try? values.decodeIfPresent(String.self, forKey: .highlightColor)) ?? nil) ?? ""
        devotionalDate = ((try? values.decodeIfPresent(String.self, forKey: .devotionalDate)) ?? nil) ?? ""
        devotionalTag = ((try? values.decodeIfPresent(String.self, forKey: .devotionalTag)) ?? nil) ?? ""
        devotionalCategory = ((try? values.decodeIfPresent(String.self, forKey: .devotionalCategory)) ?? nil) ?? ""
    }

    /// Whether there is anything in this tab anyone would mind losing.
    ///
    /// Words, a key, a colour or a devotional facet obviously count. So does
    /// a kind or a module chosen with nothing typed yet: someone narrowing
    /// to Commentaries before searching has set that up on purpose, and a
    /// search arriving from the reader should open its own tab rather than
    /// take theirs (macos-9d's point, reviewing the palette's route). A book
    /// range alone is left out: it comes with a kind in practice, and a tab
    /// holding nothing but a range is not a setup worth protecting.
    public var isEmpty: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && strongsKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && highlightColor.isEmpty
            && devotionalDate.isEmpty && devotionalTag.isEmpty && devotionalCategory.isEmpty
            && kind == nil && moduleID == nil
    }

    /// Whether this tab is already showing the search `other` asks for.
    ///
    /// By what was asked for — the words, the key and the kind that came
    /// with them — and not by the filters narrowed down afterwards: a tab
    /// where "grace" has since been narrowed to one commentary is still the
    /// tab that search belongs in.
    public func isShowing(_ other: SearchTab) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
            == other.query.trimmingCharacters(in: .whitespacesAndNewlines)
            && strongsKey.trimmingCharacters(in: .whitespacesAndNewlines)
                == other.strongsKey.trimmingCharacters(in: .whitespacesAndNewlines)
            && kind == other.kind
            && !other.isEmpty
    }

    /// A name worth keeping, or nil, as `ReaderTab.trimmedName`.
    public static func trimmedName(_ name: String?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The searches one window is keeping, and which of them is shown.
public struct SearchTabCollection: Codable, Equatable, Sendable {
    public private(set) var tabs: [SearchTab]
    public private(set) var selectedID: UUID

    public init() {
        let tab = SearchTab()
        tabs = [tab]
        selectedID = tab.id
    }

    public init(tabs: [SearchTab], selectedID: UUID? = nil) {
        let kept = tabs.isEmpty ? [SearchTab()] : tabs
        self.tabs = kept
        self.selectedID = selectedID.flatMap { id in
            kept.contains(where: { $0.id == id }) ? id : nil
        } ?? kept[0].id
    }

    private enum CodingKeys: String, CodingKey { case tabs, selectedID }

    /// A collection is never empty and its selection always names a tab it
    /// has: a window with no tabs has nothing to draw, and a selection
    /// pointing at a closed tab shows nothing while the bar shows a rank.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = (try? values.decode([SearchTab].self, forKey: .tabs)) ?? []
        let selected = (try? values.decodeIfPresent(UUID.self, forKey: .selectedID)) ?? nil
        self.init(tabs: decoded, selectedID: selected)
    }

    public var selected: SearchTab {
        tabs.first { $0.id == selectedID } ?? tabs[0]
    }

    public mutating func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    public mutating func updateSelected(_ change: (inout SearchTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        change(&tabs[index])
    }

    public mutating func update(_ id: UUID, _ change: (inout SearchTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        change(&tabs[index])
    }

    /// Opens a tab after the selected one and shows it, so a new search sits
    /// beside the one it was opened from rather than at the far end.
    @discardableResult
    public mutating func open(_ tab: SearchTab = SearchTab()) -> UUID {
        let index = tabs.firstIndex { $0.id == selectedID }.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: index)
        selectedID = tab.id
        return tab.id
    }

    /// Moves a tab to `index` among the tabs, as a dragged tab lands where it
    /// is dropped. The open tab stays open: moving one is not choosing it.
    public mutating func move(_ id: UUID, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(max(index, 0), tabs.count))
    }

    /// Closes a tab, selecting its neighbour the way a window of tabs does:
    /// the one to its right, or the one to its left when it was last. Closing
    /// the only tab empties it instead, since the pane always shows one.
    public mutating func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard tabs.count > 1 else {
            tabs = [SearchTab()]
            selectedID = tabs[0].id
            return
        }
        tabs.remove(at: index)
        guard id == selectedID else { return }
        selectedID = tabs[min(index, tabs.count - 1)].id
    }

    /// The same search again in a tab of its own, named as its own tab: a
    /// copy is for taking one search in two directions.
    public mutating func duplicate(_ id: UUID) {
        guard let source = tabs.first(where: { $0.id == id }) else { return }
        var copy = source
        copy = SearchTab(
            name: source.name,
            query: source.query,
            kind: source.kind,
            moduleID: source.moduleID,
            bookScopeRawValue: source.bookScopeRawValue,
            strongsKey: source.strongsKey,
            highlightColor: source.highlightColor,
            devotionalDate: source.devotionalDate,
            devotionalTag: source.devotionalTag,
            devotionalCategory: source.devotionalCategory
        )
        open(copy)
    }

    /// Shows a search asked for from somewhere else — the reader's ⌘L, a
    /// word looked up, a Strong's key followed from the text.
    ///
    /// A tab already showing this very search is selected rather than
    /// opened again: asking for "grace" while "grace" is open, or following
    /// one key from two verses, should take you to it. Otherwise into the
    /// open tab when that one has nothing in it, and a tab of its own when
    /// it has — taking over a search someone is in the middle of would be
    /// worse than opening a tab, and a tab per lookup would pile them up.
    /// A reused tab keeps its own id and the name it was given: it is still
    /// that tab.
    ///
    /// Following a *chain* of different keys does get a tab each, on
    /// purpose: every key is a place you might want to go back to, and
    /// closing a tab is cheap (macos-9d, reviewing the palette's route).
    public mutating func show(_ tab: SearchTab) {
        if let existing = tabs.first(where: { $0.isShowing(tab) }) {
            selectedID = existing.id
            return
        }
        guard selected.isEmpty else {
            open(tab)
            return
        }
        let id = selectedID
        let name = selected.name
        update(id) { existing in
            existing = SearchTab(
                id: id,
                name: name,
                query: tab.query,
                kind: tab.kind,
                moduleID: tab.moduleID,
                bookScopeRawValue: tab.bookScopeRawValue,
                strongsKey: tab.strongsKey,
                highlightColor: tab.highlightColor,
                devotionalDate: tab.devotionalDate,
                devotionalTag: tab.devotionalTag,
                devotionalCategory: tab.devotionalCategory
            )
        }
    }

    public mutating func rename(_ id: UUID, to name: String?) {
        update(id) { $0.name = SearchTab.trimmedName(name) }
    }
}

/// Where a window's searches are kept between launches.
///
/// The same shape as `ReaderTabSessionStore`, and for the same reason: a
/// window's tabs have nowhere else to be remembered. Sessions are per window,
/// so a relaunch hands a window back the searches it was interrupted in,
/// while a second window opened beside one starts empty rather than mirroring
/// it — it was opened to look for something else.
public enum SearchTabSessionStore {
    private static let lastSessionKey = "search.tabs.lastSession"
    private static let sessionsKey = "search.tabs.sessions"
    /// As the reader keeps: far more windows than are ever open at once, so
    /// that sessions cannot pile up unread for as long as the app is
    /// installed.
    static let keptSessions = 24

    static func key(for session: UUID) -> String {
        "search.tabs.session.\(session.uuidString)"
    }

    /// The sessions searches have been saved under, most recently saved first.
    public static func sessions(defaults: UserDefaults = .standard) -> [UUID] {
        (defaults.stringArray(forKey: sessionsKey) ?? []).compactMap(UUID.init(uuidString:))
    }

    /// The searches for `session`.
    ///
    /// A session with none of its own picks up the last any window saved, but
    /// only when this window is resuming where the app left off. A second
    /// window beside one starts fresh, so that two windows do not share one
    /// set of tabs and save over each other — the fault the reader's sessions
    /// were built to fix.
    public static func load(
        session: UUID,
        resumingLastSession: Bool,
        defaults: UserDefaults = .standard
    ) -> SearchTabCollection {
        [
            defaults.data(forKey: key(for: session)),
            resumingLastSession ? defaults.data(forKey: lastSessionKey) : nil,
        ]
            .compactMap { $0 }
            .lazy
            .compactMap { try? JSONDecoder().decode(SearchTabCollection.self, from: $0) }
            .first ?? SearchTabCollection()
    }

    public static func save(
        _ collection: SearchTabCollection,
        session: UUID,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(collection) else { return }
        defaults.set(data, forKey: key(for: session))
        defaults.set(data, forKey: lastSessionKey)
        var sessions = [session.uuidString]
            + (defaults.stringArray(forKey: sessionsKey) ?? [])
                .filter { $0 != session.uuidString }
        for forgotten in sessions.dropFirst(keptSessions) {
            defaults.removeObject(forKey: "search.tabs.session.\(forgotten)")
        }
        sessions = Array(sessions.prefix(keptSessions))
        defaults.set(sessions, forKey: sessionsKey)
    }
}
