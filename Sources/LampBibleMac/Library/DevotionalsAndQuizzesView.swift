import AppKit
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampModuleKit
import SwiftUI
import UniformTypeIdentifiers

private enum WritingSortOrder: String, CaseIterable, Identifiable {
    case titleAscending = "Title (A–Z)"
    case titleDescending = "Title (Z–A)"
    case dateNewest = "Date (Newest First)"
    case dateOldest = "Date (Oldest First)"
    case recentlyModified = "Recently Modified"
    case recentlyCreated = "Recently Created"

    var id: Self { self }
}

private enum WritingGroupBy: String, CaseIterable, Identifiable {
    case none = "None"
    case category = "Category"
    case collection = "Collection"
    case series = "Series"

    var id: Self { self }
}

/// Each writing's row snippet and reading statistics, worked out once for the
/// writing as it stands. Both read the whole text, and for writing made on the
/// phone that first means turning its blocks into Markdown, while the list
/// draws every row again each time it is shown.
///
/// One for the app rather than one per appearance of the list: the list is
/// rebuilt every time Writing is chosen in the sidebar, and its rows haven't
/// changed. Each entry is checked against the writing it was made from.
@MainActor
private final class WritingRowSummaries {
    static let shared = WritingRowSummaries()

    private struct Entry {
        let content: String
        let contentJSON: String?
        let summary: String?
        let snippet: String?
        let statistics: WritingStatistics
    }

    private var entries: [String: Entry] = [:]

    func snippet(for devotional: LampDevotional) -> String? {
        entry(for: devotional).snippet
    }

    func statistics(for devotional: LampDevotional) -> WritingStatistics {
        entry(for: devotional).statistics
    }

    private func entry(for devotional: LampDevotional) -> Entry {
        if let entry = entries[devotional.id],
           entry.content == devotional.content,
           entry.contentJSON == devotional.contentJSON,
           entry.summary == devotional.summary {
            // Equal but freshly loaded text is a second copy of it: keep the
            // library's instead, so the cache never holds text of its own and
            // the next comparison is the quick one between identical strings.
            let current = Entry(
                content: devotional.content,
                contentJSON: devotional.contentJSON,
                summary: devotional.summary,
                snippet: entry.snippet,
                statistics: entry.statistics
            )
            entries[devotional.id] = current
            return current
        }
        let source = devotional.summary?.isEmpty == false ? devotional.summary! : devotional.content
        let snippet = WritingStatistics.snippet(from: source, limit: 120)
        let entry = Entry(
            content: devotional.content,
            contentJSON: devotional.contentJSON,
            summary: devotional.summary,
            snippet: snippet.isEmpty ? nil : snippet,
            statistics: WritingStatistics.measuring(markdown: devotional.displayMarkdown)
        )
        entries[devotional.id] = entry
        return entry
    }
}

private struct WritingListSection: Identifiable {
    let id: String
    let title: String?
    let devotionals: [LampDevotional]
}

struct DevotionalPresentationRequest: Codable, Hashable {
    let devotionalID: String
}

enum LinkedPresentationDeckLookup {
    static let systemImage = "rectangle.stack.badge.play"

    static func groupedByDevotional(rootURL: URL) throws -> [String: [LampPresentationDeck]] {
        var result: [String: [LampPresentationDeck]] = [:]
        for deck in try LampPresentationDeckStore(rootURL: rootURL).decks() {
            guard deck.source?.kind == .devotional,
                  let devotionalID = deck.source?.id else { continue }
            result[devotionalID, default: []].append(deck)
        }
        return result
    }

    static func decks(rootURL: URL, devotionalID: String) throws -> [LampPresentationDeck] {
        try groupedByDevotional(rootURL: rootURL)[devotionalID] ?? []
    }
}

