import SwiftUI
import UniformTypeIdentifiers

/// The measures a rank of tabs is drawn with, shared by the reader's tabs and
/// the Search pane's.
///
/// The bar follows the tabs macOS draws for Finder and Safari, since those
/// are the tabs people who never open a code editor already know: the tabs
/// share the bar's width, the open one is a raised rounded tab rather than
/// an underlined cell, and a tab's close button sits at its leading edge and
/// shows on hover.
///
/// Shown with one tab, as Safari shows it, rather than hidden until a second
/// as Finder does: hidden, nothing on screen said tabs existed, and the only
/// way to a second was ⌘T or the File menu (owner, 2026-11-12).
enum LibraryTabStrip {
    static let height: CGFloat = 32
    /// Below this a tab stops shrinking and the rank scrolls instead, so a
    /// title stays readable however many tabs are open.
    static let minimumCellWidth: CGFloat = 116
    static let newTabButtonWidth: CGFloat = 30
    /// The gap kept around the raised tab, so it reads as sitting in the bar
    /// rather than as a block cut out of it.
    static let inset: CGFloat = 3
    static let cornerRadius: CGFloat = 7

    /// A tab's width: an equal share of the bar, but never so narrow that a
    /// title can't be read. Below that the rank scrolls.
    static func cellWidth(available: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return minimumCellWidth }
        return max(minimumCellWidth, (available / CGFloat(count)).rounded(.down))
    }
}

/// One tab as the bar draws it.
struct LibraryTabStripItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    /// Whether someone named it, which offers the way back to the name it
    /// would otherwise take.
    let isNamed: Bool
}

/// A pane's rank of tabs, drawn the way macOS draws window tabs.
///
/// One view for the reader and for Search, so the two cannot drift: what
/// differs between them — what a new tab opens on, and what a name falls
/// back to — comes in from the pane.
struct LibraryTabBar<NewTabPopover: View>: View {
    let items: [LibraryTabStripItem]
    let selectedID: UUID
    let select: (UUID) -> Void
    let close: (UUID) -> Void
    let duplicate: (UUID) -> Void
    let rename: (UUID, String?) -> Void
    let move: (UUID, Int) -> Void
    /// The context-menu item that clears a tab's own name, e.g. "Use the
    /// Chapter's Name".
    let clearNameTitle: String
    let newTabHelp: String
    let newTab: () -> Void
    /// A popover the new-tab button presents, for a pane where a new tab is
    /// chosen before it opens. Nil where it simply opens.
    var newTabPopover: Binding<Bool>? = nil
    @ViewBuilder var popoverContent: () -> NewTabPopover

    @State private var hoveredID: UUID?
    @State private var isHoveringNewTab = false
    @State private var renamingID: UUID?
    @State private var draftName = ""
    @State private var targetedID: UUID?
    /// The tabs as last drawn, for the ⌃Tab shortcuts. A shortcut keeps the
    /// action it was first given, which captured the tabs of that moment, so
    /// ⌃Tab went from the first tab to the second and then stayed there.
    @State private var current = CurrentTabs()

