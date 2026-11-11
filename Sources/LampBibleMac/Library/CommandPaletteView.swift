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
    /// A second line: a library match's snippet, with its found words marked.
    var subtitle: String? = nil
    /// What kind of thing it is, or where it comes from, at the row's end:
    /// "Book", a match's module. Short, so most rows keep to one line.
    var detail: String? = nil
    let systemImage: String
    /// Other words it answers to: a pane's settings, a command's other name.
    var keywords: [String] = []
    /// Whether ⌘↩ and ⌥↩ open it in a new tab or window: a place in scripture.
    var opensPlaces = false
    /// The heading over it, when not its group's: a library match's kind;
    /// empty for none.
    var sectionTitle: String? = nil
    /// A library match's kind, whose own page Tab opens.
    var libraryLevel: CommandPaletteLibraryLevel? = nil
    var perform: (CommandPalettePlacement) -> Void = { _ in }

    var heading: String { sectionTitle ?? group.title }
}

/// One kind of the library's matches, on a page of its own, pushed over the
/// palette as Raycast pushes a command's list: the search bar names it and
/// has a way back, and Escape goes back.
struct CommandPaletteLibraryLevel: Equatable, Hashable {
    /// The kind, as the library search names it.
    let id: String
    /// Its name as a heading: "Commentaries".
    let title: String
}

/// One kind's matches from the library, best first, and whether it found
/// more than it gave: not how many, which the search doesn't count.
struct CommandPaletteLibraryGroup {
    let level: CommandPaletteLibraryLevel
    let items: [CommandPaletteItem]
    let hasMore: Bool
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
    /// Matches in the library for what is typed, worked out as typing
    /// pauses: a few of every kind that matched, or, on one kind's page
    /// (`level`), a page of that kind.
    let searchLibrary: (String, CommandPaletteLibraryLevel?) async -> [CommandPaletteLibraryGroup]
    let close: () -> Void

    @State private var query = ""
    /// The chosen row, by what it is rather than where it sits, so library
    /// matches arriving above it do not move the choice to another row.
    @State private var highlightedID: String?
    @State private var libraryGroups: [CommandPaletteLibraryGroup] = []
    /// What `libraryGroups` answer: the words, and the page they were for.
    @State private var libraryGroupsKey = LibraryKey(words: "", level: nil)
    /// One kind's page of matches, entered by Tab or "Show All"; nil for all.
    @State private var level: CommandPaletteLibraryLevel?
    /// Where the pointer was when the palette opened or the keys last moved
    /// the choice. A row the pointer merely rests on — the palette opened
    /// under it, or the list scrolled beneath it — does not take the choice;
    /// only a pointer that moves does.
    @State private var restingPointer: NSPoint?

    private static let perGroup = 6
    private static let maxListHeight: CGFloat = 420

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private struct LibraryKey: Equatable {
        var words: String
        var level: CommandPaletteLibraryLevel?
    }

    /// The rows in the order shown, which arrow keys move through, and the
    /// library kinds whose headings offer "Show All".
    private var layout: (rows: [CommandPaletteItem], showsAll: Set<String>) {
        if let level { return (levelRows(level), []) }
        guard !trimmed.isEmpty else {
            return (recentItems + namedItems.filter { $0.group == .sections }, [])
        }
        let named = namedItems
            .compactMap { item in
                CommandPaletteMatch.score(trimmed, title: item.title, keywords: item.keywords)
                    .map { (item, $0) }
            }
            .sorted { $0.1 > $1.1 }
        let typed = typedItems(trimmed)
        // A passage or a key first; then what is named so, so that "line
        // spacing" goes to its setting and "new" to New Writing; then the
        // library's matches for the words, a section a kind; the search for
        // them last.
        var shown = typed.filter { $0.group != .search }
        for group in [CommandPaletteItem.Group.open, .commands, .sections, .settings] {
            shown += named.filter { $0.0.group == group }.prefix(Self.perGroup).map(\.0)
        }
        let searchRows = typed.filter { $0.group == .search }
        guard libraryGroupsKey == LibraryKey(words: trimmed, level: nil) else { return (shown + searchRows, []) }
        let library = Self.libraryRows(libraryGroups, above: shown, below: searchRows)
        return (shown + library.rows + searchRows, library.showsAll)
    }

