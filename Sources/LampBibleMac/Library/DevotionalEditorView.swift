import AppKit
import AVFoundation
import LampCore
import LampModuleKit
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI
import UniformTypeIdentifiers

/// Identifies which devotional an editor window is for. A `nil` id opens a blank one.
struct DevotionalEditorRequest: Codable, Hashable {
    var devotionalID: String?
    /// Opens the writing with its agent pane showing: for a writing started
    /// from a reader chat, whose conversation is in that pane.
    var opensAgentPane = false
    /// Tells one new writing from the next: two asked for in turn were the
    /// same request, so the second kept the first's editor and typed into
    /// the draft it had saved. Nil for a writing that has an id.
    var draftID: UUID?

    init(devotionalID: String? = nil, opensAgentPane: Bool = false) {
        self.devotionalID = devotionalID
        self.opensAgentPane = opensAgentPane
        self.draftID = devotionalID == nil ? UUID() : nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        devotionalID = try container.decodeIfPresent(String.self, forKey: .devotionalID)
        opensAgentPane = try container.decodeIfPresent(Bool.self, forKey: .opensAgentPane) ?? false
        draftID = try container.decodeIfPresent(UUID.self, forKey: .draftID)
    }

    /// What an editor for this request is known by: the writing, or the
    /// new draft.
    var editorIdentity: String {
        devotionalID ?? draftID?.uuidString ?? "new"
    }
}

/// A tab in the writing editor's rank, for tracking which one is under the
/// pointer.
private struct HoveredDocumentTab: Hashable {
    let id: String?
}

private enum DevotionalSaveState: Equatable {
    case idle
    case saving
    case saved
    case failed(String)
}

/// Decodes a writing's media list, and keeps the answer against the JSON it
/// was decoded from.
///
/// A reference type, so the editor can ask it from a computed property: the
/// list is wanted during `body`, which runs on every keystroke, and what it
/// must never do there is parse the JSON again for an answer that changes
/// only when a picture or recording is added.
private final class DevotionalMediaReferenceCache {
    /// Doubly optional on purpose: the outer says whether anything has been
    /// decoded, the inner is the JSON itself, which is nil for a writing with
    /// no media. Without that, a writing with no media decodes on every pass.
    private var decodedFrom: String??
    private var decoded: [LampDevotionalMediaReference] = []

    func references(for json: String?) -> [LampDevotionalMediaReference] {
        if let decodedFrom, decodedFrom == json { return decoded }
        decodedFrom = .some(json)
        decoded = Self.decode(json)
        return decoded
    }

    private static func decode(_ json: String?) -> [LampDevotionalMediaReference] {
        guard let json else { return [] }
        return (try? JSONDecoder().decode(
            [LampDevotionalMediaReference].self, from: Data(json.utf8)
        )) ?? []
    }
}

/// What the workspace's debounced save watches: each open file's identity and
/// its text as it stands.
///
/// The texts are the same string values the documents hold, so building this
/// copies references. Interpolating the id and the text into one string
/// instead made a fresh copy of every open file's whole text on every body
/// pass — a couple of microseconds each time, but two 70KB files' worth of
/// garbage per pass, and the body is evaluated as the writer types.
private struct WorkspaceEditTrigger: Equatable {
    let ids: [String]
    let texts: [String]
}

private struct DevotionalWorkspaceEditorDocument: Identifiable, Equatable {
    let url: URL
    /// Where the file sits inside the workspace. This is the document's
    /// identity — a file opened by hand can live in a subdirectory, where its
    /// name alone would not tell it apart from another of the same name — and
    /// it is also the path its revisions are recorded under, which for the
    /// top-level files that have always been listed is the filename as before.
    let relativePath: String
    var text: String
    var persistedText: String
    var selection = NSRange(location: 0, length: 0)
    var externalText: String?
    var wasRemovedExternally = false
    var errorMessage: String?
    /// Whether this file was opened by hand rather than listed automatically.
    /// The listing covers the writing's companions only, so a hand-opened file
    /// is refreshed from its own URL and is not missing when absent from it.
    let isHandOpened: Bool

    init(
        url: URL,
        relativePath: String? = nil,
        text: String,
        persistedText: String,
        isHandOpened: Bool = false
    ) {
        self.url = url
        self.relativePath = relativePath ?? url.lastPathComponent
        self.text = text
        self.persistedText = persistedText
        self.isHandOpened = isHandOpened
    }

    var id: String { relativePath }
    var isDirty: Bool { text != persistedText }
    var hasExternalConflict: Bool { externalText != nil || wasRemovedExternally }
}

/// What a save writes as a devotional's body.
/// A transition waiting to be written to a document's revision history.
///
/// Recording walks the whole revision folder, so it happens off the main actor
/// once the file itself is written. The editor hands over what to record rather
/// than waiting for it.
private struct PendingWorkspaceRevision {
    let kind: DevotionalAgentRevisionKind
    let before: String
    let after: String
    /// The chat turn that made this change, where the agent made it.
    ///
    /// The workspace's other documents are the agent's to write too, and
    /// an undo of a turn refuses rather than restore half of it — so a
    /// change left unmarked here does not read as "a change this turn did
    /// not make". It reads as nothing at all, and the refusal never comes.
    var turnID: UUID? = nil
}

private struct DevotionalRevisionHistoryRequest: Identifiable {
    let id = UUID()
    let documentID: String?
    let documentPath: String
    let documentTitle: String
    let revisions: [DevotionalAgentRevision]
}

private struct NewWorkspaceMarkdownDocumentSheet: View {
    let create: (String) -> String?

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFilenameFocused: Bool
    @State private var filename = ""
    @State private var errorMessage: String?

    private var normalizedFilename: String? {
        WorkspaceTextFileStore.normalizedMarkdownFilename(filename)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Markdown File")
                .font(.title2.bold())
            Text("Create a companion document beside Main Prose. If you omit the extension, Lamp adds `.md`.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("Filename", text: $filename, prompt: Text("outline.md"))
                .focused($isFilenameFocused)
                .onChange(of: filename) { _, _ in errorMessage = nil }

            if let normalizedFilename, normalizedFilename != filename {
                Text("Will create \(normalizedFilename)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { createDocument() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalizedFilename == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { isFilenameFocused = true }
    }

    private func createDocument() {
        guard normalizedFilename != nil else { return }
        if let error = create(filename) {
            errorMessage = error
        } else {
            dismiss()
        }
    }
}

/// Which surface the author types on.
private enum DevotionalEditorMode: String, CaseIterable, Identifiable {
    case visual
    case markdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .visual: "Visual"
        case .markdown: "Markdown"
        }
    }

    var systemImage: String {
        switch self {
        case .visual: "textformat"
        case .markdown: "chevron.left.forwardslash.chevron.right"
        }
    }

    var help: String {
        switch self {
        case .visual: "Write with formatting applied as you type"
        case .markdown: "Write in Markdown source"
        }
    }
}

/// The line between two panes, dragged to resize one of them. The pane it
/// resizes is the one after it — to the right, or below — unless it says the
/// one before.
///
/// The size the person chose and the size shown are kept apart: a smaller
/// window clamps what's shown without touching the choice, so the pane comes
/// back to it when there's room again. A drag starts from what's shown.
struct PaneResizeHandle: View {
    enum ResizedPane {
        case before
        case after
    }

    let axis: Axis
    var resizes: ResizedPane = .after
    @Binding var preferredSize: Double
    let displayedSize: Double
    let minimumSize: Double
    let maximumSize: Double

    @State private var sizeAtDragStart: Double?
    @State private var isShowingResizeCursor = false

    var body: some View {
        Divider()
            .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
            .frame(maxWidth: axis == .vertical ? .infinity : nil, maxHeight: axis == .horizontal ? .infinity : nil)
            .overlay {
                // Keep the separator visually light while making it forgiving
                // enough to grab beside a text editor or terminal.
                Color.clear
                    .frame(width: axis == .horizontal ? 9 : nil, height: axis == .vertical ? 9 : nil)
                    .contentShape(Rectangle())
                    .onHover { isHovering in
                        setResizeCursor(isHovering)
                    }
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                let start = sizeAtDragStart ?? displayedSize
                                sizeAtDragStart = start
                                let moved = axis == .horizontal ? value.translation.width : value.translation.height
                                preferredSize = min(
                                    max(resizes == .after ? start - moved : start + moved, minimumSize),
                                    maximumSize
                                )
                            }
                            .onEnded { _ in sizeAtDragStart = nil }
                    )
                    .onDisappear { setResizeCursor(false) }
            }
            .zIndex(1)
            // Dragging is the only other way to size the pane, so VoiceOver
            // and Full Keyboard Access get the same range as a slider.
            .accessibilityRepresentation {
                // A window too narrow to resize the pane leaves a range of one
                // size, and a Slider over it traps (opening the agent pane in
                // a narrow window crashed).
                if maximumSize > minimumSize {
                    Slider(
                        value: Binding(
                            get: { displayedSize },
                            set: { preferredSize = min(max($0, minimumSize), maximumSize) }
                        ),
                        in: minimumSize...maximumSize,
                        step: min(10, maximumSize - minimumSize)
                    ) {
                        Text(axis == .horizontal ? "Pane width" : "Pane height")
                    }
                } else {
                    Text(axis == .horizontal ? "Pane width" : "Pane height")
                }
            }
    }

    private func setResizeCursor(_ isShowing: Bool) {
        guard isShowing != isShowingResizeCursor else { return }
        isShowingResizeCursor = isShowing
        if isShowing {
            (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
        } else {
            NSCursor.pop()
        }
    }
}

private struct DevotionalToolbarScrollState: Equatable {
    var offset: CGFloat = 0
    var maximumOffset: CGFloat = 0

    var canScrollBackward: Bool { offset > 2 }
    var canScrollForward: Bool { maximumOffset - offset > 2 }
}

/// A format bar control: a quiet glyph that lights on hover and press, and
/// takes the accent while what it sets is in force at the caret.
///
/// Bordered buttons drew every control as a grey lozenge, and a row of
/// sixteen lozenges read as a form above the writing rather than as tools
/// beside it.
struct FormatBarButtonStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        FormatBarButtonBody(configuration: configuration, isActive: isActive)
    }
}

private struct FormatBarButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isActive: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    /// On is a filled, neutral key, as the format controls in Pages and
    /// Notes show it: a faint red tint was both too quiet to find and the
    /// only colour in the bar, so it looked arbitrary.
    private var fill: Color {
        if isActive { return Color.primary.opacity(configuration.isPressed ? 0.2 : 0.14) }
        if configuration.isPressed { return Color.primary.opacity(0.14) }
        if isHovered, isEnabled { return Color.primary.opacity(0.07) }
        return .clear
    }

    var body: some View {
        configuration.label
            .font(.system(size: 15, weight: isActive ? .semibold : .regular))
            .foregroundStyle(Color.primary.opacity(isEnabled ? 1 : 0.3))
            .padding(.horizontal, 7)
            .frame(minWidth: 30, minHeight: 28)
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { isHovered = $0 }
    }
}

private struct DevotionalEditorToolbarScrollView<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var scrollState = DevotionalToolbarScrollState()
    @State private var scrollPosition = ScrollPosition(x: 0)
    @State private var containerWidth: CGFloat = 0

    private let scrollStep: CGFloat = 240

    var body: some View {
        ScrollView(.horizontal) {
            // Centred over the writing while there is room, as the column of
            // text below it is; scrolled only when the window is too narrow.
            content
                .frame(minWidth: containerWidth, alignment: .center)
                // The width arrives from `onGeometryChange`, which reports a
                // layout that has already happened and so lands outside the
                // transaction that is animating the pane. Without this the
                // editor slid while the bar above it jumped to its new centre
                // in one step. Attached to the value, not to the change, for
                // the reason `Animation.lampPaneReveal` gives.
                .animation(.lampPaneReveal, value: containerWidth)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
        .scrollIndicators(.hidden)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: DevotionalToolbarScrollState.self) { geometry in
            let offset = max(geometry.contentOffset.x, 0)
            let maximumOffset = max(geometry.contentSize.width - geometry.containerSize.width, 0)
            return DevotionalToolbarScrollState(
                offset: min(offset, maximumOffset),
                maximumOffset: maximumOffset
            )
        } action: { _, state in
            scrollState = state
        }
        .overlay(alignment: .leading) {
            if scrollState.canScrollBackward {
                scrollAffordance(direction: .backward)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .trailing) {
            if scrollState.canScrollForward {
                scrollAffordance(direction: .forward)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: scrollState)
    }

    private enum Direction {
        case backward
        case forward
    }

    private func scrollAffordance(direction: Direction) -> some View {
        let background = Color(nsColor: .controlBackgroundColor)
        return Button {
            let delta = direction == .forward ? scrollStep : -scrollStep
            let target = min(max(scrollState.offset + delta, 0), scrollState.maximumOffset)
            withAnimation(.easeInOut(duration: 0.2)) {
                scrollPosition.scrollTo(x: target)
            }
        } label: {
            ZStack {
                LinearGradient(
                    colors: direction == .forward
                        ? [.clear, background.opacity(0.98)]
                        : [background.opacity(0.98), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                Image(systemName: direction == .forward ? "chevron.right" : "chevron.left")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .background(.regularMaterial, in: Circle())
            }
            .frame(width: 42)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(direction == .forward ? "Scroll toolbar right" : "Scroll toolbar left")
        .accessibilityLabel(direction == .forward ? "Scroll toolbar right" : "Scroll toolbar left")
    }
}

/// The writing window: the editor, with the reader's writing listed beside
/// it so another can be opened in its place, as a writing app's library sits
/// beside its page. Without the list the only way back to the rest of one's
/// writing was another window.
struct WritingEditorWindow: View {
    /// The window's own value: the writing open here, the one asked for and
    /// then whichever is chosen. Kept as the window's value, so asking for a
    /// writing again finds the window showing it, not the one it opened on.
    @Binding var request: DevotionalEditorRequest?

    @EnvironmentObject private var model: LibraryModel
    @AppStorage("writing.editorShowsLibrary") private var showsLibrary = true
    /// For a window restored without its value.
    @State private var blank = DevotionalEditorRequest()

    private var shown: DevotionalEditorRequest { request ?? blank }

    @State private var query = ""
    @State private var category: String?
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(LampReadingMode.defaultsKey) private var readingModeRawValue = LampReadingMode.silent.rawValue
    @AppStorage(LampReadingMode.silent.wordsPerMinuteKey)
    private var silentWordsPerMinute = LampReadingMode.silent.defaultWordsPerMinute
    @AppStorage(LampReadingMode.aloud.wordsPerMinuteKey)
    private var aloudWordsPerMinute = LampReadingMode.aloud.defaultWordsPerMinute

    private var writings: [LampDevotional] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.devotionals
            .filter(\.isEditable)
            .filter { category == nil
                || LampWritingCategory.foldedKey($0.category) == LampWritingCategory.foldedKey(category) }
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                || ($0.content.localizedCaseInsensitiveContains(query)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        HStack(spacing: 0) {
            // By width, so the editor beside it moves with it rather than
            // jumping once the list has gone (see `LampPaneWidth`).
            HStack(spacing: 0) {
                library
                    .frame(width: 304)
                Divider()
            }
            .lampPaneWidth(showsLibrary ? 305 : 0)
            // A new editor for each writing: the one going saves what it has
            // as it goes (`flushPendingSaves`), and nothing of it is carried
            // into the next.
            // The way back, named: the writing is saved as it is typed, so
            // being done is closing the window, back to the library.
            DevotionalEditorView(request: shown)
                .id(shown.editorIdentity)
                .environment(\.writingEditorDone, WritingEditorDone(help: "Close the editor and go back to Writing") {
                    dismissWindow()
                })
        }
        // Attached to the value, not left to the toggle's `withAnimation`:
        // `showsLibrary` lives in defaults, whose change is published on its
        // own turn of the run loop, outside that transaction. See
        // `Animation.lampPaneReveal`.
        .animation(.lampPaneReveal, value: showsLibrary)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(showsLibrary ? "Hide Writing List" : "Show Writing List", systemImage: "sidebar.left") {
                    withAnimation(.lampPaneReveal) { showsLibrary.toggle() }
                }
                .help(showsLibrary ? "Hide the list of writing" : "Show the list of writing")
            }
        }
        .toolbarLabelsFit(from: ToolbarLabelFit.writingEditor)
    }

    /// The Writing section's list as it is there: the same search over it,
    /// and rows with their opening words and date, chosen in the same grey.
    private var library: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search writing", text: $query)
                        .textFieldStyle(.plain)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.lampTileFill))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.lampCardStroke))
                Button("New Writing", systemImage: "plus") {
                    request = DevotionalEditorRequest()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Create new writing")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, LampWritingCategory.kindsHeld(model.devotionals.map(\.category)).count > 1 ? 8 : 10)
            categoryChips
            Divider()
            List(selection: Binding(
                get: { shown.devotionalID },
                set: { id in if let id, id != shown.devotionalID { request = DevotionalEditorRequest(devotionalID: id) } }
            )) {
                Section {
                    ForEach(writings) { writing in
                        row(writing)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    /// The library's category chips, so the list is filtered here as it is
    /// there.
    @ViewBuilder
    private var categoryChips: some View {
        let categories = LampWritingCategory.kindsHeld(model.devotionals.map(\.category))
        if categories.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    chip("All", count: model.devotionals.filter(\.isEditable).count, category: nil)
                    ForEach(categories, id: \.self) { kind in
                        chip(
                            LampWritingCategory.displayName(kind) ?? kind,
                            count: model.devotionals.filter {
                                $0.isEditable && LampWritingCategory.foldedKey($0.category) == LampWritingCategory.foldedKey(kind)
                            }.count,
                            category: kind
                        )
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 10)
        }
    }

    /// As the library's chips are, with their counts.
    private func chip(_ title: String, count: Int, category kind: String?) -> some View {
        let isChosen = LampWritingCategory.foldedKey(category) == LampWritingCategory.foldedKey(kind)
            || (kind == nil && category == nil)
        return Button { category = kind } label: {
            Text("\(title) \(Text("\(count)").foregroundStyle(Color.lampSecondaryText))")
                .lampFilterChip(isChosen: isChosen, compact: true)
        }
        .buttonStyle(.plain)
    }

    private func rowMetadata(_ writing: LampDevotional) -> String {
        let mode = LampReadingMode(storedValue: readingModeRawValue)
        let pace = mode == .aloud ? aloudWordsPerMinute : silentWordsPerMinute
        var parts = [displayDate(writing.date)].compactMap { $0 }
        let statistics = WritingRowSummaries.shared.statistics(for: writing)
        if statistics.wordCount > 0 {
            parts.append(statistics.readingTimeDescription(mode: mode, wordsPerMinute: pace))
        }
        return parts.isEmpty ? "Empty draft" : parts.joined(separator: " · ")
    }

    /// A stored date as the library shows it, or as stored if unreadable.
    private func displayDate(_ stored: String?) -> String? {
        guard let stored, !stored.isEmpty else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: String(stored.prefix(10))) else { return stored }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func row(_ writing: LampDevotional) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(writing.title)
                .font(.system(size: LampMetrics.listTitleSize, weight: .medium))
                .lineLimit(2)
            if let snippet = WritingRowSummaries.shared.snippet(for: writing) {
                Text(snippet)
                    .font(.system(size: LampMetrics.listDetailSize))
                    .foregroundStyle(Color.lampSecondaryText)
                    .lineLimit(2)
                    .lineSpacing(1)
            }
            // The library row's line: its date and how long it takes to read.
            Text(rowMetadata(writing))
                .font(.system(size: LampMetrics.listCaptionSize))
                .foregroundStyle(Color.lampSecondaryText)
        }
        .padding(.vertical, 5)
        .listRowSeparator(.visible)
        .tag(Optional(writing.id))
        .lampListRow(isSelected: shown.devotionalID == writing.id)
    }
}