    var body: some View {
        let _ = current.update(ids: items.map(\.id), selectedID: selectedID)
        // The "+" stays at the trailing edge, as in Safari, rather than
        // scrolling off with the tabs when there are more than fit.
        HStack(spacing: 0) {
            GeometryReader { proxy in
                let available = proxy.size.width - LibraryTabStrip.inset
                let width = LibraryTabStrip.cellWidth(available: available, count: items.count)
                ScrollViewReader { scroller in
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                cell(item, at: index, width: width)
                                    .id(item.id)
                            }
                        }
                        .padding(.leading, LibraryTabStrip.inset)
                        .frame(height: LibraryTabStrip.height)
                    }
                    .scrollIndicators(.never)
                    // When the tabs run past the bar, the trailing edge fades
                    // rather than cutting a title off against the "+".
                    .mask {
                        HStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: width * CGFloat(items.count) > available ? 24 : 0)
                        }
                    }
                    // A tab chosen off the edge, by ⌃Tab or from elsewhere,
                    // is brought into view.
                    .onChange(of: selectedID) { _, id in
                        withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(id) }
                    }
                }
            }
            newTabButton
                .padding(.trailing, LibraryTabStrip.inset)
        }
        .frame(height: LibraryTabStrip.height)
        // The bar a shade down from the content, so the open tab — the
        // content's own colour — reads as the page it opens on.
        .background { LibraryTabBarTrack() }
        .background {
            // ⌃Tab and ⌃⇧Tab, as in every Mac app with tabs.
            Group {
                Button("Show Next Tab") { step(by: 1) }
                    .keyboardShortcut(.tab, modifiers: .control)
                // As the back-tab character ⌃⇧Tab types, not as Tab with
                // Shift: SwiftUI matches a Tab shortcut whatever the Shift
                // key, so the two Tab shortcuts were one and the last
                // declared took both directions.
                Button("Show Previous Tab") { step(by: -1) }
                    .keyboardShortcut(KeyEquivalent("\u{19}"), modifiers: [.control, .shift])
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func step(by offset: Int) {
        if let id = current.neighbour(offset) { select(id) }
    }

    private func cell(_ item: LibraryTabStripItem, at index: Int, width: CGFloat) -> some View {
        let isSelected = item.id == selectedID
        let isHovered = hoveredID == item.id
        // A separator only between two resting tabs: beside the raised tab
        // or a hovered one, it would cut into that tab's shape.
        let next = index + 1 < items.count ? items[index + 1].id : nil
        let showsSeparator = next != nil && !isSelected && !isHovered
            && next != selectedID && next != hoveredID
        return ZStack {
            Button { select(item.id) } label: {
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Room at the leading edge for the close button, and the
                    // same at the trailing edge so the title stays centred.
                    .padding(.horizontal, 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Siblings rather than nested: a Button inside another Button's
            // label is a fight over the click.
            if items.count > 1 {
                HStack {
                    LibraryTabCloseButton(title: item.title) { close(item.id) }
                        .opacity(isHovered ? 1 : 0)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 6)
            }
        }
        .font(.subheadline)
        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .frame(width: width, height: LibraryTabStrip.height)
        .background {
            LibraryTabShape(isSelected: isSelected, isHovered: isHovered || targetedID == item.id)
                .padding(.vertical, LibraryTabStrip.inset)
                .padding(.horizontal, 1)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 1, height: 14)
                .opacity(showsSeparator ? 1 : 0)
                .offset(x: 0.5)
        }
        .contentShape(Rectangle())
        .onHover { isHovering in
            hoveredID = isHovering ? item.id : (hoveredID == item.id ? nil : hoveredID)
        }
        .help(item.title)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        // Dragged by its id, and dropped on another tab to take its place.
        .draggable(item.id.uuidString) {
            Text(item.title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: LibraryTabStrip.cornerRadius))
        }
        .dropDestination(for: String.self) { dropped, _ in
            guard let raw = dropped.first, let id = UUID(uuidString: raw),
                  id != item.id, items.contains(where: { $0.id == id }) else { return false }
            move(id, index)
            return true
        } isTargeted: { isTargeted in
            targetedID = isTargeted ? item.id : (targetedID == item.id ? nil : targetedID)
        }
        .contextMenu {
            Button("Rename Tab…") {
                draftName = item.isNamed ? item.title : ""
                renamingID = item.id
            }
            if item.isNamed {
                Button(clearNameTitle) { rename(item.id, nil) }
            }
            Button("Duplicate Tab") { duplicate(item.id) }
            if items.count > 1 {
                Divider()
                Button("Close Tab") { close(item.id) }
            }
        }
        .popover(isPresented: Binding(
            get: { renamingID == item.id },
            set: { if !$0, renamingID == item.id { renamingID = nil } }
        ), arrowEdge: .bottom) {
            renamePopover(item)
        }
    }

    private func renamePopover(_ item: LibraryTabStripItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Name this tab")
                .font(.subheadline.weight(.semibold))
            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { commitRename(item.id) }
            Text("Leave it empty to name the tab after what it shows.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { renamingID = nil }
                Button("Rename") { commitRename(item.id) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private func commitRename(_ id: UUID) {
        rename(id, draftName)
        renamingID = nil
    }

    @ViewBuilder
    private var newTabButton: some View {
        let button = Button(action: newTab) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: LibraryTabStrip.newTabButtonWidth - 4, height: LibraryTabStrip.height - 10)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHoveringNewTab ? 0.08 : 0))
                )
                .frame(width: LibraryTabStrip.newTabButtonWidth, height: LibraryTabStrip.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHoveringNewTab = $0 }
        .help(newTabHelp)
        .accessibilityLabel("New Tab")
        if let newTabPopover {
            button.popover(isPresented: newTabPopover, arrowEdge: .bottom) { popoverContent() }
        } else {
            button
        }
    }
}