    /// The library's matches on the main page, a section a kind under its
    /// name: one of every kind that matched, then more of each in turn while
    /// the list has room. A kind with more than it shows offers "Show All".
    private static func libraryRows(
        _ groups: [CommandPaletteLibraryGroup],
        above: [CommandPaletteItem],
        below: [CommandPaletteItem]
    ) -> (rows: [CommandPaletteItem], showsAll: Set<String>) {
        var counts = groups.map { $0.items.isEmpty ? 0 : 1 }
        func arranged() -> [CommandPaletteItem] {
            groups.indices.flatMap { index in
                groups[index].items.prefix(counts[index]).map { item in
                    var item = item
                    item.sectionTitle = groups[index].level.title
                    item.libraryLevel = groups[index].level
                    return item
                }
            }
        }
        var grew = true
        while grew {
            grew = false
            for index in groups.indices where counts[index] < groups[index].items.count {
                counts[index] += 1
                if estimatedHeight(of: above + arranged() + below) > maxListHeight {
                    counts[index] -= 1
                } else {
                    grew = true
                }
            }
        }
        let showsAll = groups.indices
            .filter { counts[$0] > 0 && (groups[$0].hasMore || counts[$0] < groups[$0].items.count) }
            .map { groups[$0].level.id }
        return (arranged(), Set(showsAll))
    }

    /// One kind's page: its matches, searched afresh for the page. The
    /// search bar names the kind, so no heading repeats it.
    private func levelRows(_ level: CommandPaletteLibraryLevel) -> [CommandPaletteItem] {
        guard libraryGroupsKey == LibraryKey(words: trimmed, level: level) else { return [] }
        return (libraryGroups.first { $0.level == level }?.items ?? []).map { item in
            var item = item
            item.sectionTitle = ""
            return item
        }
    }

    /// Where the chosen row sits now: the top row until one is chosen, or
    /// once the chosen one is gone.
    private func highlightedIndex(in rows: [CommandPaletteItem]) -> Int {
        highlightedID.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
    }