struct DevotionalEditorView: View {
    let request: DevotionalEditorRequest

    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("devotional.editor.fontSize")
    private var editorFontSize = LampTextScale.writingEditorText.defaultValue
    /// The face the writing is read in, from the Writing section's text menu,
    /// so the visual editor sets it as the preview does.
    @AppStorage("devotional.typeface") private var writingTypeface = ProseTypeface.readerDefault
    @AppStorage("devotional.editor.showsDetails") private var showsDetails = true
    @AppStorage("devotional.editor.detailsWidth") private var detailsWidth = 320.0
    @AppStorage("devotional.editor.agentWidth") private var agentWidth = 480.0
    @AppStorage("agent.moduleAccess.enabled") private var agentModuleAccessEnabled = true
    @AppStorage("agent.moduleAccess.scope") private var agentModuleAccessScope = AgentModuleAccessScope.enabledModules.rawValue
    @AppStorage("agent.moduleAccess.personal") private var agentPersonalContentEnabled = false
    @State private var showingAgentWorkspace = false
    /// The chat turn running in the agent pane, where one is open.
    ///
    /// Held here rather than in that pane because the agent writes to the
    /// workspace's other documents as well as the draft, and those are
    /// this view's to record. Nil while no turn is running, and while the
    /// pane is closed — a run outlives its pane, and a change nobody was
    /// watching is a change nobody can say the turn made.
    @State private var agentChatTurn: UUID?
    /// Done, where the host gives one: the way back from editing.
    @Environment(\.writingEditorDone) private var done
    /// Whether AI features are shown (`AIFeatures`): off, the editor has no
    /// Agent button and no agent pane. The workspace on disk is kept.
    @AppStorage(AIFeatures.key) private var aiFeaturesEnabled = AIFeatures.defaultValue
    @State private var linkedPresentationDecks: [LampPresentationDeck] = []
    @State private var isOpeningPresentation = false
    @State private var workspaceDocuments: [DevotionalWorkspaceEditorDocument] = []
    @State private var selectedWorkspaceDocumentID: String?
    /// Which tab the pointer is over. A wrapper, because a tab's id is itself
    /// optional — the writing's own prose has none — and `String??` says
    /// nothing a reader can follow.
    @State private var hoveredDocumentTab: HoveredDocumentTab?
    @State private var hoveredTabBarButton: String?
    @State private var workspaceIsAvailable = false
    @State private var workspaceDocumentsInitialized = false
    /// Why the last attempt to open a workspace file failed. Not a document's
    /// own error, because the file never became one.
    @State private var workspaceDocumentError: String?
    @State private var revisionHistoryRequest: DevotionalRevisionHistoryRequest?
    @State private var showingNewWorkspaceDocument = false

    /// Visual editing is deliberately the approachable default; Markdown is the
    /// source surface behind it.
    @State private var editorMode: DevotionalEditorMode = .visual
    @State private var identifier = UUID().uuidString
    @State private var createdDate: Date?
    @State private var title = ""
    @State private var subtitle = ""
    @State private var author = ""
    @State private var date = ""
    @State private var tags = ""
    @State private var category = DevotionalEditorView.firstKindOffered

    /// The kind as the library holds it, which is not always how it is shown:
    /// a `sermon` reads as Exhortation and a `Prayer` as a prayer. Kept so an
    /// autosave of someone else's spelling leaves it alone — the writing is
    /// saved every 1.5 seconds, and none of those saves was a decision to
    /// rename its kind.
    @State private var originalCategory: String?
    @State private var seriesName = ""
    @State private var seriesOrder = 0
    @State private var summary = ""
    @State private var content = ""
    @State private var originalContentJSON: String?
    @State private var originalPlainContent = ""
    @State private var originalProjectedMarkdown = ""
    @State private var mediaJSON: String?
    /// Holds the media list last decoded from `mediaJSON`, so reading
    /// `mediaReferences` from `body` is a comparison rather than a parse.
    @State private var mediaCache = DevotionalMediaReferenceCache()
    @State private var footnotes = ""
    @State private var keyScriptures: [LampScriptureLink] = []

    @State private var contentSelection = NSRange(location: 0, length: 0)
    /// Where the caret sits in the Footnotes field, so that clicking a marker
    /// whose note is kept there can put the writer on that line.
    @State private var footnotesSelection = NSRange(location: 0, length: 0)
    @State private var footnotesRevealToken = 0
    /// Inspector groups the writer has opened or closed by hand. A group
    /// left alone is open while it holds something and folded while empty.
    @State private var foldedOpen: [String: Bool] = [:]
    @State private var tipTapCoordinator: TipTapEditorCoordinator?
    /// The copy of the writing this editor holds, said to a phone's turn
    /// (`WritingChatTurns.watched`).
    @State private var writingHold: WritingHold?
    /// Gone from screen: a save finishing after that does not take a hold
    /// it would never give up.
    @State private var editorIsGone = false
    /// When the stored copy this editor holds was saved: the one it loaded,
    /// or its own last save. Every save is made only over that copy, so a
    /// newer one sync brings in while the writing is open is never written
    /// over by the editor's older text. Nil for a writing not stored yet.
    @State private var heldRevision: Date?
    /// A newer stored copy than the one held, arrived while this editor had
    /// edits of its own, and those edits not yet kept elsewhere. Nothing is
    /// saved while it is here.
    @State private var newerCopy: LampDevotional?
    /// Why the edits could not be kept as a copy, when they could not.
    @State private var keepingFailed: String?
    /// The copy this conflict's edits are kept in, once one is stored, so
    /// another pass or a retry writes to it rather than making a second.
    @State private var keptCopyID: String?
    /// When that copy was last written by this editor: later passes write
    /// over it only if it is still that copy, not one edited elsewhere.
    @State private var keptCopyRevision: Date?
    /// A newer copy is being weighed against the page, which is read first.
    @State private var isWeighingNewerCopy = false
    /// The writer's edits, kept as a writing of their own when a newer
    /// version came in over them, for the status bar to say so.
    @State private var keptEdits: LampDevotional?
    /// What the assistant changed that the writer has not yet read, where
    /// they keep marks (`WritingReviewMarks`).
    @StateObject private var reviewSession = WritingReviewSession()
    @AppStorage(WritingReviewMarks.key) private var reviewMarksEnabled = LampPreferenceDefaults.writingReviewMarksEnabled
    @State private var tipTapSelection = TipTapSelectionState()
    /// The text selected in the visual editor, read from the page a moment
    /// after the selection settles, while the agent pane is open to be told.
    @State private var visualSelectedText = ""
    @State private var visualSelectionRead: Task<Void, Never>?
    @State private var visualEditorIsReady = false
    @State private var find = WritingFindController()
    @State private var markdownFinder = MarkdownTextFinder()
    /// The count and reading time the status bar shows, measured once the
    /// text has settled rather than inside `body`.
    ///
    /// Measuring walks the whole document and builds a prose copy of it to
    /// count. In `body` that ran on every keystroke, and the cost grew with
    /// the writing — which is the wrong way round, since it is the long
    /// writing whose typing must stay smooth.
    @State private var statistics = WritingStatistics(wordCount: 0, characterCount: 0)
    /// Whether anything has been counted yet, so the first count is immediate
    /// and a writing never opens reading "No words".
    @State private var hasMeasuredStatistics = false
    @State private var saveState: DevotionalSaveState = .idle
    /// Identifies this editor to the quit hook, for as long as it is on screen.
    @State private var pendingWritesID = UUID()
    @State private var showingAudioRecorder = false
    @State private var hasLoaded = false
    /// The document as last written to the library. Dirtiness is this compared with
    /// the live fields — a snapshot rather than a flag, so no ordering between
    /// loading and change-tracking can leave a freshly opened devotional "edited".
    @State private var savedFields: [String] = []

    /// Every value a save would persist.
    private var editedFields: [String] {
        [
            title, subtitle, author, date, tags, category, seriesName,
            String(seriesOrder), summary, content, footnotes,
            keyScriptures.map(\.id).joined(separator: "|"),
            mediaJSON ?? "",
        ]
    }

    /// The writing's media, decoded once per change of `mediaJSON`.
    ///
    /// This is read from `body` — the visual editor is handed the list, and
    /// asks it for its media map — and `body` runs on every keystroke, so
    /// decoding here put a JSON parse of every picture and recording in the
    /// writing on the typing path. The cache is asked for the JSON in hand
    /// rather than told when it changes, because `addMedia` reads this in the
    /// same breath as it appends to `mediaJSON` (see `updateRichMediaIDs`),
    /// where anything updated on a later pass would answer with the media as
    /// it was before.
    private var mediaReferences: [LampDevotionalMediaReference] {
        mediaCache.references(for: mediaJSON)
    }

    private var isDirty: Bool {
        hasLoaded && editedFields != savedFields
    }

    private var workspaceURL: URL {
        DevotionalAgentWorkspaceFiles.workspaceURL(
            libraryRootURL: model.library.rootURL,
            devotionalID: identifier
        )
    }

    private var activeWorkspaceDocument: DevotionalWorkspaceEditorDocument? {
        guard let selectedWorkspaceDocumentID else { return nil }
        return workspaceDocuments.first { $0.id == selectedWorkspaceDocumentID }
    }

    private var isEditingPrimaryDocument: Bool {
        activeWorkspaceDocument == nil
    }

    private var activeText: String {
        activeWorkspaceDocument?.text ?? content
    }

    /// Whether the open document can be written visually: the writing itself
    /// or any Markdown file beside it. A plain text file isn't Markdown, so it
    /// stays in the Markdown editor, which keeps it exactly as written.
    private var activeDocumentSupportsVisual: Bool {
        guard let document = activeWorkspaceDocument else { return true }
        return WorkspaceTextFileStore.isMarkdown(document.url)
    }

    private var isEditingVisually: Bool {
        activeDocumentSupportsVisual && editorMode == .visual
    }

    private var activeEditorMode: DevotionalEditorMode {
        activeDocumentSupportsVisual ? editorMode : .markdown
    }

    private var activeRevisionDocumentPath: String? {
        guard let document = activeWorkspaceDocument else {
            return DevotionalAgentRevisionStore.primaryDocumentPath
        }
        return supportsRevisionHistory(document.url) ? document.id : nil
    }

    private var activeTextBinding: Binding<String> {
        guard let selectedWorkspaceDocumentID else { return $content }
        return Binding(
            get: {
                workspaceDocuments.first { $0.id == selectedWorkspaceDocumentID }?.text ?? ""
            },
            set: { text in
                guard let index = workspaceDocuments.firstIndex(where: {
                    $0.id == selectedWorkspaceDocumentID
                }) else { return }
                workspaceDocuments[index].text = text
                workspaceDocuments[index].errorMessage = nil
            }
        )
    }

    private var activeSelectionBinding: Binding<NSRange> {
        guard let selectedWorkspaceDocumentID else { return $contentSelection }
        return Binding(
            get: {
                workspaceDocuments.first { $0.id == selectedWorkspaceDocumentID }?.selection
                    ?? NSRange(location: 0, length: 0)
            },
            set: { selection in
                guard let index = workspaceDocuments.firstIndex(where: {
                    $0.id == selectedWorkspaceDocumentID
                }) else { return }
                workspaceDocuments[index].selection = selection
            }
        )
    }

    /// What the writing chat is told the editor has open and selected.
    private var editorFocus: WritingEditorFocus {
        let document = selectedWorkspaceDocumentID.flatMap { id in
            workspaceDocuments.first { $0.id == id }
        }
        let path = document?.relativePath ?? LampWritingWorkspace.draftFilename
        let name = document == nil ? "Main Prose" : path
        guard !isEditingVisually else {
            return WritingEditorFocus(
                documentPath: path, documentName: name, isVisual: true,
                selectedText: visualSelectedText
            )
        }
        return .markdown(
            documentPath: path,
            documentName: name,
            text: activeTextBinding.wrappedValue,
            selection: activeSelectionBinding.wrappedValue
        )
    }

