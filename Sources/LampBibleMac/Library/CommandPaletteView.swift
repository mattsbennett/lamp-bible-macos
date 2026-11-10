import AppKit
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI

/// Where something the palette opens goes: here, a new reader tab (⌘↩) or a
/// new reader window (⌥↩). Only a place in scripture takes the last two.
enum CommandPalettePlacement {
    case here, newTab, newWindow

    /// Read from the keys held as Return or a click arrives.
    static var current: Self {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.option) { return .newWindow }
        if flags.contains(.command) { return .newTab }
        return .here
    }
}

/// One row of the palette.
struct CommandPaletteItem: Identifiable {
    enum Group: Int, CaseIterable {
        case suggested, recent, results, open, commands, sections, settings
        /// Searching the library for the words, last: what to do when
        /// nothing above is what was meant.
        case search

        var title: String {
            switch self {
            case .suggested: "Go"
            case .recent: "Recent"
            case .results: "In Your Library"
            case .open: "Open"
            case .commands: "Commands"
            case .sections: "Sections"
            case .settings: "Settings"
            case .search: "Search"
            }
        }
    }

    let id: String
    let group: Group
    let title: String
    var subtitle: String? = nil
    let systemImage: String
    /// Other words it answers to: a pane's settings, a command's other name.
    var keywords: [String] = []
    /// Whether ⌘↩ and ⌥↩ open it in a new tab or window: a place in scripture.
    var opensPlaces = false
    let perform: (CommandPalettePlacement) -> Void
}

/// ⌘K: one field that goes anywhere in Lamp. What is typed decides the top
/// row, as the passage field's does — a passage, a Strong's key, or words to
/// search for — and under it come matches from the library, things to open
/// by name, commands, sections and settings. Before anything is typed it
/// shows where you have been.
///
/// Drawn over the window rather than as a sheet, so the page stays in view,
/// and with the app's own row mark for the chosen row.
struct CommandPaletteView: View {
    /// Rows for what is typed: a passage, a key, a search.
    let typedItems: (String) -> [CommandPaletteItem]
    /// Things to open, commands, sections and settings, filtered as you type.
    let namedItems: [CommandPaletteItem]
    /// Before anything is typed.
    let recentItems: [CommandPaletteItem]
    /// Matches in the library for what is typed, worked out as typing pauses.
    let searchLibrary: (String) async -> [CommandPaletteItem]
    let close: () -> Void

    @State private var query = ""
    /// The chosen row, by what it is rather than where it sits, so library
    /// matches arriving above it do not move the choice to another row.
    @State private var highlightedID: String?
    @State private var libraryResults: [CommandPaletteItem] = []
    @State private var libraryResultsQuery = ""
    @FocusState private var isFieldFocused: Bool

    private static let perGroup = 6

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The rows in the order shown, which arrow keys move through.
    private var rows: [CommandPaletteItem] {
        guard !trimmed.isEmpty else {
            return recentItems + namedItems.filter { $0.group == .sections }
        }
        let named = namedItems
            .compactMap { item in
                CommandPaletteMatch.score(trimmed, title: item.title, keywords: item.keywords)
                    .map { (item, $0) }
            }
            .sorted { $0.1 > $1.1 }
        let typed = typedItems(trimmed)
        // A passage or a key first; the search for the words last, so that
        // "line spacing" goes to its setting and "new" to New Writing.
        var shown = typed.filter { $0.group != .search }
        if libraryResultsQuery == trimmed {
            shown += libraryResults.prefix(Self.perGroup)
        }
        for group in [CommandPaletteItem.Group.open, .commands, .sections, .settings] {
            shown += named.filter { $0.0.group == group }.prefix(Self.perGroup).map(\.0)
        }
        return shown + typed.filter { $0.group == .search }
    }