    var body: some View {
        let layout = layout
        let rows = layout.rows
        VStack(spacing: 0) {
            field(rows)
            Divider()
            if rows.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(Color.lampSecondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                list(rows, showsAll: layout.showsAll)
            }
            footer(rows)
        }
        .frame(width: 640)
        // The shadow on the panel's shape only: on the whole view it falls
        // under the list's text too, which scrolls in its own layer.
        .background {
            RoundedRectangle(cornerRadius: LampMetrics.cardRadius, style: .continuous)
                .fill(Color.lampRaisedPanelFill)
                .shadow(color: Color.lampPanelShadow, radius: 30, y: 12)
        }
        .overlay {
            RoundedRectangle(cornerRadius: LampMetrics.cardRadius, style: .continuous)
                .strokeBorder(Color.lampCardStroke)
        }
        .onAppear { restingPointer = NSEvent.mouseLocation }
        .task(id: LibraryKey(words: trimmed, level: level)) {
            let key = LibraryKey(words: trimmed, level: level)
            // A passage or a Strong's key is a place, and a full-text match
            // for "john 3:16" or "g26" is only noise under it; on a kind's
            // own page the words are searched in that kind whatever they are.
            let isPlace = level == nil && typedItems(key.words).contains { $0.group == .suggested }
            guard key.words.count >= 2, !isPlace else {
                libraryGroups = []
                libraryGroupsKey = key
                return
            }
            // As typing pauses, not on every key: a library search reads the
            // database, and the rows for what is typed are already showing.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let found = await searchLibrary(key.words, key.level)
            guard !Task.isCancelled else { return }
            libraryGroups = found
            libraryGroupsKey = key
        }
        .onChange(of: trimmed) { _, _ in highlightedID = nil }
        .onChange(of: level) { _, _ in highlightedID = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Go to anything")
    }

    private var emptyMessage: String {
        if let level {
            if trimmed.count < 2 { return "Type to search \(level.title)." }
            // Not "no matches" before the page's own search has answered:
            // entered from a match of this kind, that would be untrue.
            guard libraryGroupsKey == LibraryKey(words: trimmed, level: level) else {
                return "Searching \(level.title)…"
            }
            return "No \(level.title) match “\(trimmed)”."
        }
        return trimmed.isEmpty ? "Type to go anywhere in Lamp." : "Nothing matches “\(trimmed)”."
    }

    /// On a kind's page the search bar says which, as Raycast's names the
    /// command it is in: a way back where the magnifying glass was, and the
    /// kind beside the words.
    private func field(_ rows: [CommandPaletteItem]) -> some View {
        HStack(spacing: 10) {
            if let level {
                Button { self.level = nil } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.lampSecondaryText)
                        .frame(width: 26, height: 26)
                        .background(Color.lampTileFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Back to all results (esc)")
                .accessibilityLabel("Back to all results")
                Text(level.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.lampTileFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.lampSecondaryText)
            }
            CommandPaletteField(
                text: $query,
                placeholder: level.map { "Search \($0.title)" } ?? "Passage, word, writing, command or setting",
                onMove: { move(by: $0, in: rows) },
                onSubmit: { perform(rows, at: highlightedIndex(in: rows)) },
                onCancel: cancel,
                onTab: { showAll(of: rows) }
            )
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    private func move(by step: Int, in rows: [CommandPaletteItem]) {
        guard !rows.isEmpty else { return }
        let index = min(max(highlightedIndex(in: rows) + step, 0), rows.count - 1)
        highlightedID = rows[index].id
        restingPointer = NSEvent.mouseLocation
    }

    private func list(_ rows: [CommandPaletteItem], showsAll: Set<String>) -> some View {
        let highlighted = highlightedIndex(in: rows)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                        if !item.heading.isEmpty, index == 0 || rows[index - 1].heading != item.heading {
                            sectionHeading(item, showsAll: item.libraryLevel.map { showsAll.contains($0.id) } ?? false)
                                .padding(.horizontal, 18)
                                .padding(.top, index == 0 ? 10 : 14)
                                .padding(.bottom, 4)
                        }
                        row(item, isHighlighted: index == highlighted)
                            .id(item.id)
                            .onTapGesture { perform(rows, at: index) }
                            .onHover { inside in
                                guard inside, NSEvent.mouseLocation != restingPointer else { return }
                                restingPointer = nil
                                highlightedID = item.id
                            }
                    }
                }
                .padding(.bottom, 8)
            }
            // As tall as its rows, up to a point: a short list should not
            // sit in a tall empty box. A longer one fades at the foot, so
            // the cut row reads as more below rather than a clipped edge.
            .frame(height: min(Self.estimatedHeight(of: rows), Self.maxListHeight))
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    if Self.estimatedHeight(of: rows) > Self.maxListHeight {
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 28)
                    }
                }
            }
            .onChange(of: highlightedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    /// A section's name, and for a library kind with more than it shows, a
    /// quiet way to see them all, as Raycast puts an accessory by a heading.
    private func sectionHeading(_ item: CommandPaletteItem, showsAll: Bool) -> some View {
        HStack(spacing: 6) {
            Text(item.heading)
                .lampSectionHeading()
            Spacer(minLength: 8)
            if showsAll, let level = item.libraryLevel {
                Button { enter(level) } label: {
                    HStack(spacing: 2) {
                        Text("Show All")
                        Image(systemName: "chevron.right").imageScale(.small)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.lampSecondaryText)
                }
                .buttonStyle(.plain)
                .help("All \(level.title) matching “\(trimmed)” (⇥)")
            }
        }
    }

    private func row(_ item: CommandPaletteItem, isHighlighted: Bool) -> some View {
        resultRow(item)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(LampListSelection(isSelected: isHighlighted))
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }

    private func resultRow(_ item: CommandPaletteItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.system(size: 15))
                .foregroundStyle(Color.lampSecondaryText)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: Self.titleSize))
                    .lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    // A library match's snippet marks the words it found,
                    // as Search's rows do, cut so the row never truncates it.
                    Text.lampMarked(CommandPaletteSnippet.clipped(subtitle, droppingLeading: item.title))
                        .font(.system(size: Self.snippetSize))
                        .foregroundStyle(Color.lampSecondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: LampMetrics.listDetailSize))
                    .foregroundStyle(Color.lampSecondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .trailing)
            }
        }
    }

    /// A launcher's rows read at a glance, a step above a list's.
    private static let titleSize: CGFloat = 15
    private static let snippetSize: CGFloat = 13

    /// The keys that work now: ⌘↩ and ⌥↩ only on a row that opens a place.
    private func footer(_ rows: [CommandPaletteItem]) -> some View {
        let opensPlaces = rows.indices.contains(highlightedIndex(in: rows))
            && rows[highlightedIndex(in: rows)].opensPlaces
        return HStack(spacing: 14) {
            hint("↩", "Open")
            if level == nil, let kind = highlightedLevel(in: rows) {
                hint("⇥", "All \(kind.title)")
            }
            if opensPlaces {
                hint("⌘↩", "New Tab")
                hint("⌥↩", "New Window")
            }
            Spacer()
            hint("↑↓", "Move")
            hint("esc", level == nil ? "Close" : "Back")
        }
        .padding(.horizontal, 18)
        .frame(height: 38)
        .background(Color.primary.opacity(0.04))
        .overlay(alignment: .top) { Divider() }
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .frame(minWidth: 22, minHeight: 20)
                .background(Color.lampTileFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.lampCardStroke)
                }
            Text(label)
                .font(.system(size: LampMetrics.listDetailSize))
                .foregroundStyle(Color.lampSecondaryText)
        }
    }

    /// The rows' height as drawn: a row with a second line is taller, and a
    /// heading opens each group.
    private static func estimatedHeight(of rows: [CommandPaletteItem]) -> CGFloat {
        var height: CGFloat = 8
        for (index, item) in rows.enumerated() {
            if !item.heading.isEmpty, index == 0 || rows[index - 1].heading != item.heading {
                height += index == 0 ? 28 : 32
            }
            height += (item.subtitle?.isEmpty == false) ? 52 : 36
        }
        return height
    }

    /// Does the row, and says whether the palette closed.
    @discardableResult
    private func perform(_ rows: [CommandPaletteItem], at index: Int) -> Bool {
        guard rows.indices.contains(index) else { return false }
        let item = rows[index]
        let placement = item.opensPlaces ? CommandPalettePlacement.current : .here
        close()
        item.perform(placement)
        return true
    }

    private func enter(_ next: CommandPaletteLibraryLevel) {
        level = next
    }

    private func highlightedLevel(in rows: [CommandPaletteItem]) -> CommandPaletteLibraryLevel? {
        let index = highlightedIndex(in: rows)
        return rows.indices.contains(index) ? rows[index].libraryLevel : nil
    }

    /// Tab: the highlighted match's kind, all of it, on its own page.
    private func showAll(of rows: [CommandPaletteItem]) {
        guard level == nil, let kind = highlightedLevel(in: rows) else { return }
        enter(kind)
    }

    /// Escape: out of a kind's page, or, from the main page, closed. Says
    /// whether it closed.
    private func cancel() -> Bool {
        if level != nil {
            level = nil
            return false
        }
        close()
        return true
    }
}

