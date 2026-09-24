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
    private var devotionalFontSize = LampTextScale.writingPreviewText.defaultValue
    @AppStorage("devotional.lineSpacing")
    private var devotionalLineSpacing = LampTextScale.writingPreviewLineSpacing.defaultValue
    @AppStorage("devotional.typeface")
    private var devotionalTypeface = ProseTypeface.readerDefault
    @State private var selection: String?
    @State private var query = ""
    @State private var categoryFilter: String?
    @State private var moduleFilter: String?
    @AppStorage("writing.sortOrder") private var sortOrderRawValue = WritingSortOrder.titleAscending.rawValue
    @AppStorage("writing.groupBy") private var groupByRawValue = WritingGroupBy.none.rawValue
    @State private var devotionalPendingDeletion: LampDevotional?
    @State private var exportedURL: URL?
    @State private var presentationDecksByDevotionalID: [String: [LampPresentationDeck]] = [:]

    let showImporter: () -> Void
    let openReference: (Int) -> Void

    private var filteredDevotionals: [LampDevotional] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.devotionals.filter { devotional in
            guard categoryFilter == nil || normalizedCategory(devotional.category) == categoryFilter,
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
                HSplitView {
                    // Group headings are ordinary rows rather than `Section`
                    // headers. Section chrome draws a rule under the topmost
                    // heading only, in the separator's own colour, and no
                    // separator modifier suppresses or restyles it — owning the
                    // rows outright is the only way every heading gets the same
                    // rule and it can be drawn stronger than the item separators.
                    List(selection: $selection) {
                        ForEach(listSections) { section in
                            if let title = section.title {
                                sectionHeaderRow(title)
                            }
                            ForEach(Array(section.devotionals.enumerated()), id: \.element.id) { index, devotional in
                                devotionalRow(devotional)
                                if index < section.devotionals.index(before: section.devotionals.endIndex) {
                                    itemDividerRow
                                }
                            }
                        }
                    }
                    // The inset style keeps its own row margin that `listRowInsets`
                    // cannot clear, which is what stopped the group headers
                    // reaching the edges of the column.
                    .listStyle(.plain)
                    // Separator rows are intentionally one point tall. The
                    // default minimum row height otherwise surrounds each rule
                    // with a band of empty, non-interactive space; content rows
                    // remain as tall as their intrinsic content requires.
                    .environment(\.defaultMinListRowHeight, 1)
                    .contentMargins(.bottom, 52, for: .scrollContent)
                    .frame(minWidth: 235, idealWidth: 295, maxWidth: 375)
                    .overlay(alignment: .bottom) {
                        Button {
                            beginEditing(nil)
                        } label: {
                            Label("New Writing", systemImage: "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .help("Create new writing")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                    }

                    if let devotional = selectedDevotional {
                        devotionalDetail(devotional)
                    } else {
                        // There are results — none is chosen. A "no results"
                        // message here would contradict the list beside it.
                        ContentUnavailableView(
                            "No Writing Selected",
                            systemImage: "sun.max",
                            description: Text("Choose an entry in the list to read it.")
                        )
                        // Claims the pane the way the detail view does. Left at
                        // its intrinsic size, HSplitView shrinks to fit it and
                        // collapses the list into a small floating box.
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .navigationTitle("Writing")
        .searchable(text: $query, prompt: "Search writing")
        .toolbar {
            ToolbarItemGroup {
                Picker("Category", selection: $categoryFilter) {
                    Text("All Categories").tag(String?.none)
                    ForEach(devotionalCategories, id: \.self) { category in
                        Text(category.capitalized).tag(Optional(category))
                    }
                }
                .accessibilityLabel("Filter writing by category")
                .help("Filter writing by category")
                Picker("Collection", selection: $moduleFilter) {
                    Text("All Collections").tag(String?.none)
                    ForEach(devotionalCollections, id: \.id) { collection in
                        Text(collection.name).tag(Optional(collection.id))
                    }
                }
                .accessibilityLabel("Filter writing by collection")
                .help("Filter writing by collection")
                sortMenu
                groupMenu
                TextSizeMenu(
                    fontSize: $devotionalFontSize,
                    lineSpacing: $devotionalLineSpacing,
                    typeface: $devotionalTypeface,
                    defaultTypeface: ProseTypeface.readerDefault,
                    fontScale: .writingPreviewText,
                    lineSpacingScale: .writingPreviewLineSpacing,
                    help: "Adjust the reading typeface, text size, and line spacing"
                )
                if let devotional = selectedDevotional {
                    Button("Present", systemImage: "rectangle.inset.filled.and.person.filled") {
                        openWindow(
                            id: "devotional-presenter",
                            value: DevotionalPresentationRequest(devotionalID: devotional.id)
                        )
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
            Text("This removes the personal writing from this Mac. Installed module entries are never modified.")
        }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: model.devotionals) { _, _ in selectFirstIfNeeded() }
        .onChange(of: query) { _, _ in selectFirstIfNeeded() }
        .onChange(of: categoryFilter) { _, _ in selectFirstIfNeeded() }
        .onChange(of: moduleFilter) { _, _ in selectFirstIfNeeded() }
        .task { await monitorLinkedPresentationDecks() }
    }

    private var sortMenu: some View {
        Menu("Sort By", systemImage: "arrow.up.arrow.down") {
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
        .accessibilityLabel("Sort writing")
        .help("Sort writing")
    }

    private var groupMenu: some View {
        Menu("Group By", systemImage: "rectangle.3.group") {
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
        .accessibilityLabel("Group writing")
        .help("Group writing")
    }

    /// Drawn by hand rather than left to `Section(_ title:)`.
    ///
    /// The built-in header rule reaches the column edges only at the top of the
    /// list; every later group gets an inset one, so the first group looked
    /// deliberately different from the rest.
    ///
    /// `listRowInsets` does not clear the margin a header row carries, so the
    /// rule is bled back out to the column edges explicitly. `ruleBleed` is that
    /// residual margin, measured off the rendered list: header content sits 8pt
    /// inside the column on the left and 9pt on the right, and the wider of the
    /// two covers both without overhanging anything.
    private func sectionHeaderRow(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Deliberately stronger than the hairline between items, so a group
            // boundary reads as a bigger break than the rows inside it.
            Rectangle()
                .fill(Color.primary.opacity(0.28))
                .frame(height: 1)
                // `listRowInsets` does not clear the margin a row carries, so
                // the rule is bled back out to reach the column edges. The value
                // is that residual margin, measured off the rendered list.
                .padding(.horizontal, -Self.ruleBleed)
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        // A heading is a label, not a document to open.
        .selectionDisabled()
    }

    private static let ruleBleed: CGFloat = 9
    /// How far a row's content sits inside the column at its leading edge, and so
    /// the inset an item separator matches at both ends.
    private static let contentInset: CGFloat = 9
    /// Breathing room above and below each item's content.
    private static let verticalContentInset: CGFloat = 12

    private var itemDividerRow: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(height: 1)
            // `listRowInsets` leaves the plain list's residual margin in place;
            // bleed through it so item rules span the full column width.
            .padding(.horizontal, -Self.ruleBleed)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .selectionDisabled()
            .accessibilityHidden(true)
    }

    private func devotionalRow(_ devotional: LampDevotional) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(devotional.title)
                        .font(.headline)
                        .lineLimit(2)
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
                    Text(snippet)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(rowMetadata(for: devotional))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !presentationDecks(for: devotional).isEmpty {
                Image(systemName: LinkedPresentationDeckLookup.systemImage)
                    .symbolRenderingMode(.hierarchical)
                    // A status marker, not an action: it should read as quieter
                    // than the row's own text, not compete with it.
                    .foregroundStyle(.secondary)
                    .help(presentationDescription(for: devotional))
                    .accessibilityLabel(presentationDescription(for: devotional))
            }
            if devotional.isEditable {
                Menu {
                    presentationActions(for: devotional)
                    Divider()
                    Button("Edit", systemImage: "pencil") {
                        beginEditing(devotional)
                    }
                    Button("Export…", systemImage: "square.and.arrow.up") {
                        export(devotional)
                    }
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        devotionalPendingDeletion = devotional
                    }
                } label: {
                    Label("Writing Actions", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Open its presentation, edit, export, or delete this writing")
            }
        }
        .padding(.vertical, Self.verticalContentInset)
        .contentShape(Rectangle())
        .tag(devotional.id)
        .listRowInsets(EdgeInsets(
            top: 0,
            leading: Self.contentInset,
            bottom: 0,
            trailing: Self.contentInset
        ))
        // Dividers are separate, non-selectable rows. Keeping them outside this
        // row prevents the native selection background from occupying the same
        // bounds as the rule.
        .listRowSeparator(.hidden)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    // Scales with the reading size rather than sitting at a
                    // fixed `largeTitle`, so turning the text up does not
                    // leave the title looking detached from its own document.
                    Text(devotional.title)
                        .font(.system(
                            size: devotionalFontSize * 1.9,
                            weight: .bold,
                            design: devotionalTypeface.design
                        ))
                    if let subtitle = devotional.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(
                                size: devotionalFontSize * 1.25,
                                design: devotionalTypeface.design
                            ))
                            .foregroundStyle(.secondary)
                    }
                    detailMetadata(devotional)
                }

                if !devotional.keyScriptures.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Key Scripture")
                            .font(.headline)
                        // Wraps: a devotional can carry more references than the
                        // detail pane has room for on a single line.
                        WrappingRow(spacing: 8) {
                            ForEach(devotional.keyScriptures) { scripture in
                                Button(scripture.displayDescription) {
                                    openReference(scripture.startReference)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
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

                DevotionalContentView(
                    markdown: devotional.displayMarkdown,
                    libraryRootURL: model.library.rootURL,
                    devotionalID: devotional.id,
                    mediaReferences: devotional.mediaReferences,
                    fontSize: devotionalFontSize,
                    lineSpacing: devotionalLineSpacing,
                    typeface: devotionalTypeface,
                    // Without this an unwritten draft is a title over a divider
                    // over nothing, which reads as a rendering failure.
                    emptyState: AnyView(emptyDraftState(devotional)),
                    titleShownAbove: devotional.title
                )

                if let footnotes = devotional.footnotes, !footnotes.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Footnotes")
                            .font(.headline)
                        DevotionalContentView(
                            markdown: footnotes,
                            libraryRootURL: model.library.rootURL,
                            devotionalID: devotional.id,
                            mediaReferences: devotional.mediaReferences,
                            fontSize: max(devotionalFontSize - 2, 11),
                            lineSpacing: devotionalLineSpacing,
                            typeface: devotionalTypeface
                        )
                        .foregroundStyle(.secondary)
                    }
                }

                if !devotional.tags.isEmpty {
                    Text(devotional.tags.map { "#\($0)" }.joined(separator: "  "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
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

    private func rowSnippet(for devotional: LampDevotional) -> String? {
        let source = devotional.summary?.isEmpty == false
            ? devotional.summary!
            : devotional.content
        let snippet = WritingStatistics.snippet(from: source, limit: 120)
        return snippet.isEmpty ? nil : snippet
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
        let statistics = WritingStatistics.measuring(markdown: devotional.displayMarkdown)
        if statistics.wordCount > 0 {
            parts.append(statistics.readingTimeDescription)
        }
        return parts.isEmpty ? "Empty draft" : parts.joined(separator: " · ")
    }

    /// Author, date, series and length. Reading time belongs beside them: these
    /// are written to a length, and "how long is this" is part of choosing what
    /// to read next.
    private func detailMetadata(_ devotional: LampDevotional) -> some View {
        let statistics = WritingStatistics.measuring(markdown: devotional.displayMarkdown)
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
                Label(statistics.readingTimeDescription, systemImage: "clock")
                    .monospacedDigit()
            }
            if devotional.isEditable {
                Button("Edit") {
                    beginEditing(devotional)
                }
                .buttonStyle(.plain)
                .fontWeight(.semibold)
                .foregroundStyle(.tint)
                .help("Edit this writing")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
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
            return normalizedCategory(devotional.category)?.capitalized ?? "Uncategorized"
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
        Array(Set(model.devotionals.compactMap { normalizedCategory($0.category) })).sorted()
    }

    private func normalizedCategory(_ category: String?) -> String? {
        category == "sermon" ? "exhortation" : category
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
                        DevotionalContentView(
                            markdown: devotional.displayMarkdown,
                            libraryRootURL: model.library.rootURL,
                            devotionalID: devotional.id,
                            mediaReferences: devotional.mediaReferences,
                            fontSize: devotionalFontSize + 5
                        )
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

    let showImporter: () -> Void
    let openReference: (Int) -> Void

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
        Calendar.current.component(.year, from: Date())
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
        .onAppear { configureSelection() }
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

    private func quizControls(_ quiz: LampQuizModule) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Picker("Quiz", selection: $selectedModuleID) {
                    ForEach(model.quizModules) { module in
                        Text(module.name).tag(Optional(module.id))
                    }
                }
                .frame(maxWidth: 360)

                Picker("Age Group", selection: $selectedAgeGroupID) {
                    ForEach(quiz.ageGroups) { ageGroup in
                        Text("\(ageGroup.label) (\(ageGroup.ageRange))")
                            .tag(Optional(ageGroup.id))
                    }
                }
                .frame(maxWidth: 300)

                Stepper(value: $day, in: 1...maximumDay) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(selectedDateDescription)
                        Text("Day \(day)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize()

                QuizOptionsMenu()
            }

            if let description = quiz.description, !description.isEmpty {
                Text(description)
                    .foregroundStyle(.secondary)
            } else if let plan = selectedPlan {
                Text("Questions for \(plan.name)")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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
                LazyVStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedDateDescription)
                                .font(.largeTitle.bold())
                            Text("Day \(day)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(questions.count) question\(questions.count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(questions) { question in
                        questionCard(question)
                    }
                }
                .frame(maxWidth: 820)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func questionCard(_ question: LampQuizQuestion) -> some View {
        QuizQuestionCard(
            question: question,
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
    let answerVisible: Bool
    let allowsAnswerToggle: Bool
    let showsTheme: Bool
    @ObservedObject var readAloud: QuizReadAloudController
    let openReference: (Int) -> Void
    let toggleAnswer: () -> Void
    @State private var linkActivationGate = ReaderLinkActivationGate()
    @State private var previewLink: LampScriptureLink?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Button {
                    openReference(question.startReference)
                } label: {
                    Label(question.readingDescription, systemImage: "book")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)

                Spacer()

                if question.isChristFocused {
                    Label("Christ-focused", systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.iconOnly)
                        .help("Christ-focused question")
                }
                if showsTheme, !question.theme.isEmpty {
                    Text(question.theme)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Button(action: toggleReadAloud) {
                    Label(readAloudButtonTitle, systemImage: readAloudButtonImage)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(readAloudButtonTitle)
            }

            quizText(question.question, annotations: question.questionAnnotations, weight: .semibold)

            if answerVisible {
                Divider()
                quizText(question.answer, annotations: question.answerAnnotations, weight: .regular)

                let references = Array(Set(question.references + question.crossReferences)).sorted()
                if !references.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
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

            if allowsAnswerToggle {
                Button(answerVisible ? "Hide Answer" : "Reveal Answer", action: toggleAnswer)
                    .buttonStyle(.bordered)
            }
        }
        .padding(showsTheme ? 18 : 13)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: showsTheme ? 12 : 10))
        .overlay {
            RoundedRectangle(cornerRadius: showsTheme ? 12 : 10)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
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
        .popover(item: $previewLink) { link in
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

    private func activateLink(_ url: URL) {
        guard linkActivationGate.shouldActivate(url, at: ProcessInfo.processInfo.systemUptime),
              let link = ScriptureAnnotationLink(url: url) else { return }
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
