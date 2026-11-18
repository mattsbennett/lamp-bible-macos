import AppKit
import LampCore
import LampPresentationUI
import SwiftUI

/// What the Presentations section shows of the library's decks: those a
/// search and a filter leave, in the order chosen, and how many each filter
/// would show for the search as it stands, so a chip's count agrees with the
/// decks beneath it.
struct PresentationsShelf: Equatable {
    struct Deck: Equatable, Identifiable {
        let id: String
        let title: String
        /// The writing it was built from, if any, and that writing's title
        /// where the library still has it.
        let writingID: String?
        let writingTitle: String?
        let modified: Date
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case fromWriting = "From Writing"
        case standalone = "Standalone"
        var id: Self { self }

        func includes(_ deck: Deck) -> Bool {
            switch self {
            case .all: true
            case .fromWriting: deck.writingID != nil
            case .standalone: deck.writingID == nil
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case recent = "Recently Changed"
        case title = "Title"
        var id: Self { self }
    }

    var decks: [Deck]

    /// Whether a deck's title, or its writing's, holds the search's words.
    static func matches(_ deck: Deck, query: String) -> Bool {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty
            || deck.title.localizedCaseInsensitiveContains(words)
            || deck.writingTitle?.localizedCaseInsensitiveContains(words) == true
    }

    func count(of filter: Filter, query: String) -> Int {
        decks.filter { filter.includes($0) && Self.matches($0, query: query) }.count
    }

    func shown(filter: Filter, sort: Sort, query: String) -> [Deck] {
        Self.sorted(decks.filter { filter.includes($0) && Self.matches($0, query: query) }, by: sort)
    }

    /// Most recently changed first, or by title; ties by title, so the order
    /// is the same every time.
    static func sorted(_ decks: [Deck], by sort: Sort) -> [Deck] {
        decks.sorted { a, b in
            if sort == .recent, a.modified != b.modified { return a.modified > b.modified }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}

extension LampPresentationDeckStore {
    /// When a deck's file was last written: what "recently changed" means
    /// here, since a deck records no date of its own.
    func modificationDate(ofDeck id: String) -> Date {
        let url = decksDirectoryURL.appendingPathComponent("\(id).lampdeck")
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? .distantPast
    }
}

/// The library's decks, as Books shows its shelf: each by its first slide,
/// its title, how long it is and when it was last changed, and the writing
/// it was built from. A deck opens in Slide Studio's own window, where it is
/// edited beside what it is built from and presented full screen.
///
/// Before this, a deck was reached from its writing's More menu, by name in
/// the palette, or from the menu in Slide Studio's sidebar heading; a deck
/// with no writing had no list at all.
struct PresentationsLibraryView: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var inbox = SlideStudioInbox.shared
    @State private var entries: [Entry] = []
    @State private var hasLoaded = false
    @State private var query = ""
    @State private var filter: PresentationsShelf.Filter = .all
    @AppStorage("presentations.sortOrder") private var sortRawValue = PresentationsShelf.Sort.recent.rawValue
    @AppStorage("presentations.layout") private var layoutRawValue = Layout.grid.rawValue
    @Environment(\.colorScheme) private var colorScheme
    /// Shows a deck's writing in Writing.
    let openWriting: (String) -> Void

    struct Entry: Identifiable, Equatable {
        let deck: LampPresentationDeck
        let modified: Date
        var id: String { deck.id }
    }

    /// Covers to recognise a deck by, or rows to scan many.
    enum Layout: String, CaseIterable, Identifiable {
        case grid = "Grid"
        case list = "List"
        var id: Self { self }
        var systemImage: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
    }

    private var sort: PresentationsShelf.Sort { PresentationsShelf.Sort(rawValue: sortRawValue) ?? .recent }
    private var layout: Layout { Layout(rawValue: layoutRawValue) ?? .grid }

    private var store: LampPresentationDeckStore {
        LampPresentationDeckStore(rootURL: model.library.rootURL)
    }

    private var shelf: PresentationsShelf {
        PresentationsShelf(decks: entries.map { entry in
            let writingID = entry.deck.source?.kind == .devotional ? entry.deck.source?.id : nil
            return PresentationsShelf.Deck(
                id: entry.id,
                title: entry.deck.title,
                writingID: writingID,
                writingTitle: writingTitle(of: entry.deck),
                modified: entry.modified
            )
        })
    }

    private var shown: [Entry] {
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return shelf.shown(filter: filter, sort: sort, query: query).compactMap { byID[$0.id] }
    }

    private func writingTitle(of deck: LampPresentationDeck) -> String? {
        guard deck.source?.kind == .devotional, let id = deck.source?.id else { return nil }
        return model.devotionals.first { $0.id == id }?.title
    }

    var body: some View {
        Group {
            if hasLoaded, entries.isEmpty {
                LampEmptyState(
                    systemImage: "rectangle.stack",
                    caption: "Presentations",
                    title: "No Presentations Yet",
                    message: "Decks you build from your writing, or begin here, are kept here, ready to edit or present."
                ) {
                    Button("New Deck", systemImage: "plus", action: newDeck)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        filterChips
                        if shown.isEmpty, hasLoaded {
                            ContentUnavailableView.search(text: query)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                        switch layout {
                        case .grid:
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 24, alignment: .top)],
                                alignment: .leading,
                                spacing: 28
                            ) {
                                ForEach(shown) { entry in
                                    card(entry)
                                }
                            }
                        case .list:
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(shown) { entry in
                                    row(entry)
                                    Divider()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                }
            }
        }
        .navigationTitle("Presentations")
        .searchable(text: $query, placement: .toolbar, prompt: "Find a deck")
        .toolbar {
            ToolbarItemGroup {
                Picker(selection: $layoutRawValue) {
                    ForEach(Layout.allCases) { layout in
                        Label(layout.rawValue, systemImage: layout.systemImage).tag(layout.rawValue)
                    }
                } label: {
                    Label("View", systemImage: layout.systemImage)
                }
                .pickerStyle(.segmented)
                .help("Show decks as covers or as a list")
                Menu {
                    Picker("Sort By", selection: $sortRawValue) {
                        ForEach(PresentationsShelf.Sort.allCases) { sort in
                            Text(sort.rawValue).tag(sort.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .fittingToolbarLabel()
                .help("Sort decks")
                Button(action: newDeck) {
                    Label("New Deck", systemImage: "plus")
                }
                .fittingToolbarLabel()
                .help("Start a new presentation deck")
            }
        }
        .toolbarLabelsFit(from: 560)
        // Read again whenever a deck is made, renamed or saved anywhere.
        .task(id: inbox.decks) { await load() }
        .onAppear { inbox.refreshDecks(rootURL: model.library.rootURL, force: true) }
    }

    private var filterChips: some View {
        let shelf = shelf
        return HStack(spacing: 8) {
            ForEach(PresentationsShelf.Filter.allCases) { choice in
                // For the search as it stands: the count agrees with the
                // decks beneath it.
                let count = shelf.count(of: choice, query: query)
                Button {
                    filter = choice
                } label: {
                    HStack(spacing: 5) {
                        Text(choice.rawValue)
                        Text("\(count)").foregroundStyle(Color.lampSecondaryText).monospacedDigit()
                    }
                }
                .buttonStyle(.plain)
                .lampFilterChip(isChosen: filter == choice, compact: true)
            }
        }
    }

    private func card(_ entry: Entry) -> some View {
        let deck = entry.deck
        let first = deck.slides.first { !$0.isHidden } ?? deck.slides.first
        let writing = writingTitle(of: deck)
        let count = deck.slides.filter { !$0.isHidden }.count
        return Button {
            open(deck)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if let first {
                        SlideThumbnail(slide: first, style: LampPresentationSlideStyle(deck: deck), store: store)
                            .equatable()
                    } else {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.lampTileFill)
                            .aspectRatio(16 / 9, contentMode: .fit)
                    }
                }
                // At their own brightness in dark too: dimmed, the covers read
                // as washed out and harder still to tell apart.
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.lampCardStroke))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.12), radius: 6, y: 3)
                Text(deck.title.isEmpty ? "Untitled Presentation" : deck.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(count) \(count == 1 ? "slide" : "slides") · \(entry.modified.formatted(.relative(presentation: .named)))")
                    .font(.callout)
                    .foregroundStyle(Color.lampSecondaryText)
                if let writing {
                    Label(writing, systemImage: "sun.max")
                        .font(.callout)
                        .foregroundStyle(Color.lampSecondaryText)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(deck.title) in Slide Studio")
        .contextMenu {
            Button("Open in Slide Studio", systemImage: "rectangle.stack") { open(deck) }
            if writing != nil, let id = deck.source?.id {
                Button("Show Writing", systemImage: "sun.max") { openWriting(id) }
            }
        }
    }

    /// A deck as a row: a small cover, then its title, length, date and
    /// writing, for scanning many.
    private func row(_ entry: Entry) -> some View {
        let deck = entry.deck
        let first = deck.slides.first { !$0.isHidden } ?? deck.slides.first
        let writing = writingTitle(of: deck)
        let count = deck.slides.filter { !$0.isHidden }.count
        return Button {
            open(deck)
        } label: {
            HStack(alignment: .center, spacing: 14) {
                Group {
                    if let first {
                        SlideThumbnail(slide: first, style: LampPresentationSlideStyle(deck: deck), store: store)
                            .equatable()
                    } else {
                        RoundedRectangle(cornerRadius: 5).fill(Color.lampTileFill).aspectRatio(16 / 9, contentMode: .fit)
                    }
                }
                .frame(width: 112)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.lampCardStroke))
                VStack(alignment: .leading, spacing: 3) {
                    Text(deck.title.isEmpty ? "Untitled Presentation" : deck.title)
                        .font(.headline)
                        .lineLimit(1)
                    // The writing beside its length and date, under the title,
                    // where the eye already is; at the row's far end it was
                    // a long way from the deck it belongs to.
                    HStack(spacing: 10) {
                        Text("\(count) \(count == 1 ? "slide" : "slides") · \(entry.modified.formatted(.relative(presentation: .named)))")
                        if let writing {
                            Label(writing, systemImage: "sun.max")
                                .lineLimit(1)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(Color.lampSecondaryText)
                }
                Spacer(minLength: 12)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(deck.title) in Slide Studio")
        .contextMenu {
            Button("Open in Slide Studio", systemImage: "rectangle.stack") { open(deck) }
            if writing != nil, let id = deck.source?.id {
                Button("Show Writing", systemImage: "sun.max") { openWriting(id) }
            }
        }
    }

    private func open(_ deck: LampPresentationDeck) {
        openWindow(id: "slide-studio", value: SlideStudioRequest(deckID: deck.id))
    }

    private func newDeck() {
        openWindow(id: "slide-studio", value: SlideStudioRequest(newDeckID: UUID().uuidString))
    }

    private func load() async {
        let store = store
        let found: [Entry] = await Task.detached(priority: .userInitiated) {
            let decks = (try? store.decks()) ?? []
            return decks.map { Entry(deck: $0, modified: store.modificationDate(ofDeck: $0.id)) }
        }.value
        if found != entries { entries = found }
        hasLoaded = true
    }
}


extension Notification.Name {
    /// Shows the library window's Presentations section: Slide Studio's way
    /// back to every deck.
    static let lampShowPresentations = Notification.Name("lampShowPresentations")
}