/// The palette's search field: an AppKit text field the palette owns, so
/// the palette knows where the keyboard is and hears its keys after the
/// text system has.
///
/// A SwiftUI `TextField` with `@FocusState` lost the keyboard when opened by
/// ⌘K while its focus state still read true, so nothing noticed; finding its
/// NSTextField by place to correct that could pick a field behind the
/// palette. Here the field is held, and asked directly.
///
/// It takes the keyboard as it joins the window, a few times over its first
/// moments, after a menu (a key equivalent's flash) finishes tracking, when
/// the window becomes key again, and when editing ends while it is still
/// shown. Each attempt first checks whether it already has the keyboard and
/// stops if so: a check of what is true, repeated until it holds.
///
/// Keys arrive as commands, after interpretation: Escape and ⌘. as
/// `cancelOperation:`, the arrows as `moveUp:`/`moveDown:`, Return as
/// `insertNewline:`. An input method sees each key first, so with the
/// press-and-hold accent popover open, Escape closes the popover and never
/// becomes a cancel (measured, Nov 2026: the popover shows no marked text,
/// so nothing that looks at the key earlier can tell it is open).
private struct CommandPaletteField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onMove: (Int) -> Void
    /// Each says whether the palette closed, so the field stops taking the
    /// keyboard back only then: Escape out of a kind's page leaves it open,
    /// and the field must keep the keyboard.
    let onSubmit: () -> Bool
    let onCancel: () -> Bool
    /// Tab, always kept here: it would otherwise take the keyboard away.
    let onTab: () -> Void

    final class Field: NSTextField {
        private var observers: [NSObjectProtocol] = []
        /// Set while the palette is closing, so ending the edit then doesn't
        /// take the keyboard back.
        var isLeaving = false
        /// What had the keyboard before the palette, given back when it
        /// closes, so the reader's text (arrow-key scrolling, selection)
        /// answers keys again without a click. Menu commands were measured
        /// to stay enabled with nothing focused, so this is about the
        /// keyboard, not the menus.
        private weak var previousResponder: NSResponder?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            guard newWindow == nil, let window else { return }
            isLeaving = true
            let previous = previousResponder
            // A turn later, and only if nothing has taken the keyboard since:
            // a route that focuses something (Search's field) keeps it.
            DispatchQueue.main.async {
                let current = window.firstResponder
                guard current == nil || current === window,
                      let view = previous as? NSView, view.window === window else { return }
                window.makeFirstResponder(view)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.takeKeyboard() }
                },
                center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.takeKeyboard() }
                },
            ]
            takeKeyboard()
            for delay in [0.0, 0.05, 0.15, 0.35] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.takeKeyboard() }
            }
        }

        var hasKeyboard: Bool {
            guard let editor = currentEditor() else { return false }
            return window?.firstResponder === editor
        }

        func takeKeyboard() {
            guard let window, !isLeaving, !hasKeyboard else { return }
            let before = window.firstResponder
            guard window.makeFirstResponder(self) else { return }
            if previousResponder == nil, before !== window {
                // A text field being edited answers through the window's
                // shared field editor; what to give back is the field.
                if let editor = before as? NSTextView, editor.isFieldEditor {
                    previousResponder = editor.delegate as? NSResponder
                } else {
                    previousResponder = before
                }
            }
            // Typing goes after what is there, not over it all.
            currentEditor()?.selectedRange = NSRange(location: (stringValue as NSString).length, length: 0)
        }

        private func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandPaletteField

        init(_ parent: CommandPaletteField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        // There is nothing else in the palette to type into: if editing ends
        // while it is still shown (a click elsewhere in the window), the
        // keyboard comes back on the next turn.
        func controlTextDidEndEditing(_ note: Notification) {
            guard let field = note.object as? Field else { return }
            DispatchQueue.main.async { [weak field] in field?.takeKeyboard() }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                if parent.onCancel() { (control as? Field)?.isLeaving = true }
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
                parent.onTab()
            case #selector(NSResponder.insertNewline(_:)):
                if parent.onSubmit() { (control as? Field)?.isLeaving = true }
            default:
                return false
            }
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 19)
        field.textColor = .labelColor
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        // The system's placeholder grey is too faint at this size.
        field.placeholderAttributedString = Self.placeholder(placeholder)
        field.setAccessibilityLabel("Go to anything")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        // Only when it differs: setting it on every keystroke would move the
        // caret and loop through controlTextDidChange.
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderAttributedString?.string != placeholder {
            field.placeholderAttributedString = Self.placeholder(placeholder)
        }
    }

    private static func placeholder(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.lampSecondaryText,
            .font: NSFont.systemFont(ofSize: 19),
        ])
    }
}
