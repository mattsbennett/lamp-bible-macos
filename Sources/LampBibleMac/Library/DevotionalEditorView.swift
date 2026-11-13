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

    init(devotionalID: String? = nil) {
        self.devotionalID = devotionalID
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
private struct StoredDevotionalBody: Sendable {
    let contentJSON: String?
    let plainContent: String
}

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
                Slider(
                    value: Binding(
                        get: { displayedSize },
                        set: { preferredSize = min(max($0, minimumSize), maximumSize) }
                    ),
                    in: minimumSize...max(minimumSize, maximumSize),
                    step: 10
                ) {
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
    @State private var tipTapSelection = TipTapSelectionState()
    /// The text selected in the visual editor, read from the page a moment
    /// after the selection settles, while the agent pane is open to be told.
    @State private var visualSelectedText = ""
    @State private var visualSelectionRead: Task<Void, Never>?
    @State private var visualEditorIsReady = false
    @State private var find = WritingFindController()
    @State private var markdownFinder = MarkdownTextFinder()
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

    private var mediaReferences: [LampDevotionalMediaReference] {
        guard let mediaJSON else { return [] }
        return (try? JSONDecoder().decode(
            [LampDevotionalMediaReference].self, from: Data(mediaJSON.utf8)
        )) ?? []
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

    private var workspaceDocumentEditTrigger: [String] {
        workspaceDocuments.map { "\($0.id)\u{0}\($0.text)" }
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
                    Group {
                        if showingAgentWorkspace {
                            DevotionalAgentWorkspaceView(
                                libraryRootURL: model.library.rootURL,
                                bundledModulesArchiveURL: Bundle.main.url(
                                    forResource: "bundled_modules.db",
                                    withExtension: "zlib"
                                ),
                                agentAccessPolicy: agentAccessPolicy,
                                devotionalID: identifier,
                                draftMarkdown: content,
                                contextDocument: agentContextDocument,
                                editorFocus: editorFocus,
                                importDraft: { importedDraft in
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
                        } else {
                            detailsPane
                        }
                    }
                        .frame(width: sidebarWidth, height: geometry.size.height)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
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
        .task(id: AutosaveTrigger(fields: editedFields, canSave: hasSavableContent)) {
            guard isDirty, hasSavableContent else { return }
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            save()
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
        }
        .focusedSceneValue(\.writingFind, find)
        .onChange(of: activeFindTarget.map(ObjectIdentifier.init), initial: true) {
            find.attach(activeFindTarget)
        }
        // What is selected when the agent pane opens, or another document is
        // shown, has had no change of selection to report it.
        .onChange(of: showingAgentWorkspace) { readVisualSelectionSoon() }
        // Turned off while the agent's pane is open: it closes, and the
        // details take its place as they would on closing it by hand.
        .onChange(of: aiFeaturesEnabled) { _, enabled in
            if !enabled, showingAgentWorkspace {
                showingAgentWorkspace = false
                showsDetails = true
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
                    coordinator.onFootnoteNotInPage = { label in
                        revealFootnote(label)
                    }
                    coordinator.onSelectionChanged = { selection in
                        DispatchQueue.main.async {
                            tipTapSelection = selection
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
        // Shown while the web view is held back until its first paint, and behind
        // it thereafter. Same colour the page is told to paint, so the reveal is
        // invisible.
        .background(Color(nsColor: .windowBackgroundColor))
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
            .padding(.vertical, 7)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
                .padding(.vertical, 7)
            }
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            MarkdownTextEditor(
                text: activeTextBinding,
                selection: activeSelectionBinding,
                fontSize: editorFontSize,
                finder: markdownFinder,
                measure: 76
            )
            // The text view draws no background of its own, so without this it
            // shows whatever happens to be behind the window — which is close to
            // the colour the visual editor is told to paint, but not equal to it.
            // Naming the colour here makes the two surfaces match by construction.
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var statusBar: some View {
        let statistics = WritingStatistics.measuring(markdown: activeText)
        return HStack(spacing: 10) {
            Text(activeSaveStateDescription)
                .foregroundStyle(activeSaveStateIsProblem ? AnyShapeStyle(.red) : AnyShapeStyle(Color.lampSecondaryText))

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
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var activeSaveStateIsProblem: Bool {
        if let document = activeWorkspaceDocument {
            return document.errorMessage != nil || document.hasExternalConflict
        }
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
        // A ground of its own, a step off the page in either appearance, so
        // the inspector reads as beside the writing rather than part of it:
        // on the same dark as the page, the two ran together.
        .background(Self.inspectorGround)
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

    private static let inspectorGround = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.105, alpha: 1)
            : NSColor(srgbRed: 0.955, green: 0.955, blue: 0.962, alpha: 1)
    })

    /// What an empty field is for, in the place its text will go.
    private func fieldPlaceholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(Color.lampSecondaryText)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: saveActiveDocument) {
                Image(nsImage: Self.saveIcon)
            }
            .accessibilityLabel("Save")
            .disabled(!activeDocumentCanSave)
            .keyboardShortcut("s", modifiers: .command)
            .help(activeSaveHelp)
        }

        ToolbarItem(placement: .navigation) {
            Button("Revision History", systemImage: "clock.arrow.circlepath") {
                showActiveRevisionHistory()
            }
            .labelStyle(.iconOnly)
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
            .help("Companion files in this writing's workspace")
        }

        ToolbarItem {
            LampSegmentedPicker(
                "Writing Surface",
                selection: editorSurfaceSelection,
                items: DevotionalEditorMode.allCases.map { .init(id: $0, title: $0.title) }
            )
            .disabled(!activeDocumentSupportsVisual)
            .help(activeDocumentSupportsVisual
                ? "Choose the writing surface"
                : "Plain text files use the Markdown editor")
        }

        ToolbarItem {
            Toggle(isOn: Binding(
                get: { showsDetails && !showingAgentWorkspace },
                set: { isShowing in
                    showingAgentWorkspace = false
                    showsDetails = isShowing
                }
            )) {
                Label("Details", systemImage: "info.circle")
            }
            // Shown on as a neutral pressed state, as Pages and Notes show
            // their inspectors, not in the accent: a red disc in the title
            // bar outshouted the writing beneath it.
            .tint(.secondary)
            .help(showsDetails ? "Hide details" : "Show details")
        }

        if aiFeaturesEnabled {
        ToolbarItem {
            Toggle(isOn: Binding(
                get: { showingAgentWorkspace },
                set: { isShowing in
                    showingAgentWorkspace = isShowing
                    showsDetails = !isShowing
                }
            )) {
                Label("Agent", systemImage: "sparkles")
            }
            .tint(.secondary)
            .help(showingAgentWorkspace ? "Hide agent workspace" : "Show agent workspace")
        }
        }

        ToolbarItem {
            presentationToolbarControl
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
        return hasSavableContent && isDirty && saveState != .saving
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

    private var activeSaveHelp: String {
        if let document = activeWorkspaceDocument {
            if document.hasExternalConflict { return "Resolve this file conflict before saving" }
            return document.isDirty ? "Save \(title(of: document))" : "This file is up to date"
        }
        return hasSavableContent
            ? "Save this writing"
            : "Add content before saving"
    }

    private var agentContextDocument: String {
        let scriptureList = keyScriptures.isEmpty
            ? "- None selected"
            : keyScriptures.map { "- \($0.displayDescription)" }.joined(separator: "\n")
        let tagList = tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "None" : tags
        return """
        # Devotional brief

        - Title: \(title.isEmpty ? "Untitled" : title)
        - Subtitle: \(subtitle.isEmpty ? "None" : subtitle)
        - Author: \(author.isEmpty ? "Unknown" : author)
        - Date: \(date)
        - Category: \(LampWritingCategory.displayName(category) ?? "None")
        - Tags: \(tagList)
        - Series: \(seriesName.isEmpty ? "None" : "\(seriesName), item \(seriesOrder)")

        ## Key scripture

        \(scriptureList)

        ## Summary or intent

        \(summary.isEmpty ? "No summary has been written yet." : summary)

        ## Existing footnotes

        \(footnotes.isEmpty ? "No footnotes have been written yet." : footnotes)
        """ + "\n"
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
            let snapshots = try WorkspaceTextFileStore.snapshots(
                in: workspaceURL,
                excludingFilenames: [
                    DevotionalAgentWorkspaceFiles.draftFilename,
                    DevotionalAgentWorkspaceFiles.contextFilename,
                    "AGENTS.md",
                    "CLAUDE.md",
                ]
            )
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
        identifier = devotional.id
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
        hasLoaded = true
    }

    /// Writes what is waiting, on the way out.
    ///
    /// Both autosaves wait before writing — 1.5 seconds for the writing, 0.9
    /// for a workspace document — and both wait inside a `.task`, which is
    /// cancelled when the view goes away. Closing the window or leaving the
    /// editor inside that window therefore threw the last edit away, and
    /// nothing else caught it.
    ///
    /// This covers leaving while the app runs. Quitting is still unguarded:
    /// `save()` finishes on a task of its own, and the process does not wait
    /// for it. That wants an application-level hook rather than a view's.
    private func flushPendingSaves() {
        if isDirty, hasSavableContent { save() }
        if workspaceDocuments.contains(where: { $0.isDirty && !$0.hasExternalConflict }) {
            saveDirtyWorkspaceDocuments()
        }
    }

    private func save() {
        guard hasSavableContent, saveState != .saving else { return }
        saveState = .saving
        Task {
            // Quitting waits on this count, so it has to come down on every
            // way out of this task, including the failures.
            LampPendingWrites.shared.begin()
            defer { LampPendingWrites.shared.end() }
            let markdown = content
            let body: StoredDevotionalBody
            do {
                body = try await Self.storedBody(
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
                let saved = try await model.savePersonalDevotional(devotional)
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
                await recordPrimaryUserRevision(
                    before: previouslySavedContent,
                    after: submitted[9]
                )
            } catch {
                saveState = .failed(error.localizedDescription)
            }
        }
    }

    /// A devotional's body as it will be stored: the Markdown projected back
    /// into the rich JSON it came from, where there is any, and the plain text
    /// the library searches.
    ///
    /// Worked out off the main actor. Projecting a talk-length manuscript back
    /// into its JSON costs about twenty milliseconds on a Release build —
    /// measured on nine thousand words — and it used to run on the keystroke
    /// thread every time the autosave landed, which is what the writer felt as
    /// the editor hesitating. `Task { }` on its own is no help here: `View` is
    /// main-isolated, so everything a view starts stays on the main thread
    /// unless it is detached.
    private static func storedBody(
        markdown: String,
        originalJSON: String?,
        originalPlainContent: String,
        bodyChanged: Bool
    ) async throws -> StoredDevotionalBody {
        guard bodyChanged else {
            return StoredDevotionalBody(
                contentJSON: originalJSON,
                plainContent: originalJSON == nil ? markdown : originalPlainContent
            )
        }
        guard let originalJSON else {
            return StoredDevotionalBody(contentJSON: nil, plainContent: markdown)
        }
        return try await Task.detached(priority: .userInitiated) {
            // JSON that is only a carrier for Markdown has nothing structured
            // to keep, so the writing itself is the body.
            guard LampPortableDevotionalMedia.plainMarkdown(from: originalJSON) == nil else {
                return StoredDevotionalBody(contentJSON: nil, plainContent: markdown)
            }
            let json = try LampPortableDevotionalContent.replacingMarkdown(
                markdown, in: originalJSON
            )
            return StoredDevotionalBody(
                contentJSON: json,
                plainContent: LampPortableDevotionalContent.plainText(from: json) ?? ""
            )
        }.value
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
        showingAgentWorkspace = false
        showsDetails = true
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

    private static let saveIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.labelColor.setStroke()

            let outline = NSBezierPath(
                roundedRect: rect.insetBy(dx: 1, dy: 1),
                xRadius: 2,
                yRadius: 2
            )
            outline.lineWidth = 1.5
            outline.stroke()

            let label = NSBezierPath(
                roundedRect: NSRect(x: 3, y: 2.5, width: 10, height: 5),
                xRadius: 1,
                yRadius: 1
            )
            label.lineWidth = 1.25
            label.stroke()

            let shutter = NSBezierPath(
                roundedRect: NSRect(x: 4, y: 9, width: 8, height: 4.5),
                xRadius: 0.75,
                yRadius: 0.75
            )
            shutter.lineWidth = 1.25
            shutter.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Save"
        return image
    }()
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