/// The tab order and open tab as last drawn, read by the ⌃Tab shortcuts.
private final class CurrentTabs {
    private var ids: [UUID] = []
    private var selectedID: UUID?

    func update(ids: [UUID], selectedID: UUID) {
        self.ids = ids
        self.selectedID = selectedID
    }

    /// The tab `offset` along from the open one, wrapping at either end.
    func neighbour(_ offset: Int) -> UUID? {
        guard ids.count > 1, let index = ids.firstIndex(where: { $0 == selectedID }) else { return nil }
        return ids[((index + offset) % ids.count + ids.count) % ids.count]
    }
}

extension LibraryTabBar where NewTabPopover == EmptyView {
    init(
        items: [LibraryTabStripItem],
        selectedID: UUID,
        select: @escaping (UUID) -> Void,
        close: @escaping (UUID) -> Void,
        duplicate: @escaping (UUID) -> Void,
        rename: @escaping (UUID, String?) -> Void,
        move: @escaping (UUID, Int) -> Void,
        clearNameTitle: String,
        newTabHelp: String,
        newTab: @escaping () -> Void
    ) {
        self.init(
            items: items, selectedID: selectedID, select: select, close: close,
            duplicate: duplicate, rename: rename, move: move,
            clearNameTitle: clearNameTitle, newTabHelp: newTabHelp, newTab: newTab,
            newTabPopover: nil, popoverContent: { EmptyView() }
        )
    }
}

/// The bar behind the tabs: a shade down from the content in light, a shade
/// darker in dark, so the raised tab — drawn in the content's own colour —
/// reads as lifted out of it. A hairline under it meets the content.
private struct LibraryTabBarTrack: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(colorScheme == .dark ? Color.black.opacity(0.22) : Color.black.opacity(0.045))
            // A shape style fills the safe area unless told not to, and the
            // bar sits right under the toolbar.
            .background(.background, ignoresSafeAreaEdges: [])
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
            }
    }
}

/// The open tab raised, a hovered one tinted, the rest left as the bar.
private struct LibraryTabShape: View {
    let isSelected: Bool
    let isHovered: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LibraryTabStrip.cornerRadius, style: .continuous)
        if isSelected {
            shape
                .fill(colorScheme == .dark ? Color.white.opacity(0.13) : Color.white)
                .overlay(shape.strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07), lineWidth: 0.5))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.10), radius: 1, y: 0.5)
        } else {
            shape.fill(Color.primary.opacity(isHovered ? 0.06 : 0))
        }
    }
}

/// A tab's close button: a small cross on a circle that shows on approach.
private struct LibraryTabCloseButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.primary.opacity(isHovered ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Close Tab")
        .accessibilityLabel("Close \(title)")
    }
}
