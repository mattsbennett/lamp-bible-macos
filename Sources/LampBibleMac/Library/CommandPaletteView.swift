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
    @Environment(\.controlActiveState) private var activeState
    /// Where the pointer was when the palette opened or the keys last moved
    /// the choice. A row the pointer merely rests on — the palette opened
    /// under it, or the list scrolled beneath it — does not take the choice;
    /// only a pointer that moves does.
    @State private var restingPointer: NSPoint?

    private static let perGroup = 6
    private static let maxListHeight: CGFloat = 420

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
        // A passage or a key first; then what is named so, so that "line
        // spacing" goes to its setting and "new" to New Writing; then the
        // library's matches for the words; the search for them last.
        var shown = typed.filter { $0.group != .search }
        for group in [CommandPaletteItem.Group.open, .commands, .sections, .settings] {
            shown += named.filter { $0.0.group == group }.prefix(Self.perGroup).map(\.0)
        }
        if libraryResultsQuery == trimmed {
            shown += libraryResults.prefix(Self.perGroup)
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
        // Escape or ⌘. from the field, once an input method has passed it on:
        // with the press-and-hold accent popover open, Escape closes the
        // popover and never gets here.
        .onExitCommand { close() }
        // Asked once the palette is in the window, not as it appears: from
        // onAppear the request was ignored and the reader's text kept the
        // keyboard, so typing and Escape went nowhere.
        .task { isFieldFocused = true }
        // And asked again if the field loses it while the palette is open,
        // as a click on a row or the panel would take it: there is nothing
        // else in the palette to type into. Not while the app is in the
        // background, where the field may be unable to take it, and asking
        // in a loop is not asking once.
        .onChange(of: isFieldFocused) { _, focused in
            if !focused, activeState != .inactive { isFieldFocused = true }
        }
        .onAppear { restingPointer = NSEvent.mouseLocation }
        .task(id: trimmed) {
            let words = trimmed
            // A passage or a Strong's key is a place, and a full-text match
            // for "john 3:16" or "g26" is only noise under it.
            let isPlace = typedItems(words).contains { $0.group == .suggested }
            guard words.count >= 2, !isPlace else {
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
            TextField(
                "Go to anything",
                text: $query,
                // The system's placeholder grey is too faint at this size.
                prompt: Text("Passage, word, writing, command or setting")
                    .foregroundStyle(Color.lampSecondaryText)
            )
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .focused($isFieldFocused)
                // Behind the field itself, so it can find the field by
                // place: see CommandPaletteKeyboard.
                .background {
                    CommandPaletteKeyboard(close: close)
                        .accessibilityHidden(true)
                }
                .onSubmit { perform(rows, at: highlightedIndex(in: rows)) }
                .onKeyPress(.downArrow) {
                    move(by: 1, in: rows)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    move(by: -1, in: rows)
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
        restingPointer = NSEvent.mouseLocation
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

    private func row(_ item: CommandPaletteItem, isHighlighted: Bool) -> some View {
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
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(LampListSelection(isSelected: isHighlighted))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
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
            if opensPlaces {
                hint("⌘↩", "New Tab")
                hint("⌥↩", "New Window")
            }
            Spacer()
            hint("↑↓", "Move")
            hint("esc", "Close")
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
            if index == 0 || rows[index - 1].group != item.group { height += index == 0 ? 28 : 32 }
            height += (item.subtitle?.isEmpty == false) ? 52 : 36
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

/// Gives the palette's field the keyboard, and closes the palette on Escape
/// when the field doesn't have it.
///
/// Focus is checked against AppKit's first responder, not `@FocusState`,
/// which can read true while the keyboard is elsewhere: opened by ⌘K, the
/// field's focus request was lost and nothing noticed. So the field is
/// handed the keyboard as the palette appears, a few times over its first
/// moments, after a menu (a key equivalent's flash) finishes tracking, and
/// when the window becomes key again. Each attempt first asks whether the
/// field already has it and stops if so: a check of what is true, repeated
/// until it holds, not a guess at when AppKit settles.
///
/// The field is found by place: this view sits behind it, and the field is
/// the frontmost editable text field over this view's centre. A field
/// behind the palette (the library's search, say) can sit inside the
/// panel's area, so the panel's frame alone would not do, and walking the
/// window front to back puts the palette's own first. Finding none, it does
/// nothing: the keyboard stays where the reader left it rather than going
/// somewhere they didn't ask for.
///
/// Escape from the field is left to the text system, so an input method sees
/// it first. That ordering is what spares the press-and-hold accent popover:
/// it takes Escape before the field turns it into the cancel command
/// (`onExitCommand`), and it never shows as marked text, so nothing earlier
/// can tell it is open (measured, Nov 2026). From anywhere else in the window
/// — the field never took the keyboard — a key monitor closes the palette,
/// scoped to this window, since a local monitor sees every window's keys.
/// It passes Escape on to another text view with marked text, for an input
/// method that composes (Japanese, say); press-and-hold doesn't.
private struct CommandPaletteKeyboard: NSViewRepresentable {
    let close: () -> Void

    final class Controller: NSView {
        var close: () -> Void = {}
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []

        // Behind the panel, it must never take a click.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
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

        /// The palette's own text field: the frontmost editable one over
        /// this view's centre, which is the field's.
        private func field() -> NSTextField? {
            guard let root = window?.contentView, bounds.width > 0, bounds.height > 0 else { return nil }
            let centre = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            // Subviews run back to front, so search them front first.
            func search(_ view: NSView) -> NSTextField? {
                for subview in view.subviews.reversed() where !subview.isHidden {
                    if let found = search(subview) { return found }
                }
                if let field = view as? NSTextField, field.isEditable,
                   field.convert(field.bounds, to: nil).contains(centre) {
                    return field
                }
                return nil
            }
            return search(root)
        }

        private func fieldHasKeyboard() -> Bool {
            guard let field = field(), let editor = field.currentEditor() else { return false }
            return window?.firstResponder === editor
        }

        private func takeKeyboard() {
            guard let window, !fieldHasKeyboard(), let field = field() else { return }
            window.makeFirstResponder(field)
            // Typing goes after what is there, not over it all.
            if let editor = field.currentEditor() {
                editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            let isCancel = event.keyCode == 53
                || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == ".")
            guard isCancel, event.window === window, !fieldHasKeyboard() else { return event }
            if let editor = window?.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            close()
            return nil
        }

        private func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    func makeNSView(context: Context) -> Controller {
        let view = Controller()
        view.close = close
        return view
    }

    func updateNSView(_ view: Controller, context: Context) { view.close = close }
}