    /// Where the chosen row sits now: the top row until one is chosen, or
    /// once the chosen one is gone.
    private func highlightedIndex(in rows: [CommandPaletteItem]) -> Int {
        highlightedID.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            field(rows)
            Divider()
            if rows.isEmpty {
                Text(trimmed.isEmpty ? "Type to go anywhere in Lamp." : "Nothing matches “\(trimmed)”.")
                    .font(.callout)
                    .foregroundStyle(Color.lampSecondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                list(rows)
            }
            footer
        }
        .frame(width: 640)
        .background(Color.lampPopoverFill, in: RoundedRectangle(cornerRadius: LampMetrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LampMetrics.cardRadius, style: .continuous)
                .strokeBorder(Color.lampCardStroke)
        }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        .onAppear { isFieldFocused = true }
        .task(id: trimmed) {
            let words = trimmed
            guard words.count >= 2 else {
                libraryResults = []
                libraryResultsQuery = words
                return
            }
            // As typing pauses, not on every key: a library search reads the
            // database, and the rows for what is typed are already showing.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let found = await searchLibrary(words)
            guard !Task.isCancelled else { return }
            libraryResults = found
            libraryResultsQuery = words
        }
        .onChange(of: trimmed) { _, _ in highlightedID = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Go to anything")
    }

    private func field(_ rows: [CommandPaletteItem]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.lampSecondaryText)
            TextField("Passage, word, writing, command or setting", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .focused($isFieldFocused)
                .onSubmit { perform(rows, at: highlightedIndex(in: rows)) }
                .onKeyPress(.downArrow) {
                    move(by: 1, in: rows)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    move(by: -1, in: rows)
                    return .handled
                }
                .onKeyPress(.escape) {
                    close()
                    return .handled
                }
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    private func move(by step: Int, in rows: [CommandPaletteItem]) {
        guard !rows.isEmpty else { return }
        let index = min(max(highlightedIndex(in: rows) + step, 0), rows.count - 1)
        highlightedID = rows[index].id
    }

    private func list(_ rows: [CommandPaletteItem]) -> some View {
        let highlighted = highlightedIndex(in: rows)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                        if index == 0 || rows[index - 1].group != item.group {
                            Text(item.group.title)
                                .lampSectionHeading()
                                .padding(.horizontal, 18)
                                .padding(.top, index == 0 ? 10 : 14)
                                .padding(.bottom, 4)
                        }
                        row(item, isHighlighted: index == highlighted)
                            .id(item.id)
                            .onTapGesture { perform(rows, at: index) }
                            .onHover { if $0 { highlightedID = item.id } }
                    }
                }
                .padding(.bottom, 8)
            }
            // As tall as its rows, up to a point: a short list should not
            // sit in a tall empty box.
            .frame(height: min(Self.estimatedHeight(of: rows), 420))
            .onChange(of: highlightedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func row(_ item: CommandPaletteItem, isHighlighted: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.system(size: 14))
                .foregroundStyle(Color.lampSecondaryText)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: LampMetrics.listTitleSize))
                    .lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: LampMetrics.listCaptionSize))
                        .foregroundStyle(Color.lampSecondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isHighlighted, item.opensPlaces {
                Text("⌘↩ New Tab   ⌥↩ New Window")
                    .font(.system(size: LampMetrics.listCaptionSize))
                    .foregroundStyle(Color.lampSecondaryText)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(LampListSelection(isSelected: isHighlighted))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text("↩ Open")
            Text("↑↓ Move")
            Text("esc Close")
            Spacer()
        }
        .font(.system(size: LampMetrics.listCaptionSize))
        .foregroundStyle(Color.lampSecondaryText)
        .padding(.horizontal, 18)
        .frame(height: 30)
        .background(Color.primary.opacity(0.03))
    }

    /// The rows' height as drawn: a row with a second line is taller, and a
    /// heading opens each group.
    private static func estimatedHeight(of rows: [CommandPaletteItem]) -> CGFloat {
        var height: CGFloat = 8
        for (index, item) in rows.enumerated() {
            if index == 0 || rows[index - 1].group != item.group { height += index == 0 ? 28 : 32 }
            height += (item.subtitle?.isEmpty == false) ? 46 : 32
        }
        return height
    }

    private func perform(_ rows: [CommandPaletteItem], at index: Int) {
        guard rows.indices.contains(index) else { return }
        let item = rows[index]
        let placement = item.opensPlaces ? CommandPalettePlacement.current : .here
        close()
        item.perform(placement)
    }
}