    /// The page's selection, read once it has stopped changing: it reports a
    /// change for every caret move, which is every keystroke, and the text is
    /// a trip into the page.
    private func readVisualSelectionSoon() {
        visualSelectionRead?.cancel()
        guard showingAgentWorkspace else { return }
        visualSelectionRead = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let tipTapCoordinator else { return }
            tipTapCoordinator.getSelectedText { text in
                let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if visualSelectedText != text { visualSelectedText = text }
            }
        }
    }

    private var workspaceDocumentEditTrigger: WorkspaceEditTrigger {
        WorkspaceEditTrigger(
            ids: workspaceDocuments.map(\.id),
            texts: workspaceDocuments.map(\.text)
        )
    }

    private var hasSavableContent: Bool {
        [title, subtitle, author, tags, seriesName, summary, content, footnotes]
            .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || !keyScriptures.isEmpty
    }

    var body: some View {
        GeometryReader { geometry in
            let usesSidePane = showsDetails || showingAgentWorkspace
            let dividerWidth = 1.0
            let minimumEditorWidth = 360.0
            let preferredSidebarWidth = showingAgentWorkspace ? agentWidth : detailsWidth
            let desiredMinimumSidebarWidth = showingAgentWorkspace ? 360.0 : 240.0
            let maximumSidebarWidth = max(
                Double(geometry.size.width) - minimumEditorWidth - dividerWidth,
                0
            )
            let minimumSidebarWidth = min(desiredMinimumSidebarWidth, maximumSidebarWidth)
            let sidebarWidth = usesSidePane
                ? min(max(preferredSidebarWidth, minimumSidebarWidth), maximumSidebarWidth)
                : 0
            let editorWidth = max(
                Double(geometry.size.width) - sidebarWidth - (usesSidePane ? dividerWidth : 0),
                0
            )
            HStack(spacing: 0) {
                contentColumn
                    // Horizontal editor toolbars have a much wider intrinsic
                    // content size than the document. Give the complete editor
                    // column its exact share of the split so those ScrollViews
                    // scroll inside this viewport instead of expanding beneath
                    // the sidebar.
                    .frame(width: editorWidth, height: geometry.size.height)
                    .clipped()
                if usesSidePane {
                    PaneResizeHandle(
                        axis: .horizontal,
                        preferredSize: showingAgentWorkspace ? $agentWidth : $detailsWidth,
                        displayedSize: sidebarWidth,
                        minimumSize: minimumSidebarWidth,
                        maximumSize: maximumSidebarWidth
                    )
                }
                ZStack {
                    if showingAgentWorkspace {
                        DevotionalAgentWorkspaceView(
                            libraryRootURL: model.library.rootURL,
                            bundledModulesArchiveURL: Bundle.main.url(
                                forResource: "bundled_modules.db",
                                withExtension: "zlib"
                            ),
                            agentAccessPolicy: agentAccessPolicy,
                            devotionalID: identifier,
                            devotionalTitle: title,
                            draftMarkdown: content,
                            contextDocument: agentContextDocument,
                            editorFocus: editorFocus,
                            importDraft: { importedDraft in
                                // Held before anything else runs: the
                                // turn's marks are anchored in it, and
                                // typing before the next settle would
                                // otherwise keep it from this editor's
                                // carries and clears.
                                reviewSession.holds(importedDraft)
                                content = importedDraft
                                // Saved now rather than on the next
                                // autosave. A crash in between left
                                // the library holding the version the
                                // workspace had just moved away from,
                                // and the next open read that as the
                                // writer's newer text and put it back
                                // — undoing the undo.
                                save()
                            },
                            chatTurn: Binding(
                                get: { agentChatTurn },
                                set: { turn in
                                    guard turn != agentChatTurn else { return }
                                    // What the finishing turn wrote to
                                    // the workspace's other documents,
                                    // collected while it is still the
                                    // turn in hand. These are polled on
                                    // their own clock, and a run's last
                                    // write lands just before it ends —
                                    // so the change was regularly
                                    // picked up under no turn at all,
                                    // and an undo then put the draft
                                    // back and left those files as the
                                    // turn had made them.
                                    refreshWorkspaceDocuments()
                                    agentChatTurn = turn
                                }
                            )
                        )
                        .id(identifier)
                    }
                    // Kept in the view tree whether it is shown or not.
                    // Taking it out had AppKit validate the toolbar and draw
                    // every button disabled for about 200ms: measured as a
                    // 1.9 dip in the title bar's brightness on each close and
                    // 5.4 where the assistant displaced it, against 0.01 for
                    // putting it back. Zero width rather than removal also
                    // lets the pane slide, as the writing list does
                    // (`LampPaneWidth`).
                    detailsPane
                        .opacity(showingAgentWorkspace ? 0 : 1)
                        .allowsHitTesting(!showingAgentWorkspace)
                        .accessibilityHidden(showingAgentWorkspace)
                }
                .frame(width: sidebarWidth, height: geometry.size.height)
                .clipped()
                // A side pane, so it recedes one step from the writing, as the
                // slide studio's inspector does.
                .background(Color.lampPaneGround)
                .accessibilityHidden(!usesSidePane)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            // The side pane's flags: `showsDetails` is kept in defaults, so
            // the reveal is animated from the value rather than left to the
            // toggle's transaction (see `Animation.lampPaneReveal`). The
            // width itself is not in the list, so dragging the divider still
            // follows the pointer exactly.
            .animation(.lampPaneReveal, value: [showsDetails, showingAgentWorkspace])
            .preference(key: WritingAssistantOpenKey.self, value: showingAgentWorkspace)
            .clipped()
        }
        .frame(minWidth: 640, minHeight: 540)
        // The save state is said once, in the status bar beneath the
        // writing, where its conflict buttons sit. The title bar carried it
        // too, so a quiet document said "Up to date" twice.
        .navigationTitle(title.isEmpty ? "New Writing" : title)
        .toolbar { editorToolbar }
        .task(id: request) {
            editorMode = .visual
            load()
        }
        .task(id: identifier) { await monitorLinkedPresentationDecks() }
        .task(id: identifier) { await monitorWorkspaceDocuments() }
        // Autosave starts after any authored field has content. A newly opened,
        // untouched editor still never leaves an empty devotional behind.
        .task(id: AutosaveTrigger(fields: editedFields, canSave: hasSavableContent && newerCopy == nil)) {
            guard isDirty, hasSavableContent, newerCopy == nil else { return }
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            save()
        }
        // Counted here rather than in the status bar's own body, so a
        // keystroke does not measure the document. The pause is what keeps it
        // off the typing path; a count that lands a moment after the typing
        // stops reads the same as one that kept up with it.
        .task(id: activeText) {
            if hasMeasuredStatistics {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            // Counted off the main thread as well as off the typing path.
            // Measured with `-O` over writing from the corpus: 1.3ms for a
            // 10KB writing, 4.1ms for 30KB, around 10ms for 70KB. Even once
            // per pause, a 70KB writing would drop a frame counting itself.
            let text = activeText
            let measured = await Task.detached(priority: .utility) {
                WritingStatistics.measuring(markdown: text)
            }.value
            guard !Task.isCancelled else { return }
            statistics = measured
            hasMeasuredStatistics = true
        }
        .task(id: workspaceDocumentEditTrigger) {
            guard workspaceDocuments.contains(where: { $0.isDirty && !$0.hasExternalConflict }) else {
                return
            }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            saveDirtyWorkspaceDocuments()
        }
        .onAppear {
            LampPendingWrites.shared.register(pendingWritesID) { flushPendingSaves() }
        }
        .onDisappear {
            flushPendingSaves()
            LampPendingWrites.shared.unregister(pendingWritesID)
            editorIsGone = true
            writingHold?.release()
            writingHold = nil
        }
        .focusedSceneValue(\.writingFind, find)
        // ⌘S lives in the File menu now, not on a toolbar button: see
        // `WritingSaveKey`. What it saves is whatever is open here — the
        // writing, or the workspace file in front of it.
        .focusedSceneValue(
            \.writingSave,
            WritingSave(canSave: activeDocumentCanSave, save: saveActiveDocument)
        )
        .onChange(of: activeFindTarget.map(ObjectIdentifier.init), initial: true) {
            find.attach(activeFindTarget)
        }
        // What is selected when the agent pane opens, or another document is
        // shown, has had no change of selection to report it.
        .onChange(of: showingAgentWorkspace) { _, _ in
            readVisualSelectionSoon()
        }
        // The writing's review marks, followed while it is open and marks
        // are shown; another writing, or marks turned off, starts again.
        .task(id: ReviewFollowing(writingID: identifier, isShown: showsReviewMarks)) {
            await reviewSession.follow(
                writingID: identifier, text: content,
                libraryRootURL: model.library.rootURL, isShown: showsReviewMarks
            )
        }
        .onChange(of: content) { _, text in reviewSession.textChanged(text) }
        // Published only when the writings change, so this is not asked on
        // every keystroke. The new value is passed in: read off the model
        // here, it would still be the old one.
        .onReceive(model.$devotionals) { devotionals in lookForNewerCopy(in: devotionals) }
        // Turned off while the agent's pane is open: it closes, and the
        // details take its place as they would on closing it by hand.
        .onChange(of: aiFeaturesEnabled) { _, enabled in
            if !enabled, showingAgentWorkspace {
                withAnimation(.lampPaneReveal) {
                    showingAgentWorkspace = false
                    showsDetails = true
                }
            }
        }
        .onChange(of: selectedWorkspaceDocumentID) {
            visualSelectedText = ""
            readVisualSelectionSoon()
        }
        .sheet(isPresented: $showingAudioRecorder) {
            DevotionalAudioRecorderView(devotionalID: identifier) { storedURL in
                insertStoredAudio(storedURL)
            }
            .environmentObject(model)
        }
        .sheet(item: $revisionHistoryRequest) { request in
            DevotionalAgentRevisionHistoryView(
                documentTitle: request.documentTitle,
                revisions: request.revisions
            ) { markdown in
                restoreRevision(markdown, request: request)
            }
        }
        .sheet(isPresented: $showingNewWorkspaceDocument) {
            NewWorkspaceMarkdownDocumentSheet { proposedName in
                createWorkspaceDocument(named: proposedName)
            }
        }
    }

    /// Everything that belongs to the document itself: the writing surface and
    /// the status bar beneath it. The details and agent sidebars sit outside
    /// this, since they are about the document rather than part of it.
    private var contentColumn: some View {
        VStack(spacing: 0) {
            // Only once there is more than the writing itself to move
            // between. With the prose alone, a rank holding one tab was a
            // third band of chrome over the page; making, opening and
            // revealing workspace files are in the toolbar's Workspace menu.
            if !workspaceDocuments.isEmpty {
                documentTabBar
                Divider()
            }

            editorPane

            Divider()
            statusBar
        }
    }

    /// The Reader's tab height, so the two ranks line up.

    /// The documents open for this writing, drawn as the reader and Search
    /// draw their tabs: the rank shares the bar's width, the open one is a
    /// raised rounded tab, and a resting tab is divided from the next by a
    /// hairline.
    ///
    /// Every button here sits at the trailing edge, outside the rank and so
    /// out of the scroll. Making a new file was at the end of the rank, as
    /// the reader's new-tab button used to be; it moved with the reader's,
    /// because a button that scrolls away with the tabs is a button you
    /// cannot reach when you have most need of it.
    private var documentTabBar: some View {
        HStack(spacing: 0) {
            documentTabRank
            tabSeparator
            workspaceControls
        }
        .frame(height: LibraryTabStrip.height)
        .background { LibraryTabBarTrack() }
    }

    private var documentTabRank: some View {
        HStack(spacing: 0) {
            GeometryReader { proxy in
                let available = proxy.size.width - LibraryTabStrip.inset
                let width = LibraryTabStrip.cellWidth(
                    available: available, count: workspaceDocuments.count + 1
                )
                let ids: [String?] = [nil] + workspaceDocuments.map(\.id)
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(Array(ids.enumerated()), id: \.offset) { index, id in
                            documentTab(
                                id: id,
                                // The next tab decides the hairline: one is
                                // drawn only between two resting tabs, since
                                // beside a raised or hovered one it would cut
                                // into that tab's shape.
                                nextID: index + 1 < ids.count ? ids[index + 1] : nil,
                                isLast: index + 1 == ids.count,
                                width: width
                            )
                        }
                    }
                    .padding(.leading, LibraryTabStrip.inset)
                    .frame(height: LibraryTabStrip.height)
                }
                .scrollIndicators(.never)
            }
            // The button that adds to the rank stays at its trailing edge
            // rather than scrolling away with the tabs, as the reader's does.
            tabBarButton(
                "New Markdown File",
                systemImage: "plus",
                help: "Create a companion Markdown file"
            ) { showingNewWorkspaceDocument = true }
            .frame(width: LibraryTabStrip.newTabButtonWidth)
        }
        .frame(height: LibraryTabStrip.height)
    }

    /// What belongs to the workspace rather than to the rank, kept where it
    /// cannot scroll out of reach: a file picker, and a trip to the Finder.
    private var workspaceControls: some View {
        HStack(spacing: 10) {
            Button("Open Workspace File", systemImage: "folder.badge.plus") {
                openWorkspaceFile()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(!workspaceIsAvailable)
            .help("Open any file from this writing's workspace")

            Button("Reveal Workspace", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([workspaceURL])
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(!workspaceIsAvailable)
            .help("Reveal the writing workspace in Finder")
        }
        .padding(.horizontal, 10)
    }

    private var tabSeparator: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
    }

    /// One of the workspace controls at the end of the rank, drawn as a cell of
    /// the rank rather than as a button on top of it.
    private func tabBarButton(
        _ title: String,
        systemImage: String,
        help: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: LibraryTabStrip.height)
                .background(
                    hoveredTabBarButton == title
                        ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                    ignoresSafeAreaEdges: []
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .disabled(!isEnabled)
        .onHover { isHovering in
            hoveredTabBarButton = isHovering
                ? title : (hoveredTabBarButton == title ? nil : hoveredTabBarButton)
        }
        .help(help)
    }

    /// One document as the rank draws it, with the measures, the raised
    /// shape, the hairline and the close button the reader's and Search's
    /// tabs use — and arranged as they arrange theirs, so a click anywhere
    /// on a tab chooses it.
    ///
    /// What is this rank's own is what a tab here *is*: a file, so it can be
    /// unsaved or in conflict with what is on disk, and the writing's own
    /// prose is always first and cannot be closed. The accent underline the
    /// old cells wore is gone — the open tab is raised instead, which is how
    /// macOS has drawn window tabs since Finder and Safari took this shape.
    private func documentTab(
        id: String?,
        nextID: String??,
        isLast: Bool,
        width: CGFloat
    ) -> some View {
        let document = id.flatMap { documentID in
            workspaceDocuments.first { $0.id == documentID }
        }
        let title = document.map(title(of:)) ?? "Main Prose"
        let isDirty = document?.isDirty ?? self.isDirty
        let hasConflict = document?.hasExternalConflict ?? false
        let canClose = document?.isHandOpened ?? false
        let isSelected = selectedWorkspaceDocumentID == id
        let isHovered = hoveredDocumentTab == HoveredDocumentTab(id: id)
        // Only between two tabs that are both at rest: beside the raised tab
        // or a hovered one it would cut into that tab's shape.
        let next = nextID ?? nil
        let showsSeparator = !isLast && !isSelected && !isHovered
            && next != selectedWorkspaceDocumentID
            && HoveredDocumentTab(id: next) != hoveredDocumentTab

        return ZStack {
            // The whole cell chooses the document. Laid out as siblings
            // instead, the close button's corner of the tab answered no
            // click at all, and on a tab that cannot be closed that corner
            // was simply dead.
            Button {
                selectWorkspaceDocument(id)
            } label: {
                HStack(spacing: 5) {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Beside the title rather than at the cell's trailing
                    // edge: a tab is as wide as the bar divided by the
                    // documents open, and a mark that far from its own title
                    // reads as belonging to the tab after it.
                    //
                    // A file's state, which a reader tab has no equivalent of
                    // and which is why this rank is not simply `LibraryTabBar`.
                    if hasConflict {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("File conflict")
                    } else if isDirty {
                        Circle()
                            .fill(.secondary)
                            .frame(width: 5, height: 5)
                            .accessibilityLabel("Unsaved changes")
                    }
                }
                // Room for the close button at the leading edge, and as much
                // at the trailing edge so the title stays centred.
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Siblings rather than nested: a Button inside another Button's
            // label is a fight over the click.
            if canClose, let id {
                HStack {
                    LibraryTabCloseButton(title: title) { closeWorkspaceDocument(id) }
                        .opacity(isHovered ? 1 : 0)
                        .disabled(isDirty)
                        .help(isDirty ? "Save this file before closing it" : "Close this file")
                    Spacer(minLength: 0)
                }
                .padding(.leading, 6)
            }
        }
        .font(.subheadline)
        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        // The share it was given, and no more: padding outside this would
        // put the rank over the width it was measured for, so the last tab
        // would be clipped and the bar would scroll when everything fits.
        .frame(width: width, height: LibraryTabStrip.height)
        .background {
            LibraryTabShape(isSelected: isSelected, isHovered: isHovered)
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
            let tab = HoveredDocumentTab(id: id)
            hoveredDocumentTab = isHovering
                ? tab : (hoveredDocumentTab == tab ? nil : hoveredDocumentTab)
        }
        .help(title)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .contextMenu {
            if canClose, let id {
                // Only files opened by hand can be closed. The rest follow the
                // workspace listing, so closing one would mean nothing: the
                // next refresh would bring it straight back.
                Button("Close") { closeWorkspaceDocument(id) }
                    .disabled(isDirty)
                    .help(isDirty ? "Save this file before closing it" : "")
            }
        }
    }

    /// Takes a hand-opened file back off the tab bar. Its contents are left
    /// exactly as they are on disk.
    private func closeWorkspaceDocument(_ id: String) {
        guard let index = workspaceDocuments.firstIndex(where: {
            $0.id == id && $0.isHandOpened && !$0.isDirty
        }) else { return }
        workspaceDocuments.remove(at: index)
        if selectedWorkspaceDocumentID == id {
            selectWorkspaceDocument(nil)
        }
    }

    private func selectWorkspaceDocument(_ id: String?) {
        workspaceDocumentError = nil
        guard selectedWorkspaceDocumentID != id else { return }
        collectVisualEditorText()
        selectedWorkspaceDocumentID = id
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            if find.isVisible {
                WritingFindBar(controller: find)
                Divider()
            }
            if activeDocumentSupportsVisual {
                ZStack {
                    visualEditorPane
                        // Each document gets an editor of its own: giving one editor
                        // new text adds it to that editor's undo history, where Undo
                        // would bring back the document that was there before.
                        .id(selectedWorkspaceDocumentID ?? "")
                    if editorMode == .markdown {
                        markdownEditorPane
                    }
                }
            } else {
                markdownEditorPane
            }
        }
    }

    /// The surface the find bar searches: the one on screen.
    private var activeFindTarget: (any WritingFindTarget)? {
        isEditingVisually ? tipTapCoordinator : markdownFinder
    }

    // MARK: - Panes

    private var visualEditorPane: some View {
        VStack(spacing: 0) {
            if editorMode == .visual {
                visualFormattingToolbar
                Divider()
            }
            TipTapEditorView(
                markdownContent: activeTextBinding,
                fontSize: editorFontSize,
                mediaScopeID: identifier,
                libraryRootURL: model.library.rootURL,
                isVisible: editorMode == .visual,
                mediaReferences: mediaReferences,
                // A note written beneath the prose opens in a panel by its
                // marker, which the page draws itself. A note kept in the
                // Footnotes field isn't on the page for it to open, so the
                // page reports the click and `revealFootnote` answers it.
                footnoteClicks: .popover,
                proseTypeface: writingTypeface,
                onCoordinatorReady: { coordinator in
                    tipTapCoordinator = coordinator
                    visualEditorIsReady = true
                    connectReviewMarks(to: coordinator)
                    coordinator.onFootnoteNotInPage = { label in
                        revealFootnote(label)
                    }
                    coordinator.onSelectionChanged = { selection in
                        DispatchQueue.main.async {
                            // The page reports a selection with every
                            // keystroke, and this state is read by the format
                            // bar — so writing a value equal to the one held
                            // rebuilt the editor, its status bar and both
                            // surfaces for a caret that had moved one
                            // character. It carries which styles are on,
                            // nothing about where the caret is, so typing
                            // inside a paragraph reports the same state over
                            // and over: only a change of style is news.
                            if tipTapSelection != selection {
                                tipTapSelection = selection
                            }
                            // What is selected does change with the caret, and
                            // this reads it on its own clock, a moment later.
                            readVisualSelectionSoon()
                        }
                    }
                    // Nothing should reach this editor's text once it has gone.
                    // The editor for the next document can report in first, so
                    // only the editor still held is let go.
                    coordinator.onDetached = { [weak coordinator] in
                        guard let coordinator, tipTapCoordinator === coordinator else { return }
                        tipTapCoordinator = nil
                        visualEditorIsReady = false
                        tipTapSelection = TipTapSelectionState()
                    }
                }
            )
        }
        // No colour here either. The page is transparent and shows whatever
        // is behind it, so a colour here would be the one it showed — and
        // the window's own ground is what every other surface shows.
    }

    private var visualFormattingToolbar: some View {
        DevotionalEditorToolbarScrollView {
            HStack(alignment: .center, spacing: 10) {
                editorControlGroup("Style") {
                    Menu {
                        Button("Paragraph") { tipTapCoordinator?.applyStyle(.paragraph) }
                        Divider()
                        Button("Heading 1") { tipTapCoordinator?.applyStyle(.heading1) }
                        Button("Heading 2") { tipTapCoordinator?.applyStyle(.heading2) }
                        Button("Heading 3") { tipTapCoordinator?.applyStyle(.heading3) }
                    } label: {
                        HStack(spacing: 4) {
                            Text(visualStyleLabel)
                                .frame(minWidth: 56, alignment: .leading)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Paragraph Style")
                    .help("Paragraph and heading style")
                }

                formatBarSeparator

                editorControlGroup("Text") {
                    visualCommandButton(
                        "Bold",
                        systemImage: "bold",
                        isActive: tipTapSelection.bold
                    ) { tipTapCoordinator?.applyStyle(.bold) }
                    visualCommandButton(
                        "Italic",
                        systemImage: "italic",
                        isActive: tipTapSelection.italic
                    ) { tipTapCoordinator?.applyStyle(.italic) }
                    if tipTapSelection.link {
                        visualCommandButton(
                            "Remove Link",
                            systemImage: "link",
                            isActive: true
                        ) { tipTapCoordinator?.removeLink() }
                    }
                }

                formatBarSeparator

                editorControlGroup("Lists") {
                    visualCommandButton(
                        "Bulleted List",
                        systemImage: "list.bullet",
                        isActive: tipTapSelection.bulletList
                    ) { tipTapCoordinator?.applyStyle(.bullet) }
                    visualCommandButton(
                        "Numbered List",
                        systemImage: "list.number",
                        isActive: tipTapSelection.orderedList
                    ) { tipTapCoordinator?.applyStyle(.numberedList) }
                    visualCommandButton("Decrease Indent", systemImage: "decrease.indent") {
                        tipTapCoordinator?.applyStyle(.outdent)
                    }
                    visualCommandButton("Increase Indent", systemImage: "increase.indent") {
                        tipTapCoordinator?.applyStyle(.indent)
                    }
                }

                formatBarSeparator

                editorControlGroup("Blocks") {
                    visualCommandButton(
                        "Quote",
                        systemImage: "text.quote",
                        isActive: tipTapSelection.blockquote
                    ) { tipTapCoordinator?.applyStyle(.quote) }
                    visualCommandButton("Divider", systemImage: "minus") {
                        tipTapCoordinator?.insertHorizontalRule()
                    }
                    Menu {
                        Button("2 × 2 Table") { tipTapCoordinator?.insertTable(rows: 2, columns: 2) }
                        Button("3 × 3 Table") { tipTapCoordinator?.insertTable(rows: 3, columns: 3) }
                        Button("4 × 4 Table") { tipTapCoordinator?.insertTable(rows: 4, columns: 4) }
                    } label: {
                        toolbarIcon("tablecells")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Table")
                    .help("Insert table")
                }

                formatBarSeparator

                editorControlGroup("Insert") {
                    insertMenu(includesFootnote: true)
                }

                formatBarSeparator

                editorTextSizeControls
            }
            .buttonStyle(FormatBarButtonStyle())
            .disabled(!visualEditorIsReady)
            .padding(.horizontal, 16)
            // The assistant's setup row stands beside this one, so both
            // take the shared height rather than each adding up its own.
            .frame(height: LampMetrics.paneHeaderHeight)
        }
            }

    /// What can be put into the writing, under one labelled menu. As four
    /// labelled buttons beside a row of glyphs, the bar mixed two kinds of
    /// control and ran long; and a greyed "Scripture" button said nothing of
    /// why. In the menu it says so.
    private func insertMenu(includesFootnote: Bool) -> some View {
        Menu {
            Button(
                model.selectedVerseReference == nil
                    ? "Scripture Link (open a verse in the reader first)"
                    : "Scripture Link",
                systemImage: "book"
            ) { insertScriptureLink() }
                .disabled(model.selectedVerseReference == nil)
            if includesFootnote {
                Button("Footnote", systemImage: "text.badge.plus") { insertFootnote() }
            }
            Divider()
            Button("Image or Audio File…", systemImage: "paperclip") { attachMedia() }
            Button("Record Audio…", systemImage: "mic") { showingAudioRecorder = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                Text("Insert")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Insert")
        .help(includesFootnote
            ? "Insert a scripture link, a footnote, media or a recording"
            : "Insert a scripture link, media or a recording")
    }

    /// The hairline between groups of the format bar: groups read by their
    /// spacing and this, rather than by a caption over each one.
    private var formatBarSeparator: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1, height: 16)
            .accessibilityHidden(true)
    }

    private var markdownEditorPane: some View {
        VStack(spacing: 0) {
            DevotionalEditorToolbarScrollView {
                HStack(alignment: .center, spacing: 10) {
                    editorControlGroup("Text") {
                        ForEach([MarkdownCommand.bold, .italic]) { command in
                            markdownCommandButton(command)
                        }
                    }

                    formatBarSeparator

                    editorControlGroup("Blocks") {
                        ForEach([MarkdownCommand.heading, .quote]) { command in
                            markdownCommandButton(command)
                        }
                    }

                    formatBarSeparator

                    editorControlGroup("Lists") {
                        ForEach([MarkdownCommand.bulletList, .numberedList]) { command in
                            markdownCommandButton(command)
                        }
                    }

                    formatBarSeparator

                    editorControlGroup("Insert") {
                        insertMenu(includesFootnote: false)
                    }

                    formatBarSeparator

                    editorTextSizeControls
                }
                .buttonStyle(FormatBarButtonStyle())
                .padding(.horizontal, 16)
                // The assistant's setup row stands beside this one, so both
                // take the shared height rather than each adding up its own.
                .frame(height: LampMetrics.paneHeaderHeight)
            }
            
            Divider()

            MarkdownTextEditor(
                text: activeTextBinding,
                selection: activeSelectionBinding,
                fontSize: editorFontSize,
                finder: markdownFinder,
                measure: 76,
                reviewRanges: isEditingPrimaryDocument ? reviewSession.ranges : [],
                onMarkAsReviewed: isEditingPrimaryDocument ? { reviewSession.clear(range: $0) } : nil
            )
            // The text view draws no background of its own, so without this it
            // shows whatever happens to be behind the window — which is close to
            // the colour the visual editor is told to paint, but not equal to it.
            // Naming the colour here makes the two surfaces match by construction.
                    }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text(activeSaveStateDescription)
                .foregroundStyle(activeSaveStateIsProblem ? AnyShapeStyle(.red) : AnyShapeStyle(Color.lampSecondaryText))

            if activeWorkspaceDocument == nil, keepingFailed != nil, let newer = newerCopy {
                Button("Try Again") { keepEdits(over: newer) }
                    .controlSize(.mini)
            } else if activeWorkspaceDocument == nil, let keptEdits, !isDirty {
                Button("Open Your Edits") {
                    openWindow(id: "devotional-editor", value: DevotionalEditorRequest(devotionalID: keptEdits.id))
                }
                .controlSize(.mini)
            }

            if let document = activeWorkspaceDocument, document.hasExternalConflict {
                Button(document.wasRemovedExternally ? "Close Tab" : "Use Agent Version") {
                    acceptExternalWorkspaceDocument(document.id)
                }
                .controlSize(.mini)
                Button("Keep My Version") {
                    saveWorkspaceDocument(document.id, force: true)
                }
                .controlSize(.mini)
            }

            Spacer(minLength: 8)

            Text(statistics.wordCountDescription)
                .monospacedDigit()
            Text("·")
                .foregroundStyle(.tertiary)
            ReadingTimeMenu(statistics: statistics)
        }
        .font(.subheadline)
        .foregroundStyle(Color.primary.opacity(0.72))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
            }

    private var activeSaveStateIsProblem: Bool {
        if let document = activeWorkspaceDocument {
            return document.errorMessage != nil || document.hasExternalConflict
        }
        if keepingFailed != nil { return true }
        if case .failed = saveState { return true }
        return false
    }

    /// The writing's details, as a writing tool's inspector rather than a
    /// settings form: each field under its own small label, in a bordered
    /// box that says it can be typed in, at the inspector's full width. The
    /// grouped form set values right-aligned on unbordered rows, which read
    /// as settings and gave the eye no edge to an editable value.
    ///
    /// Series, Key Scripture, Summary and Footnotes fold away while empty,
    /// so a writing with none of them is not faced with four empty boxes;
    /// each opens with a click on its heading, and opens by itself once it
    /// holds something.
    private var detailsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                inspectorGroup("Details") {
                    inspectorField("Title") {
                        TextField("Title", text: $title, prompt: Text("Untitled"))
                            .modifier(InspectorFieldBox())
                    }
                    inspectorField("Subtitle") {
                        TextField("Subtitle", text: $subtitle, prompt: Text("None"))
                            .modifier(InspectorFieldBox())
                    }
                    inspectorField("Author") {
                        TextField("Author", text: $author, prompt: Text("None"))
                            .modifier(InspectorFieldBox())
                    }
                    HStack(alignment: .top, spacing: 12) {
                        inspectorField("Date") {
                            WritingDateField(storedValue: $date)
                        }
                        inspectorField("Category") {
                            WritingCategoryField(
                                title: "Category",
                                storedValue: $category,
                                held: model.devotionals.map(\.category)
                            )
                            .labelsHidden()
                            .modifier(InspectorFieldBox(trailingInset: 4))
                        }
                    }
                    inspectorField("Tags") {
                        TextField("Tags", text: $tags, prompt: Text("Comma separated"))
                            .modifier(InspectorFieldBox())
                    }
                }

                Divider()

                foldingGroup("Series", holdsContent: !seriesName.isEmpty) {
                    inspectorField("Series") {
                        TextField("Series", text: $seriesName, prompt: Text("None"))
                            .modifier(InspectorFieldBox())
                    }
                    Stepper("Order: \(seriesOrder)", value: $seriesOrder, in: 0...10_000)
                        .disabled(seriesName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Divider()

                foldingGroup("Key Scripture", holdsContent: !keyScriptures.isEmpty) {
                    if keyScriptures.isEmpty {
                        Text("No key scripture added")
                            .foregroundStyle(Color.lampSecondaryText)
                    }
                    ForEach(keyScriptures) { scripture in
                        HStack {
                            Text(scripture.displayDescription)
                            Spacer()
                            Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                keyScriptures.removeAll { $0.id == scripture.id }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                    }
                    if let reference = model.selectedVerseReference {
                        Button(
                            "Add \(LampBibleReferenceFormatter.describeRange(from: reference, to: reference))",
                            systemImage: "book"
                        ) {
                            guard !keyScriptures.contains(where: { $0.startReference == reference }) else { return }
                            keyScriptures.append(LampScriptureLink(startReference: reference))
                        }
                    } else {
                        Text("Select a verse in the reader to add it here.")
                            .font(.callout)
                            .foregroundStyle(Color.lampSecondaryText)
                    }
                }

                Divider()

                foldingGroup("Summary", holdsContent: !summary.isEmpty) {
                    TextEditor(text: $summary)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(minHeight: 80)
                        .modifier(InspectorTextBox())
                        .overlay(alignment: .topLeading) {
                            if summary.isEmpty {
                                fieldPlaceholder("A sentence or two on what this writing is about")
                                    .padding(.leading, 9)
                                    .padding(.top, 4)
                            }
                        }
                }

                Divider()

                foldingGroup("Footnotes", holdsContent: !footnotes.isEmpty) {
                    // A text view rather than `TextEditor`, which has no selection
                    // to move: clicking a marker in the writing puts the caret on
                    // that note's line here.
                    MarkdownTextEditor(
                        text: $footnotes,
                        selection: $footnotesSelection,
                        fontSize: 13,
                        revealToken: footnotesRevealToken,
                        monospaced: false
                    )
                    .frame(minHeight: 100)
                    .modifier(InspectorTextBox())
                    .overlay(alignment: .topLeading) {
                        if footnotes.isEmpty {
                            fieldPlaceholder("Notes kept apart from the writing, in Markdown, as [^1]: …")
                                .font(.system(size: 13))
                                .padding(.leading, 12)
                                .padding(.top, 14)
                        }
                    }
                    Text("Notes written in the prose with Insert › Footnote stay there; these are kept beside it.")
                        .font(.caption)
                        .foregroundStyle(Color.lampSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textFieldStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
        }
        // No ground of its own: it is inside the side pane, which carries the
        // one step for everything in it. Its old colour overshot that step
        // and read as a hole (0.1408 against the window's 0.1863).
        // A footnote marker clicked in the writing whose note is kept here
        // opens the section, so the caret has somewhere visible to go.
        .onChange(of: footnotesRevealToken) { foldedOpen["Footnotes"] = true }
    }

    /// A titled group of the inspector, always open.
    private func inspectorGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).lampSectionHeading()
            content()
        }
    }

    /// A group that folds away while it holds nothing, and opens on a click
    /// on its heading or as soon as something is put in it.
    private func foldingGroup<Content: View>(
        _ title: String,
        holdsContent: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isOpen = foldedOpen[title] ?? holdsContent
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { foldedOpen[title] = !isOpen }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text(title).lampSectionHeading()
                    Spacer()
                    if !isOpen && !holdsContent {
                        Text("Empty")
                            .font(.caption)
                            .foregroundStyle(Color.lampSecondaryText)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            .help(isOpen ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")
            if isOpen {
                content()
            }
        }
    }

    /// One field of the inspector, under its own small label.
    private func inspectorField<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.lampSecondaryText)
            content()
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// What an empty field is for, in the place its text will go.
    private func fieldPlaceholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(Color.lampSecondaryText)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        // No Save button. The writing saves itself 1.5 seconds after a
        // change, a workspace file 900ms after one, and everything on the
        // way out; the status bar under the writing says which of those
        // states it is in, and the conflict buttons live there too. ⌘S is
        // kept as a File menu command (`writingSave`), because the shortcut
        // is a reflex and one that beeps reads as work not saved.
        ToolbarItem(placement: .navigation) {
            Button {
                showActiveRevisionHistory()
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .fittingToolbarLabel()
            .accessibilityLabel("Revision History")
            .disabled(activeRevisionDocumentPath == nil)
            .help(activeRevisionDocumentPath == nil
                ? "Revision history is available for Markdown workspace files"
                : "Review or restore revisions for this Markdown file")
        }

        ToolbarItem(placement: .navigation) {
            Menu("Workspace", systemImage: "folder") {
                Button("New Markdown File…", systemImage: "doc.badge.plus") {
                    showingNewWorkspaceDocument = true
                }
                Button("Open Workspace File…", systemImage: "folder.badge.plus") {
                    openWorkspaceFile()
                }
                .disabled(!workspaceIsAvailable)
                Divider()
                Button("Reveal Workspace in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([workspaceURL])
                }
                .disabled(!workspaceIsAvailable)
            }
            .fittingToolbarLabel()
            .help("Companion files in this writing's workspace")
        }

        ToolbarItem {
            LampSegmentedPicker(
                "Writing Surface",
                selection: editorSurfaceSelection,
                items: DevotionalEditorMode.allCases.map { .init(id: $0, title: $0.title) },
                isCapsule: true
            )
            .disabled(!activeDocumentSupportsVisual)
            .help(activeDocumentSupportsVisual
                ? "Choose the writing surface"
                : "Plain text files use the Markdown editor")
        }

        // The side pane's two kinds, named, together: two small unlabelled
        // icons were hunted for. One pressed shows its pane; pressed again,
        // it closes.
        ToolbarItem {
            ControlGroup {
                Toggle(isOn: Binding(
                    get: { showsDetails && !showingAgentWorkspace },
                    set: { isShowing in
                        withAnimation(.lampPaneReveal) {
                            showingAgentWorkspace = false
                            showsDetails = isShowing
                        }
                    }
                )) {
                    Label("Details", systemImage: "info.circle")
                }
                .help(showsDetails && !showingAgentWorkspace ? "Hide details" : "Show details")
                if aiFeaturesEnabled {
                    Toggle(isOn: Binding(
                        get: { showingAgentWorkspace },
                        set: { isShowing in
                            // The assistant covers the details rather than
                            // closing them: closed again, it leaves the side
                            // as it found it, details open or not.
                            withAnimation(.lampPaneReveal) {
                                showingAgentWorkspace = isShowing
                            }
                        }
                    )) {
                        Label("Assistant", systemImage: "sparkles")
                    }
                    .help(showingAgentWorkspace ? "Hide the assistant" : "Show the assistant")
                }
            }
            .fittingToolbarLabel()
            // Shown on as a neutral pressed state, as Pages and Notes show
            // their inspectors, not in the accent: a red disc in the title
            // bar outshouted the writing beneath it. Strong enough to read
            // as on in dark mode, where the secondary grey did not.
            .tint(Color.primary.opacity(0.55))
        }

        if showsReviewMarks, reviewSession.count > 0, isEditingPrimaryDocument {
            ToolbarItem {
                reviewToolbarControl
            }
        }

        ToolbarItem {
            presentationToolbarControl
        }

        // The way out where the way in was, at the right; its shortcut is
        // Edit's (⇧⌘E: ⌘↩ is the editor's, ⌘E is Use Selection for Find).
        if let done {
            WritingDoneToolbarItem(done: done)
        }
    }

    // MARK: - Review marks

    /// Whether the assistant's changes are marked here: the writer asked for
    /// it, and AI is on.
    private var showsReviewMarks: Bool {
        aiFeaturesEnabled && reviewMarksEnabled
    }

    private struct ReviewFollowing: Equatable {
        let writingID: String
        let isShown: Bool
    }

    /// The visual page shows the session's marks and sends its clears back.
    private func connectReviewMarks(to coordinator: TipTapEditorCoordinator) {
        coordinator.setReviewMarks(reviewSession.markedMarkdown)
        reviewSession.onMarksChanged = { [weak coordinator] marked in
            coordinator?.setReviewMarks(marked)
        }
        coordinator.onReviewClear = { [weak reviewSession] clear in
            reviewSession?.clear(markedMarkdown: clear.marked, pageText: clear.pageText)
        }
        coordinator.onReviewMarksRejected = { [weak reviewSession] in
            reviewSession?.marksRejected()
        }
    }

    /// How much is still to read, and the clears that do not need a
    /// paragraph: the selection, or everything.
    private var reviewToolbarControl: some View {
        Menu {
            Button("Mark Selection as Reviewed") { markSelectionAsReviewed() }
            Button("Mark All as Reviewed") { reviewSession.clearAll() }
        } label: {
            Label(
                reviewSession.count == 1 ? "1 to Review" : "\(reviewSession.count) to Review",
                systemImage: "checkmark.circle"
            )
        }
        .fittingToolbarLabel()
        .help("Passages the assistant changed that you have not read yet")
    }

    private func markSelectionAsReviewed() {
        if activeEditorMode == .visual, let tipTapCoordinator {
            tipTapCoordinator.reviewMarkdownForSelection { clear in
                guard let clear else { return }
                reviewSession.clear(markedMarkdown: clear.marked, pageText: clear.pageText)
            }
        } else {
            reviewSession.clear(range: contentSelection)
        }
    }

    @ViewBuilder
    private var presentationToolbarControl: some View {
        if linkedPresentationDecks.count > 1 {
            Menu("Presentation Decks", systemImage: LinkedPresentationDeckLookup.systemImage) {
                ForEach(linkedPresentationDecks) { deck in
                    Button(deck.title) { openPresentationDeck(deck) }
                }
            }
            .help("Open a presentation deck linked to this writing")
        } else if let deck = linkedPresentationDecks.first {
            Button("Open Presentation Deck", systemImage: LinkedPresentationDeckLookup.systemImage) {
                openPresentationDeck(deck)
            }
            .help("Open the presentation deck linked to this writing")
        } else {
            Button("Build Presentation Deck", systemImage: LinkedPresentationDeckLookup.systemImage) {
                openPresentationDeck(nil)
            }
            .disabled(!hasSavableContent || isOpeningPresentation)
            .help(hasSavableContent
                ? "Build a presentation deck accompanying this writing"
                : "Add writing content before building a presentation deck")
        }
    }

    private var saveStateDescription: String {
        if let keepingFailed {
            return "Not saved — a newer version arrived, and your edits couldn’t be kept: \(keepingFailed)"
        }
        if newerCopy != nil { return "A newer version arrived — keeping your edits…" }
        if let keptEdits, !isDirty {
            return "A newer version arrived from another device. Your edits are kept as “\(keptEdits.title)”."
        }
        if case .failed(let message) = saveState { return "Not saved — \(message)" }
        if saveState == .saving { return "Saving…" }
        if isDirty { return hasSavableContent ? "Unsaved changes" : "Add content to save" }
        if saveState == .saved { return "Saved" }
        return request.devotionalID == nil ? "Not saved yet" : "Up to date"
    }

    private var activeSaveStateDescription: String {
        if let workspaceDocumentError { return "Issue — \(workspaceDocumentError)" }
        guard let document = activeWorkspaceDocument else { return saveStateDescription }
        if document.wasRemovedExternally {
            return "Conflict — this file was removed outside Lamp"
        }
        if document.externalText != nil {
            return "Conflict — this file changed outside Lamp"
        }
        if let errorMessage = document.errorMessage {
            return errorMessage.hasPrefix("Saved,")
                ? errorMessage : "Issue — \(errorMessage)"
        }
        return document.isDirty ? "Unsaved changes" : "Up to date"
    }

    private var activeDocumentCanSave: Bool {
        if let document = activeWorkspaceDocument {
            return document.isDirty && !document.hasExternalConflict
        }
        return hasSavableContent && isDirty && saveState != .saving && newerCopy == nil
    }

    /// Tab labels for the open companions, read the way "Main Prose" reads
    /// rather than as raw filenames. Computed over all of them at once because
    /// two files can format to one title, and then both show their paths.
    private var workspaceDocumentTitles: [String: String] {
        WorkspaceDocumentTitle.titles(for: workspaceDocuments.map(\.relativePath))
    }

    private func title(of document: DevotionalWorkspaceEditorDocument) -> String {
        workspaceDocumentTitles[document.relativePath]
            ?? WorkspaceDocumentTitle.formatted(document.relativePath)
    }


    private var agentContextDocument: String {
        WritingChatTurns.contextDocument(
            title: title, subtitle: subtitle, author: author, date: date, category: category,
            tags: tags, seriesName: seriesName, seriesOrder: seriesOrder, keyScriptures: keyScriptures,
            summary: summary, footnotes: footnotes
        )
    }

    private var agentAccessPolicy: LampAgentAccessPolicy {
        AgentModuleAccessPreferences.policy(
            isEnabled: agentModuleAccessEnabled,
            scope: AgentModuleAccessScope(rawValue: agentModuleAccessScope) ?? .enabledModules,
            includesPersonalContent: agentPersonalContentEnabled,
            modules: model.modules,
            hiddenModuleIDs: model.hiddenModuleIDs
        )
    }

    // MARK: - Editing

    private var editorModeBinding: Binding<DevotionalEditorMode> {
        Binding(
            get: { editorMode },
            set: { switchEditorMode(to: $0) }
        )
    }

    private var editorSurfaceSelection: Binding<DevotionalEditorMode> {
        Binding(
            get: { activeEditorMode },
            set: { switchEditorMode(to: $0) }
        )
    }

    private var visualStyleLabel: String {
        tipTapSelection.heading == 0 ? "Body" : "H\(tipTapSelection.heading)"
    }

    private func switchEditorMode(to newMode: DevotionalEditorMode) {
        guard activeDocumentSupportsVisual, newMode != editorMode else { return }
        collectVisualEditorText()
        editorMode = newMode
    }

    /// Brings the visual editor's latest text into the document it is editing,
    /// before leaving it for the Markdown editor or another document. The editor
    /// reports what is typed only after a pause, so it has to be asked.
    private func collectVisualEditorText() {
        guard isEditingVisually, let coordinator = tipTapCoordinator else { return }
        let textBefore = activeTextBinding.wrappedValue
        // Only an edit is taken, so a document that was only looked at isn't
        // rewritten in the editor's style — or stripped of what it can't show.
        guard let documentID = selectedWorkspaceDocumentID else {
            coordinator.getEditedContent { latestMarkdown in
                DispatchQueue.main.async {
                    // Do not overwrite an edit made immediately after switching
                    // into the Markdown surface.
                    if let latestMarkdown, content == textBefore {
                        content = latestMarkdown
                    }
                }
            }
            return
        }
        coordinator.getEditedContent { latestMarkdown in
            DispatchQueue.main.async {
                guard let latestMarkdown,
                      let index = workspaceDocuments.firstIndex(where: { $0.id == documentID }),
                      workspaceDocuments[index].text == textBefore
                else { return }
                workspaceDocuments[index].text = latestMarkdown
                workspaceDocuments[index].errorMessage = nil
            }
        }
    }

    /// One group of the format bar. The group's name is spoken rather than
    /// printed: captions over every group doubled the bar's height and
    /// crowded it, and each control already says what it does in its tooltip.
    private func editorControlGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 2) {
            content()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var editorTextSizeControls: some View {
        let scale = LampTextScale.writingEditorText
        return editorControlGroup("Text Size") {
            Image(systemName: "textformat.size")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.trailing, 2)
                .accessibilityHidden(true)
            Button {
                editorFontSize = scale.stepped(editorFontSize, by: -1)
            } label: {
                toolbarIcon("minus")
            }
            .accessibilityLabel("Smaller")
            .disabled(!scale.canDecrease(editorFontSize))
            .help("Decrease editor text size")

            Text("\(editorFontSize.formatted(.number.precision(.fractionLength(0)))) pt")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.primary.opacity(0.8))
                .frame(minWidth: 36)

            Button {
                editorFontSize = scale.stepped(editorFontSize, by: 1)
            } label: {
                toolbarIcon("plus")
            }
            .accessibilityLabel("Larger")
            .disabled(!scale.canIncrease(editorFontSize))
            .help("Increase editor text size")
        }
    }

    /// A toolbar button's icon, in a box of its own.
    ///
    /// A symbol's own height is what would decide a button's height, and
    /// the symbols here are nothing like each other: `minus` drew a button
    /// 15.5pt tall where `link` drew one of 28.5, with four more heights in
    /// between and no two of the rest matching. Boxing every icon the same
    /// makes every button the same.
    private func toolbarIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .frame(width: 16, height: 16)
    }

    private func visualCommandButton(
        _ title: String,
        systemImage: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { toolbarIcon(systemImage) }
            .buttonStyle(FormatBarButtonStyle(isActive: isActive))
            .accessibilityLabel(title)
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .help(title)
    }

    private func markdownCommandButton(_ command: MarkdownCommand) -> some View {
        Button {
            apply(command)
        } label: {
            toolbarIcon(command.systemImage)
        }
        .accessibilityLabel(command.title)
        .help(command.title)
    }

    private func apply(_ command: MarkdownCommand) {
        let result = command.apply(
            to: activeTextBinding.wrappedValue,
            selection: activeSelectionBinding.wrappedValue
        )
        activeTextBinding.wrappedValue = result.text
        activeSelectionBinding.wrappedValue = result.selection
    }

    private func insert(_ snippet: String, onOwnLine: Bool = true) {
        let result = MarkdownEditor.insert(
            snippet,
            in: activeTextBinding.wrappedValue,
            selection: activeSelectionBinding.wrappedValue,
            onOwnLine: onOwnLine
        )
        activeTextBinding.wrappedValue = result.text
        activeSelectionBinding.wrappedValue = result.selection
    }

    private func insertScriptureLink() {
        guard let reference = model.selectedVerseReference else { return }
        let description = LampBibleReferenceFormatter.describeRange(from: reference, to: reference)
        let url = "lampbible://read?reference=\(reference)"
        if isEditingVisually, let coordinator = tipTapCoordinator {
            coordinator.getSelectedText { selectedText in
                if selectedText.isEmpty {
                    coordinator.insertTextLink(label: description, url: url)
                } else {
                    coordinator.insertLink(url: url)
                }
            }
        } else {
            insert("[\(description)](\(url))", onOwnLine: false)
        }
    }

    private func attachMedia() {
        let panel = NSOpenPanel()
        panel.title = "Attach Image or Audio"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .audio]
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        Task {
            do {
                let storedURL = try await model.library.storePersonalDevotionalMedia(
                    from: sourceURL,
                    devotionalID: identifier
                )
                let isImage = UTType(filenameExtension: storedURL.pathExtension)?
                    .conforms(to: .image) == true
                let label = storedURL.deletingPathExtension().lastPathComponent
                if !isEditingPrimaryDocument {
                    // Only the writing keeps a list of its media, so a file
                    // beside it links the stored file by name. The visual
                    // editor writes a media ID it doesn't know as that link.
                    let filename = storedURL.lastPathComponent
                    if isEditingVisually, let coordinator = tipTapCoordinator {
                        if isImage {
                            coordinator.insertImage(mediaID: filename, caption: label, localURL: storedURL)
                        } else {
                            coordinator.insertAudio(mediaID: filename, caption: "▶︎ \(label)")
                        }
                        return
                    }
                    let legacyURL = "lamp-media://\(identifier)/\(filename)"
                    insert(isImage
                        ? "![\(label)](\(legacyURL))"
                        : "[▶︎ \(label)](\(legacyURL))")
                    return
                }
                let reference = try await registerMedia(
                    at: storedURL, type: isImage ? .image : .audio, label: label
                )
                let portableURL = "media/\(reference.id)"
                if isEditingPrimaryDocument, editorMode == .visual, let coordinator = tipTapCoordinator {
                    if isImage {
                        coordinator.insertImage(
                            mediaID: reference.id,
                            caption: label,
                            localURL: storedURL
                        )
                    } else {
                        coordinator.insertAudio(
                            mediaID: reference.id,
                            caption: "▶︎ \(label)"
                        )
                    }
                } else {
                    insert(isImage
                        ? "![\(label)](\(portableURL))"
                        : "[▶︎ \(label)](\(portableURL))")
                }
            } catch {
                saveState = .failed(error.localizedDescription)
            }
        }
    }

    private func insertStoredAudio(_ storedURL: URL) {
        Task {
            do {
                let label = storedURL.deletingPathExtension().lastPathComponent
                if !isEditingPrimaryDocument {
                    let filename = storedURL.lastPathComponent
                    if isEditingVisually, let coordinator = tipTapCoordinator {
                        coordinator.insertAudio(mediaID: filename, caption: "▶︎ \(label)")
                    } else {
                        insert("[▶︎ \(label)](lamp-media://\(identifier)/\(filename))")
                    }
                    return
                }
                let reference = try await registerMedia(
                    at: storedURL, type: .audio, label: label
                )
                if isEditingPrimaryDocument, editorMode == .visual,
                   let coordinator = tipTapCoordinator {
                    coordinator.insertAudio(
                        mediaID: reference.id, caption: "▶︎ \(label)"
                    )
                } else {
                    insert("[▶︎ \(label)](media/\(reference.id))")
                }
            } catch {
                saveState = .failed(error.localizedDescription)
            }
        }
    }

    private func registerMedia(
        at url: URL,
        type: LampDevotionalMediaType,
        label: String
    ) async throws -> LampDevotionalMediaReference {
        let filename = url.lastPathComponent
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let dimensions: (width: Int, height: Int)?
        if type == .image, let image = NSImage(contentsOf: url),
           let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            dimensions = (bitmap.width, bitmap.height)
        } else {
            dimensions = nil
        }
        let duration: Double?
        if type == .audio,
           let time = try? await AVURLAsset(url: url).load(.duration) {
            let seconds = CMTimeGetSeconds(time)
            duration = seconds.isFinite && seconds >= 0 ? seconds : nil
        } else {
            duration = nil
        }
        let reference = LampDevotionalMediaReference(
            type: type, filename: filename,
            mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream",
            size: size, width: dimensions?.width, height: dimensions?.height,
            duration: duration, alt: type == .image ? label : nil
        )
        mediaJSON = try LampPortableDevotionalMedia.appending(reference, to: mediaJSON)
        tipTapCoordinator?.updateRichMediaIDs(Set(mediaReferences.map(\.id)))
        return reference
    }

    // MARK: - Persistence

    private func saveActiveDocument() {
        if let selectedWorkspaceDocumentID {
            saveWorkspaceDocument(selectedWorkspaceDocumentID)
        } else {
            save()
        }
    }

    private func saveDirtyWorkspaceDocuments() {
        let documentIDs = workspaceDocuments
            .filter { $0.isDirty && !$0.hasExternalConflict }
            .map(\.id)
        for documentID in documentIDs {
            saveWorkspaceDocument(documentID)
        }
    }

    private func createWorkspaceDocument(named proposedName: String) -> String? {
        do {
            let needsDevotionalRecord = !model.devotionals.contains { $0.id == identifier }
            let snapshot = try WorkspaceTextFileStore.createMarkdownDocument(
                named: proposedName,
                in: workspaceURL
            )
            if !workspaceDocuments.contains(where: { $0.id == snapshot.id }) {
                workspaceDocuments.append(DevotionalWorkspaceEditorDocument(
                    url: snapshot.url,
                    text: snapshot.contents,
                    persistedText: snapshot.contents
                ))
                workspaceDocuments.sort {
                    $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
                }
            }
            workspaceIsAvailable = true
            workspaceDocumentsInitialized = true
            selectWorkspaceDocument(snapshot.id)
            if needsDevotionalRecord {
                // The library requires one authored field for a durable record.
                // A neutral title keeps an outline-first workspace reachable
                // without pretending the companion filename is the talk title.
                if !hasSavableContent { title = "Untitled" }
                save()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func showActiveRevisionHistory() {
        guard let documentPath = activeRevisionDocumentPath else { return }
        let documentID = activeWorkspaceDocument?.id
        let documentTitle = activeWorkspaceDocument.map(title(of:)) ?? "Main Prose"
        let workspace = workspaceURL
        Task {
            do {
                let revisions = try await DevotionalAgentRevisionHistory.shared.revisions(
                    in: workspace,
                    documentPath: documentPath
                )
                revisionHistoryRequest = DevotionalRevisionHistoryRequest(
                    documentID: documentID,
                    documentPath: documentPath,
                    documentTitle: documentTitle,
                    revisions: revisions
                )
            } catch {
                if let documentID,
                   let index = workspaceDocuments.firstIndex(where: { $0.id == documentID }) {
                    workspaceDocuments[index].errorMessage = error.localizedDescription
                } else {
                    saveState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func restoreRevision(
        _ markdown: String,
        request: DevotionalRevisionHistoryRequest
    ) {
        if let documentID = request.documentID {
            guard let index = workspaceDocuments.firstIndex(where: { $0.id == documentID }),
                  workspaceDocuments[index].text != markdown else { return }
            workspaceDocuments[index].text = markdown
            workspaceDocuments[index].externalText = nil
            workspaceDocuments[index].wasRemovedExternally = false
            saveWorkspaceDocument(documentID, force: true, changeKind: .restoration)
            return
        }

        guard content != markdown else { return }
        // Recorded before the draft is replaced, so an interrupted restore leaves
        // the version it moved away from recoverable rather than lost.
        //
        // **Including whatever is in the file.** A run outlives the agent
        // pane, so `draft.md` can hold something this editor has not taken
        // up yet — and with the pane closed there is nothing polling for
        // it. Recording only what this view holds wrote that version out
        // of existence. The same two steps a save makes: what arrived
        // first, then the restore on top of it.
        let onDisk = try? WorkspaceTextFileStore.openableSnapshot(
            at: workspaceURL.appendingPathComponent(
                DevotionalAgentRevisionStore.primaryDocumentPath
            ),
            in: workspaceURL
        ).contents
        let restored = savedRevisions(
            persisted: content,
            onDisk: onDisk,
            submitted: markdown,
            changeKind: .restoration
        )
        let workspace = workspaceURL
        Task {
            do {
                try await recordWorkspaceRevisions(
                    restored,
                    documentPath: DevotionalAgentRevisionStore.primaryDocumentPath
                )
                try WorkspaceTextFileStore.write(
                    markdown,
                    to: workspace.appendingPathComponent(
                        DevotionalAgentRevisionStore.primaryDocumentPath
                    ),
                    in: workspace
                )
                try await DevotionalAgentRevisionHistory.shared.markSynced(
                    markdown,
                    in: workspace
                )
                content = markdown
                save()
            } catch {
                saveState = .failed(error.localizedDescription)
            }
        }
    }

    private func workspaceRelativePath(of url: URL) -> String? {
        WorkspaceTextFileStore.relativePath(of: url, in: workspaceURL)
    }

    /// Opens any text file in the workspace, at any depth.
    ///
    /// The tabs list the writing's companions automatically; infrastructure,
    /// context and skills are left out so they don't bury them. That is a
    /// reason not to list a file, not a reason to refuse to open it, so
    /// anything in the workspace can be opened deliberately from here.
    private func openWorkspaceFile() {
        let panel = NSOpenPanel()
        panel.title = "Open Workspace File"
        panel.message = "Choose a file from this writing's workspace."
        panel.prompt = "Open"
        panel.directoryURL = workspaceURL
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK else { return }

        var opened: String?
        workspaceDocumentError = nil
        for url in panel.urls {
            do {
                let snapshot = try WorkspaceTextFileStore.openableSnapshot(
                    at: url,
                    in: workspaceURL
                )
                guard let path = workspaceRelativePath(of: snapshot.url) else { continue }
                if let existing = workspaceDocuments.first(where: { $0.id == path }) {
                    opened = existing.id
                    continue
                }
                workspaceDocuments.append(DevotionalWorkspaceEditorDocument(
                    url: snapshot.url,
                    relativePath: path,
                    text: snapshot.contents,
                    persistedText: snapshot.contents,
                    isHandOpened: true
                ))
                opened = path
            } catch {
                workspaceDocumentError = error.localizedDescription
            }
        }
        workspaceDocuments.sort {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        if let opened { selectWorkspaceDocument(opened) }
    }

    /// Every document this editor manages has a history, not only the
    /// Markdown ones.
    ///
    /// `.txt` and `.text` are listed as tabs and edited here like the
    /// rest, and were the one kind an agent could change with nothing
    /// recorded — so a turn that wrote one passed the undo's "it also
    /// changed something else" refusal, and undoing it put the draft back
    /// and left that file as the turn had made it. The set is the one the
    /// editor opens, so the two cannot drift apart again.
    private func supportsRevisionHistory(_ url: URL) -> Bool {
        if WorkspaceTextFileStore.supportedExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }
        // Anything hand-opened counts too. `openableSnapshot` takes any
        // readable text file at any extension, so a `notes.rst` opened
        // deliberately was edited here like the rest and recorded like
        // none of them — and a turn that changed it passed the undo's
        // "it also changed something else" refusal.
        return workspaceDocuments.contains { $0.url == url }
    }

    /// Writes transitions to a document's history, in the order they happened.
    private func recordWorkspaceRevisions(
        _ pending: [PendingWorkspaceRevision],
        documentPath: String
    ) async throws {
        let workspace = workspaceURL
        for revision in pending {
            try await DevotionalAgentRevisionHistory.shared.record(
                kind: revision.kind,
                turnID: revision.turnID,
                documentPath: documentPath,
                before: revision.before,
                after: revision.after,
                in: workspace
            )
        }
    }

    /// Records transitions in the background, reporting a failure on the document
    /// they belong to. The file is already written by the time this runs, so the
    /// note explains what is missing rather than what failed.
    private func recordWorkspaceRevisions(
        _ pending: [PendingWorkspaceRevision],
        documentPath: String,
        failureNote: String
    ) {
        guard !pending.isEmpty else { return }
        Task {
            do {
                try await recordWorkspaceRevisions(pending, documentPath: documentPath)
            } catch {
                guard let index = workspaceDocuments.firstIndex(where: {
                    $0.id == documentPath
                }) else { return }
                workspaceDocuments[index].errorMessage =
                    "\(failureNote): \(error.localizedDescription)"
            }
        }
    }

    /// The transitions a refresh picked up from disk, for a document whose file
    /// an agent has rewritten underneath the editor.
    private func externalRevisions(
        for document: DevotionalWorkspaceEditorDocument,
        after externalText: String
    ) -> [PendingWorkspaceRevision] {
        guard supportsRevisionHistory(document.url) else { return [] }
        return [PendingWorkspaceRevision(
            kind: .agentEdit,
            before: document.persistedText,
            after: externalText,
            turnID: agentChatTurn
        )]
    }

    /// What a completed save adds to a document's history: whatever an agent had
    /// written to the file since the editor last read it, and then the writer's
    /// own change on top of that.
    private func savedRevisions(
        persisted: String,
        onDisk: String?,
        submitted: String,
        changeKind: DevotionalAgentRevisionKind
    ) -> [PendingWorkspaceRevision] {
        // No file to compare against: it was deleted, and the save recreated it.
        let base = onDisk ?? ""
        var pending: [PendingWorkspaceRevision] = []
        if base != persisted {
            pending.append(PendingWorkspaceRevision(
                kind: .agentEdit,
                before: persisted,
                after: base,
                turnID: agentChatTurn
            ))
        }
        if submitted != base {
            pending.append(PendingWorkspaceRevision(
                kind: changeKind,
                before: base,
                after: submitted,
                // The writer's own change, even where it lands during a
                // turn. Only what the agent wrote is the turn's to undo.
                turnID: changeKind == .agentEdit ? agentChatTurn : nil
            ))
        }
        return pending
    }

    private func saveWorkspaceDocument(
        _ documentID: String,
        force: Bool = false,
        changeKind: DevotionalAgentRevisionKind = .userEdit
    ) {
        guard let index = workspaceDocuments.firstIndex(where: { $0.id == documentID }) else {
            return
        }
        let submittedText = workspaceDocuments[index].text
        let fileURL = workspaceDocuments[index].url
        let persistedText = workspaceDocuments[index].persistedText

        do {
            let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
            let diskText = fileExists
                ? try String(contentsOf: fileURL, encoding: .utf8)
                : nil
            if !force {
                guard let diskText else {
                    workspaceDocuments[index].wasRemovedExternally = true
                    workspaceDocuments[index].errorMessage = nil
                    return
                }
                if diskText != persistedText, diskText != submittedText {
                    workspaceDocuments[index].externalText = diskText
                    workspaceDocuments[index].errorMessage = nil
                    return
                }
            }

            try WorkspaceTextFileStore.writeOpened(
                submittedText,
                to: fileURL,
                in: workspaceURL
            )
            guard let savedIndex = workspaceDocuments.firstIndex(where: {
                $0.id == documentID
            }) else { return }
            workspaceDocuments[savedIndex].persistedText = submittedText
            workspaceDocuments[savedIndex].externalText = nil
            workspaceDocuments[savedIndex].wasRemovedExternally = false
            workspaceDocuments[savedIndex].errorMessage = nil

            guard supportsRevisionHistory(fileURL) else { return }
            // The document is saved and the tab already says so. Its history is
            // written after the fact, off the main actor, because walking the
            // revision folder is the slowest thing a save does and the writer is
            // typing the next sentence by now.
            recordWorkspaceRevisions(
                savedRevisions(
                    persisted: persistedText,
                    onDisk: diskText,
                    submitted: submittedText,
                    changeKind: changeKind
                ),
                documentPath: documentID,
                failureNote: "Saved, but revision history could not be updated"
            )
        } catch {
            guard let failedIndex = workspaceDocuments.firstIndex(where: {
                $0.id == documentID
            }) else { return }
            workspaceDocuments[failedIndex].errorMessage = error.localizedDescription
        }
    }

    private func acceptExternalWorkspaceDocument(_ documentID: String) {
        guard let index = workspaceDocuments.firstIndex(where: { $0.id == documentID }) else {
            return
        }
        if workspaceDocuments[index].wasRemovedExternally {
            let document = workspaceDocuments[index]
            if supportsRevisionHistory(document.url) {
                // Nowhere left to report a failure once the tab closes, and the
                // deletion is the agent's own: losing the record of it costs
                // history, not work.
                //
                // The writer's unsaved text is another matter. The removal
                // is already in the history by the time this runs — it is
                // recorded when the absence is first seen — so a record of
                // going from their buffer to nothing adds nothing the
                // duplicate rule keeps, and their words would be in no
                // file and no history. Theirs is filed as theirs, first.
                Task { [
                    workspace = workspaceURL, text = document.text,
                    persisted = document.persistedText, turn = agentChatTurn
                ] in
                    if text != persisted {
                        try? await DevotionalAgentRevisionHistory.shared.record(
                            kind: .userEdit,
                            documentPath: documentID,
                            before: persisted,
                            after: text,
                            in: workspace
                        )
                    }
                    try? await DevotionalAgentRevisionHistory.shared.record(
                        kind: .agentEdit,
                        turnID: turn,
                        documentPath: documentID,
                        before: text,
                        after: "",
                        in: workspace
                    )
                }
            }
            workspaceDocuments.remove(at: index)
            if selectedWorkspaceDocumentID == documentID {
                selectedWorkspaceDocumentID = nil
            }
            return
        }
        guard let externalText = workspaceDocuments[index].externalText else { return }
        let localText = workspaceDocuments[index].text
        if supportsRevisionHistory(workspaceDocuments[index].url) {
            var pending: [PendingWorkspaceRevision] = []
            // What the writer had typed and is now giving up. Recorded as
            // theirs, and first: the agent's arrival is already in the
            // history by now, so a record of this transition *to* it adds
            // nothing the duplicate rule will keep — and their words would
            // be in neither the file nor the history.
            if localText != workspaceDocuments[index].persistedText {
                pending.append(PendingWorkspaceRevision(
                    kind: .userEdit,
                    before: workspaceDocuments[index].persistedText,
                    after: localText
                ))
            }
            pending.append(PendingWorkspaceRevision(
                kind: .agentEdit,
                before: localText,
                after: externalText,
                turnID: agentChatTurn
            ))
            recordWorkspaceRevisions(
                pending,
                documentPath: documentID,
                failureNote: "Revision history could not be updated"
            )
        }
        workspaceDocuments[index].text = externalText
        workspaceDocuments[index].persistedText = externalText
        workspaceDocuments[index].externalText = nil
        workspaceDocuments[index].errorMessage = nil
        let textLength = (externalText as NSString).length
        let caret = min(workspaceDocuments[index].selection.location, textLength)
        workspaceDocuments[index].selection = NSRange(location: caret, length: 0)
    }

    @MainActor
    private func monitorWorkspaceDocuments() async {
        refreshWorkspaceDocuments()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            refreshWorkspaceDocuments()
        }
    }

    /// Brings the open document tabs back in line with the workspace on disk.
    ///
    /// Polled several times a second, so it works on a copy and publishes it only
    /// when it differs. Assigning the documents unconditionally — the array was
    /// re-sorted on every pass — invalidated this view a few times a second
    /// whether or not an agent had touched anything, and the editor is a large
    /// view to rebuild while someone is typing into it.
    private func refreshWorkspaceDocuments() {
        do {
            let available = FileManager.default.fileExists(atPath: workspaceURL.path)
            if workspaceIsAvailable != available { workspaceIsAvailable = available }
            let snapshots = try DevotionalAgentWorkspaceFiles.companions(in: workspaceURL)
            // A hand-opened file is not in the listing, so it brings its own
            // snapshot; without one the loop below would call it deleted.
            let listedPaths = Set(snapshots.compactMap { workspaceRelativePath(of: $0.url) })
            let reopened = workspaceDocuments
                .filter { $0.isHandOpened && !listedPaths.contains($0.relativePath) }
                .compactMap { document in
                    try? WorkspaceTextFileStore.openableSnapshot(
                        at: document.url,
                        in: workspaceURL
                    )
                }
            let allSnapshots = snapshots + reopened
            let snapshotIDs = Set(allSnapshots.compactMap { workspaceRelativePath(of: $0.url) })

            var documents = workspaceDocuments
            var pending: [String: [PendingWorkspaceRevision]] = [:]

            for snapshot in allSnapshots {
                let path = workspaceRelativePath(of: snapshot.url) ?? snapshot.id
                if let index = documents.firstIndex(where: { $0.id == path }) {
                    let document = documents[index]
                    if snapshot.contents == document.persistedText {
                        documents[index].wasRemovedExternally = false
                    } else if snapshot.contents == document.text {
                        pending[path] = externalRevisions(for: document, after: snapshot.contents)
                        documents[index].persistedText = snapshot.contents
                        documents[index].externalText = nil
                        documents[index].wasRemovedExternally = false
                        documents[index].errorMessage = nil
                    } else if document.isDirty {
                        // Not applied — the writer has unsaved work in this
                        // tab — but still recorded. The record is how an
                        // undo of the turn knows the turn touched this
                        // file: without it the undo saw only the draft,
                        // put that back, and left this change in place
                        // while taking away the question that made it.
                        pending[path] = externalRevisions(for: document, after: snapshot.contents)
                        documents[index].persistedText = snapshot.contents
                        documents[index].externalText = snapshot.contents
                        documents[index].wasRemovedExternally = false
                        documents[index].errorMessage = nil
                    } else {
                        pending[path] = externalRevisions(for: document, after: snapshot.contents)
                        documents[index].text = snapshot.contents
                        documents[index].persistedText = snapshot.contents
                        documents[index].externalText = nil
                        documents[index].wasRemovedExternally = false
                        documents[index].errorMessage = nil
                        let textLength = (snapshot.contents as NSString).length
                        let caret = min(documents[index].selection.location, textLength)
                        documents[index].selection = NSRange(location: caret, length: 0)
                    }
                } else {
                    if workspaceDocumentsInitialized, supportsRevisionHistory(snapshot.url) {
                        pending[path] = [PendingWorkspaceRevision(
                            kind: .agentEdit,
                            before: "",
                            after: snapshot.contents,
                            turnID: agentChatTurn
                        )]
                    }
                    documents.append(DevotionalWorkspaceEditorDocument(
                        url: snapshot.url,
                        relativePath: path,
                        text: snapshot.contents,
                        persistedText: snapshot.contents
                    ))
                }
            }

            for index in documents.indices where !snapshotIDs.contains(documents[index].id) {
                // A file the agent removed is a change that turn made, and
                // one an undo cannot put back — so it has to be in the
                // history for the undo to refuse rather than restore the
                // draft and leave the writing a document short. Recorded
                // when the absence is first seen, not when the reader
                // accepts it: until they do, there was no record at all.
                if !documents[index].wasRemovedExternally,
                   supportsRevisionHistory(documents[index].url),
                   !documents[index].persistedText.isEmpty {
                    pending[documents[index].id] = [PendingWorkspaceRevision(
                        kind: .agentEdit,
                        before: documents[index].persistedText,
                        after: "",
                        turnID: agentChatTurn
                    )]
                }
                documents[index].wasRemovedExternally = true
                documents[index].externalText = nil
                documents[index].errorMessage = nil
            }
            documents.sort {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
            if documents != workspaceDocuments { workspaceDocuments = documents }
            if !workspaceDocumentsInitialized { workspaceDocumentsInitialized = true }
            for (path, revisions) in pending {
                recordWorkspaceRevisions(
                    revisions,
                    documentPath: path,
                    failureNote: "Revision history could not be updated"
                )
            }
        } catch {
            guard let selectedWorkspaceDocumentID,
                  let index = workspaceDocuments.firstIndex(where: {
                      $0.id == selectedWorkspaceDocumentID
                  }) else { return }
            workspaceDocuments[index].errorMessage = error.localizedDescription
        }
    }

    private func load() {
        workspaceDocuments = []
        selectedWorkspaceDocumentID = nil
        workspaceIsAvailable = false
        workspaceDocumentsInitialized = false
        revisionHistoryRequest = nil
        showingNewWorkspaceDocument = false
        guard let devotionalID = request.devotionalID,
              let devotional = model.devotionals.first(where: { $0.id == devotionalID }) else {
            date = Self.today
            mediaJSON = nil
            originalContentJSON = nil
            originalPlainContent = ""
            originalProjectedMarkdown = ""
            savedFields = editedFields
            hasLoaded = true
            return
        }
        if request.opensAgentPane, aiFeaturesEnabled { showingAgentWorkspace = true }
        identifier = devotional.id
        keptEdits = nil
        keptCopyID = nil
        show(devotional)
        writingHold?.release()
        writingHold = WritingChatTurns.hold(
            devotional.id, revision: devotional.lastModified ?? .distantPast,
            digest: LampAgentRemoteWritingRevision.digest(of: devotional)
        )
    }

    /// Puts a stored copy of the writing in the editor as it stands: on
    /// opening, and when a newer one comes in.
    private func show(_ devotional: LampDevotional) {
        createdDate = devotional.created
        title = devotional.title
        subtitle = devotional.subtitle ?? ""
        author = devotional.author ?? ""
        date = devotional.date ?? Self.today
        tags = devotional.tags.joined(separator: ", ")
        originalCategory = devotional.category
        // Blank, not the first kind offered: a writing with no kind keeps
        // none, rather than being given one by having been opened.
        category = LampWritingCategory.displayName(devotional.category) ?? ""
        seriesName = devotional.seriesName ?? ""
        seriesOrder = devotional.seriesOrder ?? 0
        summary = devotional.summary ?? ""
        content = devotional.displayMarkdown
        originalContentJSON = devotional.contentJSON
        originalPlainContent = devotional.content
        originalProjectedMarkdown = devotional.displayMarkdown
        mediaJSON = devotional.mediaJSON
        footnotes = devotional.footnotes ?? ""
        keyScriptures = devotional.keyScriptures
        saveState = .idle
        savedFields = editedFields
        heldRevision = devotional.lastModified
        newerCopy = nil
        keepingFailed = nil
        hasLoaded = true
    }

    /// Looks for a stored copy saved after the one this editor holds: one
    /// sync brought in from another device. With nothing typed since, it is
    /// simply shown; over edits of the writer's own, those are kept first.
    /// Asked as the writings change, and again as a save finishes, since a
    /// copy that lands while a save is working is seen only then.
    private func lookForNewerCopy(in devotionals: [LampDevotional]) {
        guard hasLoaded, saveState != .saving, newerCopy == nil, !isWeighingNewerCopy,
              newerStoredCopy(in: devotionals) != nil
        else { return }
        isWeighingNewerCopy = true
        Task {
            defer { isWeighingNewerCopy = false }
            // What the visual page holds now: it reports typing only after a
            // pause, and an editor that looks clean may not be.
            await readPage()
            guard saveState != .saving, newerCopy == nil,
                  let stored = newerStoredCopy(in: model.devotionals)
            else { return }
            if !isDirty || editedFields == fields(of: stored) {
                // Nothing typed, or typed exactly what arrived.
                takeIn(stored)
            } else {
                keepEdits(over: stored)
            }
        }
    }

    /// Takes the visual page's text into the editor now, rather than after
    /// the page's own pause.
    ///
    /// Only while the writing has no companion files open: one page shows
    /// whichever document is in front, swapping between them, so while any
    /// are open a read cannot be sure whose text it has, and a companion
    /// file's text must not become the writing's. Only what was typed: a page that only spelled the Markdown
    /// its own way (`*` lists as `-`) reports nothing, so an untouched
    /// writing is not made to look edited.
    private func readPage() async {
        guard editorMode == .visual, workspaceDocuments.isEmpty,
              let coordinator = tipTapCoordinator else { return }
        let markdown = await withCheckedContinuation { continuation in
            coordinator.getEditedContent { continuation.resume(returning: $0) }
        }
        guard let markdown, editorMode == .visual, workspaceDocuments.isEmpty,
              tipTapCoordinator === coordinator, markdown != content
        else { return }
        content = markdown
    }

    /// A stored copy's fields as `editedFields` would hold them once shown.
    private func fields(of devotional: LampDevotional) -> [String] {
        [
            devotional.title, devotional.subtitle ?? "", devotional.author ?? "",
            devotional.date ?? Self.today, devotional.tags.joined(separator: ", "),
            LampWritingCategory.displayName(devotional.category) ?? "",
            devotional.seriesName ?? "", String(devotional.seriesOrder ?? 0), devotional.summary ?? "",
            devotional.displayMarkdown, devotional.footnotes ?? "",
            devotional.keyScriptures.map(\.id).joined(separator: "|"), devotional.mediaJSON ?? "",
        ]
    }

    private func newerStoredCopy(in devotionals: [LampDevotional]) -> LampDevotional? {
        guard let heldRevision,
              let stored = devotionals.first(where: { $0.id == identifier }),
              let storedRevision = stored.lastModified,
              LampAgentRemoteWritingRevision.of(lastModified: storedRevision)
                > LampAgentRemoteWritingRevision.of(lastModified: heldRevision)
        else { return nil }
        return stored
    }

    /// Shows a newer stored copy in place of what the editor held.
    private func takeIn(_ stored: LampDevotional) {
        // Held before the text changes, as a draft taken in is: the marks a
        // turn on the other device made are anchored in this text, and this
        // window's clears and carries take marks only from texts it held.
        reviewSession.holds(stored.displayMarkdown)
        show(stored)
        writingHold?.update(
            revision: stored.lastModified ?? .distantPast,
            digest: LampAgentRemoteWritingRevision.digest(of: stored)
        )
    }

    /// Keeps the writer's edits as a writing of their own, then shows the
    /// newer version that came in over them: as the phone does. Nothing is
    /// saved over the newer version, and nothing typed is lost, the title,
    /// details and pictures included. Quitting waits for it.
    private func keepEdits(over stored: LampDevotional) {
        newerCopy = stored
        keepingFailed = nil
        LampPendingWrites.shared.begin()
        Task {
            defer { LampPendingWrites.shared.end() }
            await keepEditsNow()
        }
    }

    /// The same, from inside a task that already counts as a pending write.
    private func keepEditsNow() async {
        do {
            // Saved again, under the same id, while typing goes on during the
            // save, so the copy holds everything the writer typed before the
            // newer version is shown. Each pass saves one snapshot taken
            // before it waits, and the editor is compared with that snapshot.
            var snapshot: EditsSnapshot
            var kept: LampDevotional?
            repeat {
                await readPage()
                snapshot = editsSnapshot()
                // The copy's id is chosen before it is written, so a retry
                // after any failure writes to the same copy.
                let id = keptCopyID ?? UUID().uuidString
                keptCopyID = id
                if let written = try await saveEditsAsCopy(snapshot, as: id, over: keptCopyRevision) {
                    kept = written
                    // Recorded before the marks are written, so a failure
                    // there leaves a retry writing to this copy.
                    keptCopyRevision = written.lastModified
                    try await carryReviewMarks(of: snapshot, to: id)
                    // Typed while this pass was saving: another pass.
                    await readPage()
                } else {
                    // The copy was edited somewhere else since this editor
                    // wrote it: those edits stay, and a new copy is made.
                    kept = nil
                    keptCopyID = nil
                    keptCopyRevision = nil
                }
            } while kept == nil || editedFields != snapshot.fields
            keptEdits = kept
            keptCopyID = nil
            keptCopyRevision = nil
            // The newest stored copy now, which may be later than the one
            // that set this off.
            let latest = model.devotionals.first(where: { $0.id == identifier }) ?? newerCopy
            newerCopy = nil
            if let latest { takeIn(latest) }
        } catch {
            keepingFailed = error.localizedDescription
        }
    }

    /// The writing's marks, carried into the text kept and filed under the
    /// copy, so its unread passages are still marked there. Whether or not
    /// marks are shown now: turned on again, the copy has them as the
    /// writing does.
    private func carryReviewMarks(of snapshot: EditsSnapshot, to copyID: String) async throws {
        let originalID = identifier
        let store = LampWritingReviewStore(rootURL: model.library.rootURL)
        // Relinked alike in the texts the marks are carried from and the one
        // they are carried to, or every picture's link reads as a change and
        // a mark over a picture is lost.
        func relinked(_ text: String) -> String {
            text.replacingOccurrences(of: "lamp-media://\(originalID)/", with: "lamp-media://\(copyID)/")
        }
        let known = snapshot.reviewTexts.map(relinked)
        let text = relinked(snapshot.markdown)
        try await Task.detached(priority: .userInitiated) {
            var carried = try store.review(writingID: originalID).carryingToText(text, from: known)
            guard !carried.marks.isEmpty else { return }
            carried.writingID = copyID
            try store.update(writingID: copyID) { _ in carried }
        }.value
    }

    /// Everything a copy of the edits is made from, taken at once.
    private struct EditsSnapshot {
        let fields: [String]
        let devotional: LampDevotional
        let markdown: String
        let originalJSON: String?
        let originalPlainContent: String
        let originalProjectedMarkdown: String
        let reviewTexts: [String]
    }

    private func editsSnapshot() -> EditsSnapshot {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return EditsSnapshot(
            fields: editedFields,
            devotional: LampDevotional(
                id: identifier,
                moduleID: "personal-devotionals",
                moduleName: "My Writing",
                title: "\(name.isEmpty ? "Untitled" : name) (your edits)",
                subtitle: subtitle,
                author: author,
                date: date,
                tags: tags.split(separator: ",").map {
                    String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty },
                category: categoryToSave,
                seriesName: seriesName,
                seriesOrder: seriesName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : seriesOrder,
                keyScriptures: keyScriptures,
                summary: summary,
                content: "",
                footnotes: footnotes,
                mediaJSON: mediaJSON,
                created: Date(),
                lastModified: Date(),
                isEditable: true
            ),
            markdown: content,
            originalJSON: originalContentJSON,
            originalPlainContent: originalPlainContent,
            originalProjectedMarkdown: originalProjectedMarkdown,
            reviewTexts: reviewSession.texts
        )
    }

    /// The snapshot saved under `copyID`, with the pictures and recordings
    /// it uses copied for it, links that name this writing pointed at the
    /// copy, and the passages still marked for review marked there too.
    private func saveEditsAsCopy(
        _ snapshot: EditsSnapshot, as copyID: String, over revision: Date?
    ) async throws -> LampDevotional? {
        let originalID = identifier
        let root = model.library.rootURL
        // Every pass, so a picture added while the copy was being saved is
        // in its folder too. Files already there are left as they are.
        if let from = LampPortableDevotionalMedia.folderURL(rootURL: root, scope: .devotional, ownerID: originalID),
           let to = LampPortableDevotionalMedia.folderURL(rootURL: root, scope: .devotional, ownerID: copyID) {
            try await Task.detached(priority: .userInitiated) {
                let files = FileManager.default
                guard files.fileExists(atPath: from.path) else { return }
                try files.createDirectory(at: to, withIntermediateDirectories: true)
                for name in try files.contentsOfDirectory(atPath: from.path)
                where !files.fileExists(atPath: to.appendingPathComponent(name).path) {
                    try files.copyItem(at: from.appendingPathComponent(name), to: to.appendingPathComponent(name))
                }
            }.value
        }
        // A link that names its writing (`lamp-media://<id>/…`) names the copy.
        // In the rich body's JSON its slashes may be escaped.
        func relinked(_ text: String) -> String {
            text.replacingOccurrences(of: "lamp-media://\(originalID)/", with: "lamp-media://\(copyID)/")
                .replacingOccurrences(of: #"lamp-media:\/\/\#(originalID)\/"#, with: #"lamp-media:\/\/\#(copyID)\/"#)
        }
        let markdown = relinked(snapshot.markdown)
        let body = try await WritingChatTurns.storedBody(
            markdown: markdown,
            originalJSON: snapshot.originalJSON.map(relinked),
            originalPlainContent: relinked(snapshot.originalPlainContent),
            bodyChanged: snapshot.markdown != snapshot.originalProjectedMarkdown
        )
        let d = snapshot.devotional
        guard let saved = try await model.savePersonalDevotional(LampDevotional(
            id: copyID, moduleID: d.moduleID, moduleName: d.moduleName, title: d.title,
            subtitle: d.subtitle, author: d.author, date: d.date, tags: d.tags, category: d.category,
            seriesName: d.seriesName, seriesOrder: d.seriesOrder, keyScriptures: d.keyScriptures,
            summary: d.summary, content: body.plainContent, contentJSON: body.contentJSON,
            footnotes: d.footnotes, mediaJSON: d.mediaJSON, created: d.created,
            lastModified: d.lastModified, isEditable: true
        ), ifNotNewerThan: revision ?? .distantPast) else { return nil }
        return saved
    }

    /// Writes what is waiting, on the way out.
    ///
    /// Both autosaves wait before writing — 1.5 seconds for the writing, 0.9
    /// for a workspace document — and both wait inside a `.task`, which is
    /// cancelled when the view goes away. Closing the window or leaving the
    /// editor inside that window therefore threw the last edit away, and
    /// nothing else caught it.
    ///
    /// Quitting runs this too (`LampPendingWrites`), and waits for what it
    /// starts: each write is counted before its task begins.
    private func flushPendingSaves() {
        if let newer = newerCopy {
            // Their edits are being kept, or could not be: try once more on
            // the way out, rather than leave them only in this window.
            if keepingFailed != nil { keepEdits(over: newer) }
        } else if isDirty, hasSavableContent {
            save()
        }
        if workspaceDocuments.contains(where: { $0.isDirty && !$0.hasExternalConflict }) {
            saveDirtyWorkspaceDocuments()
        }
    }

    private func save() {
        guard hasSavableContent, saveState != .saving, newerCopy == nil else { return }
        saveState = .saving
        // Quitting waits on this count, so it is taken before the task is,
        // and has to come down on every way out of it, the failures too:
        // counted inside, a save started on the way out was not yet counted
        // when quitting looked.
        LampPendingWrites.shared.begin()
        Task {
            defer { LampPendingWrites.shared.end() }
            let markdown = content
            let body: StoredWritingBody
            do {
                body = try await WritingChatTurns.storedBody(
                    markdown: markdown,
                    originalJSON: originalContentJSON,
                    originalPlainContent: originalPlainContent,
                    bodyChanged: markdown != originalProjectedMarkdown
                )
            } catch {
                saveState = .failed(error.localizedDescription)
                return
            }
            // The writing moved on while the body was being worked out, so this
            // save would write one document and record another as saved. The
            // edit that overtook it has already started the next autosave.
            guard content == markdown else {
                saveState = .idle
                return
            }

            let submitted = editedFields
            let previouslySavedContent = savedFields.indices.contains(9) ? savedFields[9] : ""
            let devotional = LampDevotional(
                id: identifier,
                moduleID: "personal-devotionals",
                moduleName: "My Writing",
                title: title,
                subtitle: subtitle,
                author: author,
                date: date,
                tags: tags.split(separator: ",").map {
                    String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty },
                category: categoryToSave,
                seriesName: seriesName,
                seriesOrder: seriesName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : seriesOrder,
                keyScriptures: keyScriptures,
                summary: summary,
                content: body.plainContent,
                contentJSON: body.contentJSON,
                footnotes: footnotes,
                mediaJSON: mediaJSON,
                created: createdDate ?? Date(),
                lastModified: Date(),
                isEditable: true
            )
            do {
                let written = if let heldRevision {
                    try await model.savePersonalDevotional(
                        devotional, reviewTexts: reviewSession.texts, ifNotNewerThan: heldRevision
                    )
                } else {
                    try await model.savePersonalDevotional(devotional, reviewTexts: reviewSession.texts)
                }
                guard let saved = written else {
                    // A newer copy is stored; nothing was written over it.
                    // The edits are kept inside this task, which quitting and
                    // closing already wait for. Still saving until it has
                    // chosen, so the check made as the writings change stands
                    // back rather than start a second copy of the same edits.
                    if let stored = model.devotionals.first(where: { $0.id == identifier }) {
                        await readPage()
                        if !isDirty || editedFields == fields(of: stored) {
                            // Nothing typed since, or typed what arrived.
                            takeIn(stored)
                        } else {
                            newerCopy = stored
                            keepingFailed = nil
                            saveState = .idle
                            await keepEditsNow()
                        }
                    }
                    saveState = .idle
                    return
                }
                heldRevision = saved.lastModified
                if writingHold == nil, !editorIsGone {
                    writingHold = WritingChatTurns.hold(
                        saved.id, revision: saved.lastModified ?? Date(),
                        digest: LampAgentRemoteWritingRevision.digest(of: saved)
                    )
                } else {
                    writingHold?.update(
                        revision: saved.lastModified ?? Date(),
                        digest: LampAgentRemoteWritingRevision.digest(of: saved)
                    )
                }
                createdDate = saved.created
                originalContentJSON = saved.contentJSON
                originalPlainContent = saved.content
                originalProjectedMarkdown = submitted[9]
                // The library supplies a useful display title for body-only
                // drafts. Adopt it only if the user did not type a title while
                // this save was in flight.
                if title == submitted[0] {
                    title = saved.title
                }
                // Compare against what was actually written, so edits made while the
                // save was in flight stay marked dirty.
                var persistedFields = submitted
                persistedFields[0] = saved.title
                savedFields = persistedFields
                saveState = .saved
                lookForNewerCopy(in: model.devotionals)
                await recordPrimaryUserRevision(
                    before: previouslySavedContent,
                    after: submitted[9]
                )
            } catch {
                saveState = .failed(error.localizedDescription)
            }
        }
    }

    /// Adds a footnote where the caret is: its marker in the prose, and an
    /// empty definition with the writing's others beneath it.
    ///
    /// The label is a number nothing else has taken, counted across the prose
    /// and the Footnotes field together — a new note must not collide with one
    /// kept in the field, which the editor cannot see.
    ///
    /// The editor opens the new note's panel itself, empty and focused, so
    /// adding a footnote and writing it are one gesture. Asking for the text
    /// first, as the phone does with a sheet, would be a heavier way in.
    private func insertFootnote() {
        guard let coordinator = tipTapCoordinator else { return }
        coordinator.insertFootnote(
            id: LampFootnoteLabels.next(content: content, field: footnotes)
        )
    }

    /// Takes the writer to the note a marker refers to, when that note is kept
    /// in the Footnotes field rather than written beneath the prose.
    ///
    /// The caret goes to the start of what the note says, not over it: the
    /// phone does the same for a note on the page, and a selected line would
    /// be gone on the first keystroke.
    ///
    /// Nothing happens when the field has no definition for that label. The
    /// marker is then one nothing defines anywhere, and opening the sidebar to
    /// show the writer an absence would be worse than leaving the click alone.
    private func revealFootnote(_ label: String) {
        guard let found = LampFootnoteField.location(of: label, in: footnotes) else { return }
        // The sidebar holds either the details or the agent's workspace, so
        // showing the field means putting the details back. One click returns
        // the workspace, and the writer asked to see this note.
        withAnimation(.lampPaneReveal) {
            showingAgentWorkspace = false
            showsDetails = true
        }
        footnotesSelection = NSRange(location: found.content.location, length: 0)
        footnotesRevealToken += 1
    }

    /// Writes the saved body to the workspace's history, after the devotional
    /// itself is durable.
    ///
    /// `continuingLatest`, because `before` is this editor's own last-saved copy:
    /// an agent change may have landed since, and the store then records this
    /// edit as continuing from the agent's result rather than discarding it.
    private func recordPrimaryUserRevision(before: String, after: String) async {
        guard before != after else { return }
        let workspace = workspaceURL
        do {
            try await DevotionalAgentRevisionHistory.shared.record(
                kind: .userEdit,
                documentPath: DevotionalAgentRevisionStore.primaryDocumentPath,
                before: before,
                after: after,
                continuingLatest: true,
                in: workspace
            )
        } catch {
            // The devotional itself is already durable at this point. A later
            // save can resume history without misreporting the successful save.
        }
    }

    private func openPresentationDeck(_ deck: LampPresentationDeck?) {
        if let deck {
            openWindow(
                id: "slide-studio",
                value: SlideStudioRequest(deckID: deck.id)
            )
            return
        }

        if model.devotionals.contains(where: { $0.id == identifier }) {
            openWindow(
                id: "slide-studio",
                value: SlideStudioRequest(devotionalID: identifier)
            )
            return
        }

        guard hasSavableContent, !isOpeningPresentation else { return }
        isOpeningPresentation = true
        save()
        Task { @MainActor in
            for _ in 0..<50 {
                if model.devotionals.contains(where: { $0.id == identifier }) {
                    openWindow(
                        id: "slide-studio",
                        value: SlideStudioRequest(devotionalID: identifier)
                    )
                    isOpeningPresentation = false
                    return
                }
                if case .failed = saveState {
                    isOpeningPresentation = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else {
                    isOpeningPresentation = false
                    return
                }
            }
            saveState = .failed("Save this writing before building its presentation.")
            isOpeningPresentation = false
        }
    }

    @MainActor
    private func monitorLinkedPresentationDecks() async {
        let rootURL = model.library.rootURL
        while !Task.isCancelled {
            // Finding this writing's decks means decoding every deck in the
            // library, every two seconds, for a list that only changes when
            // someone builds a deck. Not on the thread taking keystrokes.
            let devotionalID = identifier
            let decks = await Task.detached(priority: .utility) {
                try? LinkedPresentationDeckLookup.decks(
                    rootURL: rootURL,
                    devotionalID: devotionalID
                )
            }.value
            if let decks, decks != linkedPresentationDecks {
                linkedPresentationDecks = decks
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private static var today: String {
        LampCalendarDate.today()
    }

    /// What a new writing starts as. Not a kind named here: the vocabulary is
    /// core's, and a writing of no kind at all is a fair reading of an empty
    /// one, so this cannot be a crash either.
    private static var firstKindOffered: String {
        LampWritingCategory.suggestions.first.flatMap(LampWritingCategory.displayName) ?? ""
    }

    /// The kind to store. The rule is core's, because the phone needs the same
    /// one and neither app can test it from inside a view.
    private var categoryToSave: String? {
        LampWritingCategory.kindToStore(shown: category, held: originalCategory)
    }

}

/// Restarts the autosave countdown whenever the document changes, so the save lands
/// once typing pauses rather than on every keystroke.
private struct AutosaveTrigger: Equatable {
    let fields: [String]
    let canSave: Bool
}

/// The box around an inspector's text area: the system's text ground with a
/// hairline, as a bordered text field is drawn, so it reads as somewhere to
/// type and not as an empty panel.
private struct InspectorTextBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14))
            }
    }
}

/// A field of the writing inspector: the system's text ground and a hairline
/// strong enough to hold its edge on the dark inspector, where the bordered
/// field's own outline all but vanished.
private struct InspectorFieldBox: ViewModifier {
    var trailingInset: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .font(.body)
            .padding(.leading, 8)
            .padding(.trailing, trailingInset)
            .frame(minHeight: 28)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18))
            }
    }
}

/// The writing's date: the day, which opens a calendar when clicked, and one
/// menu for the rest. Three icon buttons beside a field (calendar, today,
/// remove) read as a busy cluster of look-alike glyphs.
private struct WritingDateField: View {
    @Binding var storedValue: String
    @State private var showingCalendar = false

    private var trimmed: String { storedValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsed: Date? { LampCalendarDate.date(from: trimmed) }

    private var selection: Binding<Date> {
        Binding(
            get: { parsed ?? Calendar.current.startOfDay(for: Date()) },
            set: { storedValue = LampCalendarDate.storedString(from: $0) }
        )
    }

    var body: some View {
        HStack(spacing: 4) {
            if parsed != nil {
                DatePicker("Date", selection: selection, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                Menu {
                    Button("Choose from Calendar…", systemImage: "calendar") {
                        showingCalendar = true
                    }
                    Button("Today", systemImage: "calendar.badge.clock") {
                        storedValue = LampCalendarDate.today()
                    }
                    .disabled(parsed.map(Calendar.current.isDateInToday) ?? false)
                    Button("Remove Date", systemImage: "xmark.circle", role: .destructive) {
                        storedValue = ""
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Date Options")
                .help("Choose from a calendar, use today, or remove the date")
            } else {
                if !trimmed.isEmpty {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .help("Unrecognized date: \(storedValue)")
                }
                Button(trimmed.isEmpty ? "Add Date" : "Choose Date", systemImage: "calendar.badge.plus") {
                    storedValue = LampCalendarDate.today()
                }
            }
        }
        .frame(minHeight: 28)
        .popover(isPresented: $showingCalendar, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose Date")
                    .font(.headline)
                DatePicker("Date", selection: selection, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
            }
            .padding()
        }
    }
}


/// Done, last in the toolbar and in a group of its own.
struct WritingDoneToolbarItem: ToolbarContent {
    let done: WritingEditorDone

    private var button: some View {
        Button("Done", action: done.action)
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .help("\(done.help) (⇧⌘E)")
    }

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
            ToolbarItem { button }
        } else {
            ToolbarItem { button }
        }
    }
}

/// The way back from editing a writing, where the host offers one: back to
/// reading in place, or the window closed.
struct WritingEditorDone {
    let help: String
    let action: () -> Void
}

/// Whether the writing editor's assistant pane is open, for a host that
/// makes room for it.
struct WritingAssistantOpenKey: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

extension EnvironmentValues {
    @Entry var writingEditorDone: WritingEditorDone?
}