struct DevotionalsView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("devotional.fontSize")
    private var devotionalFontSize = LampTextScale.writingReadingText.defaultValue
    @AppStorage("devotional.lineSpacing")
    private var devotionalLineSpacing = LampTextScale.writingReadingLineSpacing.defaultValue
    @AppStorage("devotional.typeface")
    private var devotionalTypeface = ProseTypeface.readerDefault
    @State private var selection: String?
    @AppStorage("writing.showsList") private var showsWritingList = true
    /// The list's width, as the reader dragged it.
    @State private var preferredWritingListWidth = 260.0
    @State private var query = ""
    @State private var categoryFilter: String?
    @State private var moduleFilter: String?
    @AppStorage(LampReadingMode.defaultsKey) private var readingModeRawValue = LampReadingMode.silent.rawValue
    @AppStorage(LampReadingMode.silent.wordsPerMinuteKey)
    private var silentWordsPerMinute = LampReadingMode.silent.defaultWordsPerMinute
    @AppStorage(LampReadingMode.aloud.wordsPerMinuteKey)
    private var aloudWordsPerMinute = LampReadingMode.aloud.defaultWordsPerMinute
    @AppStorage("writing.sortOrder") private var sortOrderRawValue = WritingSortOrder.titleAscending.rawValue
    @AppStorage("writing.groupBy") private var groupByRawValue = WritingGroupBy.none.rawValue
    @State private var devotionalPendingDeletion: LampDevotional?
    @State private var footnoteHighlight = DevotionalFootnoteHighlight()
    /// Find in the preview. The preview cannot be written to, so the bar it
    /// puts up offers Find and no Replace.
    @State private var previewFind = WritingFindController()
    @State private var previewFinder = WritingPreviewFinder()
    @State private var exportedURL: URL?
    @State private var presentationDecksByDevotionalID: [String: [LampPresentationDeck]] = [:]
    private let rowSummaries = WritingRowSummaries.shared

    /// A writing a search result asked for. Cleared once taken, so coming
    /// back to this section later does not jump to it again.
    @Binding var initialDevotionalID: String?
    let showImporter: () -> Void
    let openReference: (Int) -> Void

    /// Selects the writing a search result named, and forgets the request.
    ///
    /// Taken rather than left standing: without clearing it, returning to
    /// this section days later would jump back to the same writing.
    private func takeRequestedDevotional() {
        guard let id = initialDevotionalID else { return }
        selection = id
        initialDevotionalID = nil
    }

    private var filteredDevotionals: [LampDevotional] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.devotionals.filter { devotional in
            guard categoryFilter == nil
                    || LampWritingCategory.foldedKey(devotional.category)
                        == LampWritingCategory.foldedKey(categoryFilter),
                  moduleFilter == nil || devotional.moduleID == moduleFilter else { return false }
            guard !trimmedQuery.isEmpty else { return true }
            return [
                devotional.title,
                devotional.subtitle,
                devotional.author,
                devotional.seriesName,
                devotional.summary,
                devotional.content,
            ]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(trimmedQuery) }
            || devotional.tags.contains { $0.localizedCaseInsensitiveContains(trimmedQuery) }
        }
        .sorted(by: devotionalPrecedes)
    }

    var body: some View {
        let visibleDevotionals = filteredDevotionals
        // Strictly what the list says is selected. Falling back to the first entry
        // put a document in the preview that no row was highlighting, and pointed
        // the Present button at it too.
        let selectedDevotional = visibleDevotionals.first { $0.id == selection }
        let listSections = writingListSections(from: visibleDevotionals)

        return Group {
            if model.devotionals.isEmpty {
                ContentUnavailableView {
                    Label("No Writing", systemImage: "sun.max")
                } description: {
                    Text("Create your own writing, install a devotional .lamp module, or build one in Module Studio.")
                } actions: {
                    HStack {
                        Button("New Writing") { beginEditing(nil) }
                            .buttonStyle(.borderedProminent)
                        Button("Install Module…", action: showImporter)
                    }
                }
            } else if visibleDevotionals.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                // Columns as Books lays them out: a list of a width the
                // reader set, kept, beside the page. In an HSplitView the list
                // shrank when a click on its empty space cleared the
                // selection and the page beside it changed.
                HStack(spacing: 0) {
                    if showsWritingList {
                        writingList(listSections)
                            .frame(width: writingListWidth)
                        LampColumnResizeHandle(
                            preferredWidth: $preferredWritingListWidth,
                            displayedWidth: Double(writingListWidth),
                            minimumWidth: 220,
                            maximumWidth: 320,
                            label: "Resize Writing List"
                        )
                    }

                    if let devotional = selectedDevotional {
                        devotionalDetail(devotional)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(2)
                    } else {
                        // There are results — none is chosen. A "no results"
                        // message here would contradict the list beside it.
                        ContentUnavailableView(
                            "No Writing Selected",
                            systemImage: "sun.max",
                            description: Text("Choose an entry in the list to read it.")
                        )
                        // Claims the pane the way the detail view does.
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(2)
                    }
                }
            }
        }
        .navigationTitle("Writing")
        .searchable(text: $query, prompt: "Search writing")
        .toolbar {
            ToolbarItemGroup {
                if showsWritingList {
                    filterMenu
                    arrangeMenu
                }
                // As Books' list hides, so this one does, to read wide.
                Button(
                    showsWritingList ? "Hide Writing List" : "Show Writing List",
                    systemImage: "sidebar.squares.left"
                ) {
                    showsWritingList.toggle()
                }
                .labelStyle(.iconOnly)
                .help(showsWritingList ? "Hide Writing List" : "Show Writing List")
                .accessibilityValue(showsWritingList ? "Shown" : "Hidden")
                if let devotional = selectedDevotional {
                    // Named: its figure-at-a-screen symbol, alone, read as
                    // a person rather than as presenting.
                    Button {
                        openWindow(
                            id: "devotional-presenter",
                            value: DevotionalPresentationRequest(devotionalID: devotional.id)
                        )
                    } label: {
                        Label("Present", systemImage: "play.rectangle")
                            .labelStyle(.titleAndIcon)
                    }
                    .help("Present selected writing")
                }
            }
        }
        .confirmationDialog(
            "Delete this writing?",
            isPresented: Binding(
                get: { devotionalPendingDeletion != nil },
                set: { if !$0 { devotionalPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let devotional = devotionalPendingDeletion else { return }
                delete(devotional)
            }
            Button("Cancel", role: .cancel) { devotionalPendingDeletion = nil }
        } message: {
            Text(deletionWarning)
        }
        .onAppear {
            takeRequestedDevotional()
            selectFirstIfNeeded()
        }
        .onChange(of: initialDevotionalID) { _, _ in takeRequestedDevotional() }
        .onChange(of: model.devotionals) { _, _ in selectFirstIfNeeded() }
        .onChange(of: query) { _, _ in selectFirstIfNeeded() }
        .onChange(of: categoryFilter) { _, _ in selectFirstIfNeeded() }
        .onChange(of: moduleFilter) { _, _ in selectFirstIfNeeded() }
        .task { await monitorLinkedPresentationDecks() }
    }

    private var writingListWidth: CGFloat {
        CGFloat(min(max(preferredWritingListWidth, 220), 320))
    }

    /// Category and collection filters in one menu that says what is shown.
    /// As two pop-ups reading "All Categories" and "All Collections" they
    /// were the widest pills in a crowded toolbar, and said nothing at all
    /// while nothing was filtered.
    private var filterMenu: some View {
        Menu {
            Picker("Category", selection: $categoryFilter) {
                Text("All Categories").tag(String?.none)
                ForEach(devotionalCategories, id: \.self) { category in
                    Text(LampWritingCategory.displayName(category) ?? category)
                        .tag(Optional(category))
                }
            }
            .pickerStyle(.inline)
            .accessibilityLabel("Filter writing by category")
            Picker("Collection", selection: $moduleFilter) {
                Text("All Collections").tag(String?.none)
                ForEach(devotionalCollections, id: \.id) { collection in
                    Text(collection.name).tag(Optional(collection.id))
                }
            }
            .pickerStyle(.inline)
            .accessibilityLabel("Filter writing by collection")
        } label: {
            Label(
                filterSummary,
                systemImage: categoryFilter == nil && moduleFilter == nil
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
            .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel("Filter writing")
        .help("Filter writing by category and collection")
    }

    /// What the filter menu says: everything, or the category and the
    /// collection being shown.
    private var filterSummary: String {
        var parts: [String] = []
        if let categoryFilter {
            parts.append(LampWritingCategory.displayName(categoryFilter) ?? categoryFilter)
        }
        if let moduleFilter, let collection = devotionalCollections.first(where: { $0.id == moduleFilter }) {
            parts.append(collection.name)
        }
        return parts.isEmpty ? "All Writing" : parts.joined(separator: " · ")
    }

    /// Sorting and grouping in one menu: two unlabelled pills beside each
    /// other were two more symbols to decode in an already busy toolbar.
    private var arrangeMenu: some View {
        Menu("Sort and Group", systemImage: "arrow.up.arrow.down") {
            Section("Sort By") {
                sortItems
            }
            Section("Group By") {
                groupItems
            }
        }
        .accessibilityLabel("Sort and group writing")
        .help("Sort and group writing")
    }

    @ViewBuilder
    private var sortItems: some View {
            ForEach(WritingSortOrder.allCases) { option in
                Button {
                    sortOrderRawValue = option.rawValue
                } label: {
                    if sortOrder == option {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
    }

    @ViewBuilder
    private var groupItems: some View {
            ForEach(WritingGroupBy.allCases) { option in
                Button {
                    groupByRawValue = option.rawValue
                } label: {
                    if groupBy == option {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
    }

    /// The list as Books draws its own: an inset list, its groups under
    /// the list's own section headers, and the selection the system draws.
    /// Before, this list drew its rules and headings itself, and so looked
    /// unlike every other list in the app.
    private func writingList(_ listSections: [WritingListSection]) -> some View {
        List(selection: $selection) {
            ForEach(listSections) { section in
                // Always in a section: an inset list draws its row rules
                // only inside one, and Books' rows have them.
                if let title = section.title {
                    Section(title) { devotionalRows(section.devotionals) }
                } else {
                    Section { devotionalRows(section.devotionals) }
                }
            }
        }
        // Inset, as Books' list is: a sidebar list draws under the toolbar.
        .listStyle(.inset)
        .contentMargins(.bottom, 52, for: .scrollContent)
        // A footer action in the list's own voice, as the sidebar's Import
        // or Create… is: a full-width filled button was the loudest thing
        // in the window, louder than the writing.
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    beginEditing(nil)
                } label: {
                    Label("New Writing", systemImage: "plus")
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                .help("Create new writing")
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private func devotionalRows(_ devotionals: [LampDevotional]) -> some View {
        ForEach(devotionals) { devotional in
            devotionalRow(devotional)
        }
    }

    /// Set as a book's row is: the title, then a quieter line under it.
    /// Writing adds its opening words, which are what tell two drafts
    /// apart, and keeps its actions in the context menu and the strip over
    /// the preview, as Books does, rather than a button on every row.
    private func devotionalRow(_ devotional: LampDevotional) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(devotional.title)
                    .font(.system(size: LampMetrics.listTitleSize, weight: .medium))
                    .lineLimit(2)
                    // Two lines when it needs them: beside the lock badge the
                    // row measured it as one and cut it off.
                    .fixedSize(horizontal: false, vertical: true)
                // Only installed entries are worth badging. Nearly everything
                // in this list is the reader's own writing, so a badge on
                // every editable row marked nothing at all.
                if !devotional.isEditable {
                    Image(systemName: "lock")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                        .help("Installed writing — read only")
                        .accessibilityLabel("Read only")
                }
            }
            // Auto-titled drafts all read "Untitled Devotional", so the
            // opening line is the only thing that tells two of them apart.
            if let snippet = rowSnippet(for: devotional) {
                // The list's detail line, as a book's author is.
                Text(snippet)
                    .font(.system(size: LampMetrics.listDetailSize))
                    .foregroundStyle(Color.lampSecondaryText)
                    .lineLimit(2)
                    .lineSpacing(1)
            }
            HStack(spacing: 5) {
                Text(rowMetadata(for: devotional))
                    .lineLimit(1)
                // A status, said in the row's quietest line, as a book's
                // place is said under its author.
                if !presentationDecks(for: devotional).isEmpty {
                    Image(systemName: LinkedPresentationDeckLookup.systemImage)
                        .imageScale(.small)
                        .help(presentationDescription(for: devotional))
                        .accessibilityLabel(presentationDescription(for: devotional))
                }
            }
            .font(.system(size: LampMetrics.listCaptionSize))
            .foregroundStyle(Color.lampSecondaryText)
        }
        .padding(.vertical, 6)
        // Ruled between rows, as Books' list is.
        .listRowSeparator(.visible)
        .tag(devotional.id)
        .lampListRow(isSelected: selection == devotional.id)
        // Explicitly adopt the clicked row. The former simultaneous double-click
        // recognizer competed with List's native selection, leaving keyboard
        // navigation working while pointer clicks failed to update the preview.
        .onTapGesture {
            selection = devotional.id
            guard devotional.isEditable,
                  NSApplication.shared.currentEvent?.clickCount == 2 else { return }
            beginEditing(devotional)
        }
        .help(devotional.isEditable
            ? "Click to preview; double-click to edit"
            : "Click to preview this installed writing")
        .accessibilityAction(named: "Edit") {
            guard devotional.isEditable else { return }
            beginEditing(devotional)
        }
        .contextMenu {
            presentationActions(for: devotional)
            Divider()
            ShareLink(
                item: devotional.content,
                subject: Text(devotional.title),
                message: Text(devotional.summary ?? devotional.title)
            ) {
                Label("Share as Markdown", systemImage: "square.and.arrow.up")
            }
            if devotional.isEditable {
                Divider()
                Button("Edit", systemImage: "pencil") { beginEditing(devotional) }
                Button("Export…", systemImage: "square.and.arrow.up") { export(devotional) }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    devotionalPendingDeletion = devotional
                }
            }
        }
    }

    @ViewBuilder
    private func presentationActions(for devotional: LampDevotional) -> some View {
        let decks = presentationDecks(for: devotional)
        if decks.count > 1 {
            Menu("Open Presentation Deck", systemImage: LinkedPresentationDeckLookup.systemImage) {
                ForEach(decks) { deck in
                    Button(deck.title) { openPresentationDeck(deck, for: devotional) }
                }
            }
        } else if let deck = decks.first {
            Button("Open Presentation Deck", systemImage: LinkedPresentationDeckLookup.systemImage) {
                openPresentationDeck(deck, for: devotional)
            }
        } else {
            Button("Build Presentation Deck", systemImage: LinkedPresentationDeckLookup.systemImage) {
                openPresentationDeck(nil, for: devotional)
            }
        }
    }

    private func devotionalDetail(_ devotional: LampDevotional) -> some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                previewStrip(devotional)
                Divider()
                if previewFind.isVisible {
                    WritingFindBar(controller: previewFind)
                    Divider()
                }
                devotionalDocument(devotional)
            }
            // A marker in the prose is a link to its note. Every other link
            // is one the writer put there and opens as it would anywhere else.
            .environment(\.openURL, OpenURLAction { url in
                guard let number = LampDevotionalFootnotes.markerNumber(in: url) else {
                    return .systemAction
                }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(DevotionalFootnoteAnchor(number: number), anchor: .center)
                }
                footnoteHighlight.show(number)
                return .handled
            })
            .onChange(of: previewFinder.scrollTo) { _, request in
                guard let request else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(
                        DevotionalPreviewBlockAnchor(index: request.block),
                        anchor: .center
                    )
                }
            }
        }
        // ⌘F finds in the preview whatever in the window has focus. A
        // focused value counted only while something inside the preview had
        // keyboard focus, and read-only text rarely does: with the writing
        // list focused beside it, Find was disabled and ⌘F did nothing. The
        // preview exists only while Writing is shown, so this cannot reach
        // another section. It is read-only, so Find and Replace stays
        // unavailable rather than opening a bar whose Replace does nothing.
        .focusedSceneValue(\.writingFind, previewFind)
        // Moving to another writing keeps the query — it is the same bar — and
        // the new text is searched as it is rendered, because the preview
        // hands the finder its runs every time it draws.
        .onAppear { previewFind.attach(previewFinder) }
    }

    /// The writing's own actions, over it, as Books puts a section's over
    /// the page: step through the list, then edit, share, set the type, and
    /// the rest. The window's toolbar keeps what acts on the list.
    private func previewStrip(_ devotional: LampDevotional) -> some View {
        let neighbours = previewNeighbours(of: devotional)
        return HStack(spacing: 14) {
            Button("Previous Writing", systemImage: "chevron.left") {
                if let previous = neighbours.previous { selection = previous }
            }
            .labelStyle(.iconOnly)
            .disabled(neighbours.previous == nil)
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

            Button("Next Writing", systemImage: "chevron.right") {
                if let next = neighbours.next { selection = next }
            }
            .labelStyle(.iconOnly)
            .disabled(neighbours.next == nil)
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

            Spacer()
            if devotional.isEditable {
                Button("Edit", systemImage: "pencil") { beginEditing(devotional) }
                    .labelStyle(.iconOnly)
                    .help("Edit this writing")
            }

            ShareLink(
                item: devotional.content,
                subject: Text(devotional.title),
                message: Text(devotional.summary ?? devotional.title)
            ) {
                Label("Share as Markdown", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
            .help("Share this writing as Markdown")

            TextSizeMenu(
                fontSize: $devotionalFontSize,
                lineSpacing: $devotionalLineSpacing,
                typeface: $devotionalTypeface,
                defaultTypeface: ProseTypeface.readerDefault,
                fontScale: .writingReadingText,
                lineSpacingScale: .writingReadingLineSpacing,
                help: "Adjust the reading typeface, text size, and line spacing"
            )

            Menu("More", systemImage: "ellipsis.circle") {
                presentationActions(for: devotional)
                if devotional.isEditable {
                    Divider()
                    Button("Export…", systemImage: "square.and.arrow.up") { export(devotional) }
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        devotionalPendingDeletion = devotional
                    }
                }
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Presentation deck, export, and delete")
        }
        .buttonStyle(.borderless)
        // The same size and shade as the book reader's strip.
        .font(.system(size: 14.5))
        .foregroundStyle(.primary.opacity(0.78))
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

    /// The writings either side of this one, in the list's order.
    private func previewNeighbours(of devotional: LampDevotional) -> (previous: String?, next: String?) {
        let ids = writingListSections(from: filteredDevotionals).flatMap { $0.devotionals.map(\.id) }
        guard let index = ids.firstIndex(of: devotional.id) else { return (nil, nil) }
        return (
            index > ids.startIndex ? ids[index - 1] : nil,
            index + 1 < ids.endIndex ? ids[index + 1] : nil
        )
    }

    /// What kind of writing this is, over its title, as "Chapter 2" is over
    /// a book section's: its series where it has one, else its category.
    private func previewEyebrow(_ devotional: LampDevotional) -> String? {
        if let series = devotional.seriesName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !series.isEmpty {
            return series
        }
        return LampWritingCategory.displayName(devotional.category)
    }

    private func devotionalDocument(_ devotional: LampDevotional) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Set as a book section's header is: an eyebrow, the title,
                // its subtitle, then the passages it is about.
                VStack(alignment: .leading, spacing: 10) {
                    if let eyebrow = previewEyebrow(devotional) {
                        Text(eyebrow.uppercased())
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(1.4)
                            .foregroundStyle(Color.lampSecondaryText)
                    }
                    Text(devotional.title)
                        .font(.system(
                            size: max(devotionalFontSize * 1.8, 30),
                            weight: .bold,
                            design: devotionalTypeface.design
                        ))
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle = devotional.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(
                                size: max(devotionalFontSize * 1.15, 18),
                                design: devotionalTypeface.design
                            ))
                            .foregroundStyle(.secondary)
                    }
                    detailMetadata(devotional)
                    if !devotional.keyScriptures.isEmpty {
                        // Wraps: a writing can carry more references than
                        // the pane has room for on one line.
                        WrappingRow(spacing: 6) {
                            ForEach(devotional.keyScriptures) { scripture in
                                Button(scripture.displayDescription) {
                                    openReference(scripture.startReference)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(.top, 3)
                    }
                }

                if let summary = devotional.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(
                            size: devotionalFontSize * 1.1,
                            design: devotionalTypeface.design
                        ))
                        .lineSpacing(devotionalLineSpacing)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // The labels in the writing can be anything; a reader is shown
                // 1, 2, 3 in reading order. Both halves come from one numbering
                // so a marker and its note cannot disagree.
                let numbered = LampDevotionalFootnotes.numbered(
                    content: devotional.displayMarkdown,
                    footnotes: devotional.footnotes
                )
                DevotionalContentView(
                    markdown: LampDevotionalFootnotes.displayContent(numbered, linkingMarkers: true),
                    libraryRootURL: model.library.rootURL,
                    devotionalID: devotional.id,
                    mediaReferences: devotional.mediaReferences,
                    fontSize: devotionalFontSize,
                    lineSpacing: devotionalLineSpacing,
                    typeface: devotionalTypeface,
                    // Without this an unwritten draft is a title over a divider
                    // over nothing, which reads as a rendering failure.
                    emptyState: AnyView(emptyDraftState(devotional)),
                    titleShownAbove: devotional.title,
                    // The writing itself is what Find searches. The notes
                    // below it are a list of their own, and each preview
                    // numbers its runs from the top of its own text.
                    finder: previewFinder
                )

                if !numbered.footnotes.isEmpty || !numbered.preamble.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Footnotes")
                            .font(.headline)
                        // Anything the writer put above the definitions is theirs
                        // and is shown as the writing it is.
                        if !numbered.preamble.isEmpty {
                            DevotionalContentView(
                                markdown: numbered.preamble,
                                libraryRootURL: model.library.rootURL,
                                devotionalID: devotional.id,
                                mediaReferences: devotional.mediaReferences,
                                fontSize: max(devotionalFontSize - 2, 11),
                                lineSpacing: devotionalLineSpacing,
                                typeface: devotionalTypeface
                            )
                        }
                        DevotionalFootnoteList(
                            footnotes: numbered.footnotes,
                            fontSize: max(devotionalFontSize - 2, 11),
                            lineSpacing: devotionalLineSpacing,
                            typeface: devotionalTypeface,
                            highlight: footnoteHighlight
                        )
                    }
                    .foregroundStyle(.secondary)
                }

                if !devotional.tags.isEmpty {
                    Text(devotional.tags.map { "#\($0)" }.joined(separator: "  "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // A reading measure of about 70 characters, set from the text
            // size so it holds as the size changes, and centred in the pane
            // as a page is. A fixed 760 points made lines of 100 characters
            // at the default size.
            .frame(maxWidth: Self.readingMeasure(for: devotionalFontSize), alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 36)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    /// The column a writing is read in, in points, for a text size.
    static func readingMeasure(for fontSize: Double) -> CGFloat {
        CGFloat(min(max(fontSize * 33, 500), 880))
    }

    @ViewBuilder
    private func emptyDraftState(_ devotional: LampDevotional) -> some View {
        ContentUnavailableView {
            Label("Nothing Written Yet", systemImage: "text.alignleft")
        } description: {
            Text(devotional.isEditable
                ? "Open this draft in the editor to start writing."
                : "This entry has no body text.")
        } actions: {
            if devotional.isEditable {
                Button("Edit") { beginEditing(devotional) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 36)
    }

    private var readingMode: LampReadingMode { LampReadingMode(storedValue: readingModeRawValue) }

    private var readingWordsPerMinute: Int {
        switch readingMode {
        case .silent: silentWordsPerMinute
        case .aloud: aloudWordsPerMinute
        }
    }

    private func rowSnippet(for devotional: LampDevotional) -> String? {
        rowSummaries.snippet(for: devotional)
    }

    /// What distinguishes one entry from another at a glance. The collection name
    /// is only worth a line for installed modules — repeating "My Writing" under
    /// every personal draft says nothing the pencil badge has not already said.
    private func rowMetadata(for devotional: LampDevotional) -> String {
        var parts: [String] = []
        if let series = devotional.seriesName, !series.isEmpty {
            parts.append(series)
        } else if !devotional.isEditable {
            parts.append(collectionName(for: devotional))
        }
        if let date = devotional.date, !date.isEmpty {
            parts.append(formattedDate(date))
        }
        let statistics = rowSummaries.statistics(for: devotional)
        if statistics.wordCount > 0 {
            // A row is not a control, but it answers the same question, so it
            // answers it at whichever pace was chosen.
            parts.append(statistics.readingTimeDescription(
                mode: readingMode,
                wordsPerMinute: readingWordsPerMinute
            ))
        }
        return parts.isEmpty ? "Empty draft" : parts.joined(separator: " · ")
    }

    /// Author, date, series and length. Reading time belongs beside them: these
    /// are written to a length, and "how long is this" is part of choosing what
    /// to read next.
    private func detailMetadata(_ devotional: LampDevotional) -> some View {
        let statistics = rowSummaries.statistics(for: devotional)
        return WrappingRow(spacing: 12) {
            if let author = devotional.author, !author.isEmpty {
                Label(author, systemImage: "person")
            }
            if let date = devotional.date, !date.isEmpty {
                Label(formattedDate(date), systemImage: "calendar")
            }
            if let series = devotional.seriesName, !series.isEmpty {
                Label(series, systemImage: "square.stack")
            }
            if statistics.wordCount > 0 {
                ReadingTimeMenu(statistics: statistics, showsIcon: true)
            }
        }
        .font(.callout)
        .foregroundStyle(Color.lampSecondaryText)
    }

    /// Stored dates are the portable `yyyy-MM-dd`; a reader wants their own
    /// locale's rendering of the day.
    private func formattedDate(_ storedValue: String) -> String {
        guard let date = LampCalendarDate.date(from: storedValue) else { return storedValue }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    private var sortOrder: WritingSortOrder {
        WritingSortOrder(rawValue: sortOrderRawValue) ?? .titleAscending
    }

    private var groupBy: WritingGroupBy {
        WritingGroupBy(rawValue: groupByRawValue) ?? .none
    }

    private func writingListSections(
        from visibleDevotionals: [LampDevotional]
    ) -> [WritingListSection] {
        guard groupBy != .none else {
            return [WritingListSection(
                id: "all-writing",
                title: nil,
                devotionals: visibleDevotionals
            )]
        }
        return Dictionary(grouping: visibleDevotionals, by: writingGroupTitle)
            .map { title, devotionals in
                WritingListSection(id: title, title: title, devotionals: devotionals)
            }
            .sorted { lhs, rhs in
                (lhs.title ?? "").localizedStandardCompare(rhs.title ?? "") == .orderedAscending
            }
    }

    private func devotionalPrecedes(_ lhs: LampDevotional, _ rhs: LampDevotional) -> Bool {
        switch sortOrder {
        case .titleAscending:
            return titlePrecedes(lhs, rhs, ascending: true)
        case .titleDescending:
            return titlePrecedes(lhs, rhs, ascending: false)
        case .dateNewest:
            return textPrecedes(lhs.date, rhs.date, lhs: lhs, rhs: rhs, ascending: false)
        case .dateOldest:
            return textPrecedes(lhs.date, rhs.date, lhs: lhs, rhs: rhs, ascending: true)
        case .recentlyModified:
            let left = lhs.lastModified ?? .distantPast
            let right = rhs.lastModified ?? .distantPast
            return left == right ? titlePrecedes(lhs, rhs, ascending: true) : left > right
        case .recentlyCreated:
            let left = lhs.created ?? .distantPast
            let right = rhs.created ?? .distantPast
            return left == right ? titlePrecedes(lhs, rhs, ascending: true) : left > right
        }
    }

    private func titlePrecedes(
        _ lhs: LampDevotional,
        _ rhs: LampDevotional,
        ascending: Bool
    ) -> Bool {
        let comparison = lhs.title.localizedStandardCompare(rhs.title)
        guard comparison != .orderedSame else { return lhs.id < rhs.id }
        return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    private func textPrecedes(
        _ lhsText: String?,
        _ rhsText: String?,
        lhs: LampDevotional,
        rhs: LampDevotional,
        ascending: Bool
    ) -> Bool {
        let left = lhsText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhsText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if left?.isEmpty != false { return right?.isEmpty == false ? false : titlePrecedes(lhs, rhs, ascending: true) }
        if right?.isEmpty != false { return true }
        let comparison = left!.localizedStandardCompare(right!)
        guard comparison != .orderedSame else { return titlePrecedes(lhs, rhs, ascending: true) }
        return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    private func writingGroupTitle(for devotional: LampDevotional) -> String {
        switch groupBy {
        case .none:
            return "Writing"
        case .category:
            return LampWritingCategory.displayName(devotional.category) ?? "Uncategorized"
        case .collection:
            return collectionName(for: devotional)
        case .series:
            let series = devotional.seriesName?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return series.isEmpty ? "No Series" : series
        }
    }

    private func collectionName(for devotional: LampDevotional) -> String {
        devotional.moduleID == "personal-devotionals" ? "My Writing" : devotional.moduleName
    }

    private func beginEditing(_ devotional: LampDevotional?) {
        openWindow(id: "devotional-editor", value: DevotionalEditorRequest(devotionalID: devotional?.id))
    }

    private func presentationDecks(for devotional: LampDevotional) -> [LampPresentationDeck] {
        presentationDecksByDevotionalID[devotional.id] ?? []
    }

    private func presentationDescription(for devotional: LampDevotional) -> String {
        let count = presentationDecks(for: devotional).count
        return count == 1 ? "Has a presentation deck" : "Has \(count) presentation decks"
    }

    private func openPresentationDeck(
        _ deck: LampPresentationDeck?,
        for devotional: LampDevotional
    ) {
        openWindow(
            id: "slide-studio",
            value: deck.map { SlideStudioRequest(deckID: $0.id) }
                ?? SlideStudioRequest(devotionalID: devotional.id)
        )
    }

    @MainActor
    private func monitorLinkedPresentationDecks() async {
        while !Task.isCancelled {
            let rootURL = model.library.rootURL
            let decks = try? await Task.detached(priority: .utility) {
                try LinkedPresentationDeckLookup.groupedByDevotional(rootURL: rootURL)
            }.value
            if let decks, decks != presentationDecksByDevotionalID {
                presentationDecksByDevotionalID = decks
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private var devotionalCategories: [String] {
        LampWritingCategory.kindsHeld(model.devotionals.map(\.category))
    }

    private var devotionalCollections: [(id: String, name: String)] {
        Dictionary(grouping: model.devotionals, by: \.moduleID)
            .map { (id: $0.key, name: $0.value.first.map(collectionName) ?? $0.key) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func export(_ devotional: LampDevotional) {
        Task {
            do {
                let document = try await model.library.personalDevotionalDocument(id: devotional.id)
                let panel = NSSavePanel()
                panel.title = "Export Devotional Module"
                panel.nameFieldStringValue = document.suggestedModuleFilename
                panel.allowedContentTypes = [UTType(exportedAs: "com.neus.lamp-bible.lamp", conformingTo: .data)]
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
                _ = try await Task.detached(priority: .userInitiated) {
                    try LampModuleCompiler().compile(
                        data: document.jsonData,
                        sourceFilename: document.suggestedJSONFilename,
                        destinationURL: destinationURL
                    )
                }.value
                exportedURL = destinationURL
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    /// What deleting will take, including the decks that go with the writing.
    ///
    /// Named, with their slide counts, because a deck can be a great deal of
    /// work — one of this library's is 74 slides — and a writing's decks now
    /// go when it does. A confirmation that does not say so is an ambush.
    private var deletionWarning: String {
        // Not "from this Mac": deleting records a tombstone, which is how
        // the deletion reaches the other devices rather than the writing
        // coming back on the next sync.
        let writing = "This deletes the writing from your library — from this Mac, and from your "
            + "other devices the next time they sync. Installed module entries are never modified."
        guard let pending = devotionalPendingDeletion,
              let decks = presentationDecksByDevotionalID[pending.id],
              !decks.isEmpty
        else { return writing }
        let named = decks
            .map { "\u{201C}\($0.title)\u{201D} (\($0.slides.count) slides)" }
            .joined(separator: ", ")
        let lead = decks.count == 1
            ? "Its presentation deck goes with it"
            : "Its \(decks.count) presentation decks go with it"
        return "\(writing)\n\n\(lead): \(named)."
    }

    private func delete(_ devotional: LampDevotional) {
        devotionalPendingDeletion = nil
        Task {
            do {
                try await model.deletePersonalDevotional(id: devotional.id)
                selection = model.devotionals.first?.id
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    /// Fills in a selection whenever the current one is not in the visible list.
    ///
    /// This deliberately does *not* try to preserve a deselection the reader made:
    /// `List` also writes nil into the binding while it is laying out, and the two
    /// are indistinguishable from here. Treating nil as intentional left the view
    /// opening with nothing selected at all. Clicking away still empties the
    /// preview — nothing calls this until the data or a filter actually changes.
    private func selectFirstIfNeeded() {
        if !filteredDevotionals.contains(where: { $0.id == selection }) {
            selection = filteredDevotionals.first?.id
        }
    }
}

struct DevotionalPresentationView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("devotional.fontSize") private var devotionalFontSize = 17.0
    let request: DevotionalPresentationRequest

    private var devotional: LampDevotional? {
        model.devotionals.first { $0.id == request.devotionalID }
    }

    var body: some View {
        Group {
            if let devotional {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(devotional.title).font(.title.bold())
                            if let subtitle = devotional.subtitle {
                                Text(subtitle).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Close Presenter", systemImage: "xmark") {
                            dismissWindow(id: "devotional-presenter")
                        }
                        .labelStyle(.iconOnly)
                        .keyboardShortcut(.cancelAction)
                        .help("Close presenter")
                    }
                    .padding(24)
                    Divider()
                    ScrollView {
                        let numbered = LampDevotionalFootnotes.numbered(
                            content: devotional.displayMarkdown,
                            footnotes: devotional.footnotes
                        )
                        VStack(alignment: .leading, spacing: 24) {
                            DevotionalContentView(
                                markdown: LampDevotionalFootnotes.displayContent(numbered),
                                libraryRootURL: model.library.rootURL,
                                devotionalID: devotional.id,
                                mediaReferences: devotional.mediaReferences,
                                fontSize: devotionalFontSize + 5
                            )
                            if !numbered.footnotes.isEmpty {
                                Divider()
                                DevotionalFootnoteList(
                                    footnotes: numbered.footnotes,
                                    fontSize: devotionalFontSize + 2,
                                    lineSpacing: 6,
                                    typeface: .serif
                                )
                                .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: 920, alignment: .leading)
                        .padding(48)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Writing Unavailable",
                    systemImage: "doc.questionmark",
                    description: Text("This writing is no longer in the library.")
                )
            }
        }
        .frame(minWidth: 1_020, minHeight: 720)
        .background(DevotionalFullScreenWindowController())
    }
}

private struct DevotionalFullScreenWindowController: NSViewRepresentable {
    func makeNSView(context: Context) -> DevotionalFullScreenTriggerView {
        DevotionalFullScreenTriggerView()
    }

    func updateNSView(_ view: DevotionalFullScreenTriggerView, context: Context) {}
}

private final class DevotionalFullScreenTriggerView: NSView {
    private var didEnterFullScreen = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !didEnterFullScreen else { return }
        didEnterFullScreen = true
        DispatchQueue.main.async {
            window.collectionBehavior.insert(.fullScreenPrimary)
            if !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
        }
    }
}

struct QuizzesView: View {
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("quiz.defaultAgeGroup") private var defaultQuizAgeGroup = ""
    @AppStorage("quiz.alwaysShowAnswers") private var alwaysShowAnswers = false
    @State private var selectedModuleID: String?
    @State private var selectedAgeGroupID: String?
    @State private var day = LampPlanCalendar.dayNumber(for: Date())
    @State private var questions: [LampQuizQuestion] = []
    @State private var revealedAnswers: Set<Int64> = []
    @State private var isLoading = false
    @StateObject private var readAloud = QuizReadAloudController()

    /// The quiz module a search result asked for, taken once.
    @Binding var initialModuleID: String?
    let showImporter: () -> Void
    let openReference: (Int) -> Void

    /// Opens the quiz module a search result named, and forgets the request.
    private func takeRequestedModule() {
        guard let id = initialModuleID else { return }
        selectedModuleID = id
        initialModuleID = nil
    }

    private var selectedModule: LampQuizModule? {
        model.quizModules.first { $0.id == selectedModuleID } ?? model.quizModules.first
    }

    private var selectedPlan: LampReadingPlan? {
        guard let planID = selectedModule?.planID else { return nil }
        return model.plans.first { $0.id == planID }
    }

    private var maximumDay: Int {
        max(selectedPlan?.duration ?? 366, 1)
    }

    private var loadKey: String {
        "\(selectedModule?.id ?? "none"):\(selectedAgeGroupID ?? "none"):\(day)"
    }

    private var currentYear: Int {
        LampPlanCalendar.year(for: Date())
    }

    private var selectedDateDescription: String {
        LampPlanCalendar.date(forDayNumber: day, year: currentYear)?
            .formatted(date: .long, time: .omitted)
            ?? "Day \(day)"
    }

    var body: some View {
        Group {
            if model.quizModuleInstallations.isEmpty {
                ContentUnavailableView {
                    Label("No Quizzes", systemImage: "questionmark.bubble")
                } description: {
                    Text("Install a quiz .lamp module, or build one in Module Studio.")
                } actions: {
                    Button("Install Module…", action: showImporter)
                        .buttonStyle(.borderedProminent)
                }
            } else if let quiz = selectedModule {
                VStack(spacing: 0) {
                    quizControls(quiz)
                    Divider()
                    questionContent(quiz)
                }
            } else {
                ProgressView("Loading Quizzes…")
            }
        }
        .navigationTitle("Quizzes")
        .onAppear {
            takeRequestedModule()
            configureSelection()
        }
        .onChange(of: initialModuleID) { _, _ in takeRequestedModule() }
        .onChange(of: model.quizModules) { _, _ in configureSelection() }
        .onChange(of: selectedModuleID) { _, _ in configureAgeGroup() }
        .onChange(of: loadKey) { _, _ in readAloud.stop() }
        .onChange(of: alwaysShowAnswers) { _, _ in readAloud.stop() }
        .onChange(of: selectedAgeGroupID) { _, ageGroupID in
            if let ageGroupID { defaultQuizAgeGroup = ageGroupID }
        }
        .task(id: loadKey) { await loadQuestions() }
        .onDisappear { readAloud.stop() }
    }

    /// The quiz, the age group and the day, on one line over the column of
    /// questions and aligned to it. Spread across the full window, the
    /// controls floated with gaps of their own choosing and lined up with
    /// nothing below them.
    private func quizControls(_ quiz: LampQuizModule) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Picker("Quiz", selection: $selectedModuleID) {
                ForEach(model.quizModules) { module in
                    Text(module.name).tag(Optional(module.id))
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Quiz")

            Picker("Age Group", selection: $selectedAgeGroupID) {
                ForEach(quiz.ageGroups) { ageGroup in
                    Text("\(ageGroup.label) (\(ageGroup.ageRange))")
                        .tag(Optional(ageGroup.id))
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Age group")

            Spacer(minLength: 12)

            // The day, stepped either way. The date it falls on heads the
            // questions just below, in full.
            HStack(spacing: 2) {
                Button("Previous Day", systemImage: "chevron.left") {
                    day = max(day - 1, 1)
                }
                .disabled(day <= 1)
                Text("Day \(day)")
                    .font(.callout.weight(.medium).monospacedDigit())
                    .frame(minWidth: 64)
                    .help(selectedDateDescription)
                Button("Next Day", systemImage: "chevron.right") {
                    day = min(day + 1, maximumDay)
                }
                .disabled(day >= maximumDay)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Day")

            QuizOptionsMenu()
        }
        .frame(maxWidth: QuizzesView.columnWidth)
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    /// The column the questions are read in: answers run to two lines at
    /// most, rather than one line of a hundred characters.
    static let columnWidth: CGFloat = 740

    @ViewBuilder
    private func questionContent(_ quiz: LampQuizModule) -> some View {
        if isLoading {
            ProgressView("Loading \(selectedDateDescription)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if questions.isEmpty {
            ContentUnavailableView(
                "No Questions for \(selectedDateDescription)",
                systemImage: "questionmark.bubble",
                description: Text("Day \(day) · Choose another date or age group.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .lastTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedDateDescription)
                                .font(.largeTitle.bold())
                            Text(quiz.name)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(questions.count) question\(questions.count == 1 ? "" : "s")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 6)

                    ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                        questionCard(question, number: index + 1)
                    }
                }
                .frame(maxWidth: Self.columnWidth)
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            // The window, with the cards a step off it, as cards are drawn
            // across the app.
            .background(QuizCardSurface.page)
        }
    }

    private func questionCard(_ question: LampQuizQuestion, number: Int) -> some View {
        QuizQuestionCard(
            question: question,
            number: number,
            answerVisible: alwaysShowAnswers || revealedAnswers.contains(question.id),
            allowsAnswerToggle: !alwaysShowAnswers,
            showsTheme: true,
            readAloud: readAloud,
            openReference: openReference,
            toggleAnswer: {
                readAloud.stop()
                if revealedAnswers.contains(question.id) {
                    revealedAnswers.remove(question.id)
                } else {
                    revealedAnswers.insert(question.id)
                }
            }
        )
    }

    private func configureSelection() {
        if !model.quizModules.contains(where: { $0.id == selectedModuleID }) {
            selectedModuleID = model.quizModules.first?.id
        }
        configureAgeGroup()
    }

    private func configureAgeGroup() {
        guard let quiz = selectedModule else {
            selectedAgeGroupID = nil
            return
        }
        if !quiz.ageGroups.contains(where: { $0.id == selectedAgeGroupID }) {
            selectedAgeGroupID = quiz.ageGroups.first { $0.id == defaultQuizAgeGroup }?.id
                ?? quiz.ageGroups.first?.id
        }
        day = min(max(day, 1), maximumDay)
    }

    private func loadQuestions() async {
        guard let quiz = selectedModule,
              let ageGroupID = selectedAgeGroupID else {
            questions = []
            return
        }
        isLoading = true
        revealedAnswers = []
        let loaded = await model.quizQuestions(
            moduleID: quiz.id,
            day: day,
            ageGroup: ageGroupID
        )
        guard !Task.isCancelled else { return }
        questions = loaded
        isLoading = false
    }
}

/// Quiz text uses the same appearance vocabulary as scripture and commentary,
/// while retaining its own preference values for the narrower quiz layout.
struct QuizOptionsMenu: View {
    @AppStorage("quiz.fontSize") private var fontSize = LampTextScale.quizText.defaultValue
    @AppStorage("quiz.lineSpacing") private var lineSpacing = LampTextScale.quizLineSpacing.defaultValue
    @AppStorage("quiz.typeface") private var typeface = ProseTypeface.commentaryDefault
    @AppStorage("quiz.previewContextAmount") private var previewContextAmount = ScripturePreviewContextAmount.oneVerse
    @AppStorage("quiz.alwaysShowAnswers") private var alwaysShowAnswers = false

    var body: some View {
        Menu("Quiz Options", systemImage: "textformat") {
            Toggle("Show Answers by Default", isOn: $alwaysShowAnswers)

            Divider()

            TextSizeMenuItems(
                fontSize: $fontSize,
                lineSpacing: $lineSpacing,
                typeface: $typeface,
                defaultTypeface: .commentaryDefault,
                previewContextAmount: $previewContextAmount,
                fontScale: .quizText,
                lineSpacingScale: .quizLineSpacing
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose quiz answers, preview context, typeface, text size, and line spacing")
    }
}

struct QuizQuestionCard: View {
    @AppStorage("quiz.fontSize") private var fontSize = LampTextScale.quizText.defaultValue
    @AppStorage("quiz.lineSpacing") private var lineSpacing = LampTextScale.quizLineSpacing.defaultValue
    @AppStorage("quiz.typeface") private var typeface = ProseTypeface.commentaryDefault
    @AppStorage("quiz.previewContextAmount") private var previewContextAmount = ScripturePreviewContextAmount.oneVerse
    @AppStorage("reader.readAloud.voice") private var readAloudVoice = ""
    @AppStorage("reader.readAloud.rate") private var readAloudRate = 0.5
    let question: LampQuizQuestion
    /// Its place in the day's quiz, shown at the head of the card. Nil
    /// where a single question stands alone.
    var number: Int? = nil
    let answerVisible: Bool
    let allowsAnswerToggle: Bool
    let showsTheme: Bool
    @ObservedObject var readAloud: QuizReadAloudController
    let openReference: (Int) -> Void
    let toggleAnswer: () -> Void
    @State private var linkActivationGate = ReaderLinkActivationGate()
    @State private var previewLink: LampScriptureLink?
    /// Where the pointer is inside this card, and how big the card is, so a
    /// preview can be put beside the reference it is about.
    @State private var pointerInCard: CGPoint?
    @State private var cardSize: CGSize = .zero
    /// Held still while a preview is open, so moving the mouse afterwards
    /// does not drag the popover around.
    @State private var previewAnchor: UnitPoint = .center

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                // Numbered, so fifteen like cards read as a sequence, and a
                // child can be asked "number four" across the room.
                if let number {
                    Text("\(number)")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary.opacity(0.75))
                        .frame(minWidth: 26, minHeight: 26)
                        .background(Color.primary.opacity(0.07), in: Circle())
                        .accessibilityLabel("Question \(number)")
                }
                Button {
                    openReference(question.startReference)
                } label: {
                    Label(question.readingDescription, systemImage: "book")
                }
                .buttonStyle(.plain)
                // A verse reference that takes you somewhere, so it is a
                // link. ColorRules.md keeps the accent for controls and for
                // what is selected, never for links inside text — and it is
                // the same blue as the references inside the question below.
                .foregroundStyle(Color.lampLink)

                Spacer()

                if question.isChristFocused {
                    Label("Christ-focused", systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.iconOnly)
                        .help("Christ-focused question")
                }
                if showsTheme, !question.theme.isEmpty {
                    Text(question.theme.capitalized)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary.opacity(0.82))
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.09), in: Capsule())
                }

                Button(action: toggleReadAloud) {
                    Label(readAloudButtonTitle, systemImage: readAloudButtonImage)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary.opacity(0.75))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(readAloudButtonTitle)
            }

            quizText(question.question, annotations: question.questionAnnotations, weight: .semibold)

            if answerVisible {
                // The answer on a ground of its own, so an answered card is
                // told from an unanswered one by more than its height.
                VStack(alignment: .leading, spacing: 10) {
                quizText(question.answer, annotations: question.answerAnnotations, weight: .regular)

                let references = Array(Set(question.references + question.crossReferences)).sorted()
                if !references.isEmpty {
                    ScrollView(.horizontal) {
                        // Spaced as separate targets, not a run of blue.
                        HStack(spacing: 16) {
                            ForEach(references, id: \.self) { reference in
                                ScriptureReferenceButton(link: LampScriptureLink(
                                    startReference: reference
                                ), typeface: typeface,
                                   lineSpacing: LampTextScale.quizLineSpacing.clamped(lineSpacing),
                                   contextAmount: previewContextAmount)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(QuizCardSurface.answer, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            if allowsAnswerToggle {
                // Neutral, in the text's own colour: a red pill on every card
                // read as a warning beside the blue references, two accents
                // competing; the weight of the label carries it instead.
                Button(action: toggleAnswer) {
                    Label(
                        answerVisible ? "Hide Answer" : "Reveal Answer",
                        systemImage: answerVisible ? "eye.slash" : "eye"
                    )
                    .fontWeight(answerVisible ? .regular : .medium)
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(showsTheme ? 20 : 13)
        .background(
            showsTheme ? AnyShapeStyle(QuizCardSurface.card) : AnyShapeStyle(.background.secondary),
            in: RoundedRectangle(cornerRadius: showsTheme ? LampMetrics.cardRadius : 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: showsTheme ? LampMetrics.cardRadius : 10, style: .continuous)
                .strokeBorder(showsTheme ? AnyShapeStyle(Color.lampCardStroke) : AnyShapeStyle(.separator.opacity(0.45)))
                .allowsHitTesting(false)
        }
        .overlay {
            ReaderNativeContextMenuAugmenter(entries: [], openLink: activateLink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.openURL, OpenURLAction { url in
            activateLink(url)
            return .handled
        })
        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
        .onContinuousHover { phase in
            if case .active(let point) = phase { pointerInCard = point }
        }
        // Beside the reference, not in the middle of the card. The card can
        // be the height of several questions, so a popover anchored to its
        // bounds came up nowhere near the words that were clicked.
        .popover(item: $previewLink, attachmentAnchor: .point(previewAnchor)) { link in
            ScriptureReferencePopover(
                link: link,
                typeface: typeface,
                lineSpacing: LampTextScale.quizLineSpacing.clamped(lineSpacing),
                contextAmount: previewContextAmount
            )
        }
    }

    private func quizText(
        _ content: String,
        annotations: [LampVerseAnnotation],
        weight: Font.Weight
    ) -> some View {
        Text(attributedText(content, annotations: annotations))
            // The scripture it quotes opens the passage, so it reads as a link
            // rather than taking the app's accent.
            .tint(.lampLink)
            .font(.system(
                size: LampTextScale.quizText.clamped(fontSize),
                weight: weight,
                design: typeface.design
            ))
            .lineSpacing(LampTextScale.quizLineSpacing.clamped(lineSpacing))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func attributedText(
        _ content: String,
        annotations: [LampVerseAnnotation]
    ) -> AttributedString {
        var attributed = AttributedString(content)
        let characterIndices = Array(content.indices) + [content.endIndex]
        for annotation in annotations {
            guard let startReference = annotation.startReference,
                  annotation.startOffset >= 0,
                  annotation.endOffset > annotation.startOffset,
                  annotation.endOffset < characterIndices.count,
                  let link = ScriptureAnnotationLink(
                    startReference: startReference,
                    endReference: annotation.endReference
                  )?.url,
                  let start = AttributedString.Index(
                    characterIndices[annotation.startOffset],
                    within: attributed
                  ),
                  let end = AttributedString.Index(
                    characterIndices[annotation.endOffset],
                    within: attributed
                  ) else { continue }
            attributed[start..<end].link = link
        }
        return attributed
    }

    /// Where the pointer last was, as a fraction of the card.
    ///
    /// SwiftUI cannot anchor a popover to a range inside a `Text`, so there is
    /// no handle on the reference itself. The click is the next best thing and
    /// in practice the same place: the reader clicked the link, so that is
    /// where it is.
    private var pointerUnitPoint: UnitPoint {
        guard let pointerInCard, cardSize.width > 1, cardSize.height > 1 else {
            return .center
        }
        return UnitPoint(
            x: min(max(pointerInCard.x / cardSize.width, 0), 1),
            y: min(max(pointerInCard.y / cardSize.height, 0), 1)
        )
    }

    private func activateLink(_ url: URL) {
        guard linkActivationGate.shouldActivate(url, at: ProcessInfo.processInfo.systemUptime),
              let link = ScriptureAnnotationLink(url: url) else { return }
        previewAnchor = pointerUnitPoint
        previewLink = LampScriptureLink(
            startReference: link.startReference,
            endReference: link.endReference
        )
    }

    private func toggleReadAloud() {
        readAloud.toggle(
            questionID: question.id,
            text: spokenText,
            voiceIdentifier: readAloudVoice,
            rate: readAloudRate
        )
    }

    private var spokenText: String {
        var text = "Question. \(question.question)"
        if answerVisible { text += " Answer. \(question.answer)" }
        return text
    }

    private var isCurrentSpeech: Bool {
        readAloud.currentQuestionID == question.id
    }

    private var readAloudButtonTitle: String {
        guard isCurrentSpeech else { return "Read Question Aloud" }
        switch readAloud.state {
        case .stopped: return "Read Question Aloud"
        case .playing: return "Pause Reading"
        case .paused: return "Resume Reading"
        }
    }

    private var readAloudButtonImage: String {
        guard isCurrentSpeech else { return "speaker.wave.2" }
        switch readAloud.state {
        case .stopped: return "speaker.wave.2"
        case .playing: return "pause.fill"
        case .paused: return "play.fill"
        }
    }
}

/// The quiz page's layers: the window, cards one step off it, and the
/// revealed answer set into its card.
enum QuizCardSurface {
    static var page: Color { Color(nsColor: .windowBackgroundColor) }
    static var card: Color { .lampCardFill }
    static var answer: Color { Color.primary.opacity(0.05) }
}
