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

private enum DevotionalSaveState: Equatable {
    case idle
    case saving
    case saved
    case failed(String)
}

private struct DevotionalWorkspaceEditorDocument: Identifiable, Equatable {
    let url: URL
    var text: String
    var persistedText: String
    var selection = NSRange(location: 0, length: 0)
    var externalText: String?
    var wasRemovedExternally = false
    var errorMessage: String?

    var id: String { url.lastPathComponent }
    var title: String { url.lastPathComponent }
    var previewTitle: String { url.deletingPathExtension().lastPathComponent }
    var isDirty: Bool { text != persistedText }
    var hasExternalConflict: Bool { externalText != nil || wasRemovedExternally }
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

/// Which surface the author types on. Preview is deliberately not one of these:
/// it answers "am I writing or reading?", which is a different question from
/// "which editor am I typing in", and folding the two into one picker is what made
/// the old three-way control hard to read.
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

private struct DevotionalSidebarResizeHandle: View {
    @Binding var preferredWidth: Double
    let displayedWidth: Double
    let minimumWidth: Double
    let maximumWidth: Double

    @State private var widthAtDragStart: Double?
    @State private var isShowingResizeCursor = false

    var body: some View {
        Divider()
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                // Keep the separator visually light while making it forgiving
                // enough to grab beside a text editor or terminal.
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { isHovering in
                        setResizeCursor(isHovering)
                    }
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                let start = widthAtDragStart ?? displayedWidth
                                widthAtDragStart = start
                                preferredWidth = min(
                                    max(start - value.translation.width, minimumWidth),
                                    maximumWidth
                                )
                            }
                            .onEnded { _ in widthAtDragStart = nil }
                    )
                    .onDisappear { setResizeCursor(false) }
            }
            .zIndex(1)
    }

    private func setResizeCursor(_ isShowing: Bool) {
        guard isShowing != isShowingResizeCursor else { return }
        isShowingResizeCursor = isShowing
        if isShowing {
            NSCursor.resizeLeftRight.push()
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

private struct DevotionalEditorToolbarScrollView<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var scrollState = DevotionalToolbarScrollState()
    @State private var scrollPosition = ScrollPosition(x: 0)

    private let scrollStep: CGFloat = 240

    var body: some View {
        ScrollView(.horizontal) {
            content
        }
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
    @AppStorage("devotional.editor.showsDetails") private var showsDetails = true
    @AppStorage("devotional.editor.detailsWidth") private var detailsWidth = 320.0
    @AppStorage("devotional.editor.agentWidth") private var agentWidth = 480.0
    /// The placement a newly opened editor inherits. Writing it is how a choice
    /// carries to the next window; it is deliberately *not* what any open window
    /// reads, because two editors sharing one live value fight over it — a
    /// restored window with content re-asserting `.full` was enough to undo the
    /// fallback a new, empty window had just applied to itself.
    @AppStorage("writing.preview.placement")
    private var storedPreviewPlacement = WritingPreviewPlacement.hidden
    /// This window's own placement, seeded from the stored one when it opens.
    @State private var windowPreviewPlacement: WritingPreviewPlacement?
    @AppStorage("writing.preview.width") private var previewWidth = 460.0
    @AppStorage("agent.moduleAccess.enabled") private var agentModuleAccessEnabled = true
    @AppStorage("agent.moduleAccess.scope") private var agentModuleAccessScope = AgentModuleAccessScope.enabledModules.rawValue
    @AppStorage("agent.moduleAccess.personal") private var agentPersonalContentEnabled = false
    @State private var showingAgentWorkspace = false
    @State private var linkedPresentationDecks: [LampPresentationDeck] = []
    @State private var isOpeningPresentation = false
    @State private var workspaceDocuments: [DevotionalWorkspaceEditorDocument] = []
    @State private var selectedWorkspaceDocumentID: String?
    @State private var workspaceIsAvailable = false
    @State private var workspaceDocumentsInitialized = false
    @State private var revisionHistoryRequest: DevotionalRevisionHistoryRequest?
    @State private var showingNewWorkspaceDocument = false

    /// Visual editing is deliberately the approachable default; Markdown is the
    /// source surface behind it.
    @State private var editorMode: DevotionalEditorMode = .visual
    /// How far the Markdown surface is scrolled, mirrored into a split preview so
    /// the rendered prose stays beside the paragraph being written.
    @State private var editorScrollFraction: Double?
    @State private var identifier = UUID().uuidString
    @State private var createdDate: Date?
    @State private var title = ""
    @State private var subtitle = ""
    @State private var author = ""
    @State private var date = ""
    @State private var tags = ""
    @State private var category = "devotional"
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
    @State private var tipTapCoordinator: TipTapEditorCoordinator?
    @State private var tipTapSelection = TipTapSelectionState()
    @State private var visualEditorIsReady = false
    @State private var saveState: DevotionalSaveState = .idle
    @State private var showingAudioRecorder = false
    @State private var hasLoaded = false
    /// The document as last written to the library. Dirtiness is this compared with
    /// the live fields — a snapshot rather than a flag, so no ordering between
    /// loading and change-tracking can leave a freshly opened devotional "edited".
    @State private var savedFields: [String] = []
    /// Debounced so the preview isn't re-parsed on every keystroke.
    @State private var previewContent = ""

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

    private var activeEditorMode: DevotionalEditorMode {
        isEditingPrimaryDocument ? editorMode : .markdown
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

    private var workspaceDocumentEditTrigger: [String] {
        workspaceDocuments.map { "\($0.id)\u{0}\($0.text)" }
    }

    private var previewPlacement: WritingPreviewPlacement {
        windowPreviewPlacement ?? storedPreviewPlacement
    }

    /// Changing placement from a control updates this window and the inherited
    /// default together, so the next editor opens the way this one was left.
    private var previewPlacementBinding: Binding<WritingPreviewPlacement> {
        Binding(
            get: { previewPlacement },
            set: { newPlacement in
                windowPreviewPlacement = newPlacement
                storedPreviewPlacement = newPlacement
            }
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
                contentColumn(width: editorWidth)
                    // Horizontal editor toolbars have a much wider intrinsic
                    // content size than the document. Give the complete editor
                    // column its exact share of the split so those ScrollViews
                    // scroll inside this viewport instead of expanding beneath
                    // the sidebar.
                    .frame(width: editorWidth, height: geometry.size.height)
                    .clipped()
                if usesSidePane {
                    DevotionalSidebarResizeHandle(
                        preferredWidth: showingAgentWorkspace ? $agentWidth : $detailsWidth,
                        displayedWidth: sidebarWidth,
                        minimumWidth: minimumSidebarWidth,
                        maximumWidth: maximumSidebarWidth
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
                                importDraft: { importedDraft in
                                    content = importedDraft
                                    previewContent = importedDraft
                                }
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
        .navigationTitle(title.isEmpty ? "New Devotional" : title)
        .navigationSubtitle(activeSaveStateDescription)
        .toolbar { editorToolbar }
        .task(id: request) {
            editorMode = .visual
            load()
            // Seeds this window only. Writing the stored default here would push
            // the fallback onto every other open editor too.
            windowPreviewPlacement = storedPreviewPlacement
                .opening(hasContent: hasSavableContent)
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
        .task(id: content) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            previewContent = content
        }
        .task(id: workspaceDocumentEditTrigger) {
            guard workspaceDocuments.contains(where: { $0.isDirty && !$0.hasExternalConflict }) else {
                return
            }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            saveDirtyWorkspaceDocuments()
        }
        // Opening the preview should show the draft as it stands, not whatever the
        // debounce last caught.
        .onChange(of: previewPlacement) { _, placement in
            guard placement.isVisible else { return }
            refreshPreview()
        }
        .focusedSceneValue(\.writingPreviewPlacement, previewPlacementBinding)
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

    /// Everything that belongs to the document itself: the writing surface, the
    /// preview when it is on screen, and the status bar beneath both. The details
    /// and agent sidebars sit outside this, since they are about the document
    /// rather than part of it.
    private func contentColumn(width: Double) -> some View {
        VStack(spacing: 0) {
            documentTabBar
            Divider()

            switch previewPlacement {
            case .hidden:
                editorPane
            case .full:
                previewPane
            case .split:
                splitEditorAndPreview(totalWidth: width)
            }

            Divider()
            statusBar
        }
    }

    private var documentTabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    documentTab(
                        id: nil,
                        title: "Main Prose",
                        systemImage: "doc.text",
                        isDirty: isDirty,
                        hasConflict: false
                    )
                    ForEach(workspaceDocuments) { document in
                        documentTab(
                            id: document.id,
                            title: document.title,
                            systemImage: "doc.plaintext",
                            isDirty: document.isDirty,
                            hasConflict: document.hasExternalConflict
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .scrollIndicators(.hidden)

            Divider()
                .frame(height: 22)

            HStack(spacing: 10) {
                Button("New Markdown File", systemImage: "plus") {
                    showingNewWorkspaceDocument = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Create a companion Markdown file")

                Button("Reveal Workspace", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([workspaceURL])
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!workspaceIsAvailable)
                .help("Reveal the writing workspace in Finder")
            }
            .padding(.horizontal, 9)
        }
        .frame(height: 36)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func documentTab(
        id: String?,
        title: String,
        systemImage: String,
        isDirty: Bool,
        hasConflict: Bool
    ) -> some View {
        let isSelected = selectedWorkspaceDocumentID == id
        return Button {
            selectWorkspaceDocument(id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Text(title)
                    .lineLimit(1)
                if hasConflict {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("File conflict")
                } else if isDirty {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("Unsaved changes")
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func selectWorkspaceDocument(_ id: String?) {
        guard selectedWorkspaceDocumentID != id else { return }
        if isEditingPrimaryDocument, editorMode == .visual, let coordinator = tipTapCoordinator {
            coordinator.getContent { latestMarkdown in
                DispatchQueue.main.async {
                    content = latestMarkdown
                    previewContent = latestMarkdown
                }
            }
        }
        selectedWorkspaceDocumentID = id
        editorScrollFraction = nil
    }

    private func splitEditorAndPreview(totalWidth: Double) -> some View {
        let dividerWidth = 1.0
        let minimumEditorWidth = 320.0
        let desiredMinimumPreviewWidth = 280.0
        let maximumPreviewWidth = max(totalWidth - minimumEditorWidth - dividerWidth, 0)
        let minimumPreviewWidth = min(desiredMinimumPreviewWidth, maximumPreviewWidth)
        let resolvedPreviewWidth = min(
            max(previewWidth, minimumPreviewWidth),
            maximumPreviewWidth
        )
        let resolvedEditorWidth = max(totalWidth - resolvedPreviewWidth - dividerWidth, 0)

        return HStack(spacing: 0) {
            editorPane
                .frame(width: resolvedEditorWidth)
                .clipped()
            DevotionalSidebarResizeHandle(
                preferredWidth: $previewWidth,
                displayedWidth: resolvedPreviewWidth,
                minimumWidth: minimumPreviewWidth,
                maximumWidth: maximumPreviewWidth
            )
            previewPane
                .frame(width: resolvedPreviewWidth)
                .clipped()
        }
    }

    @ViewBuilder
    private var editorPane: some View {
        if isEditingPrimaryDocument {
            ZStack {
                visualEditorPane
                if editorMode == .markdown {
                    markdownEditorPane
                }
            }
        } else {
            markdownEditorPane
        }
    }

    // MARK: - Panes

    private var visualEditorPane: some View {
        VStack(spacing: 0) {
            if editorMode == .visual {
                visualFormattingToolbar
                Divider()
            }
            TipTapEditorView(
                markdownContent: $content,
                fontSize: editorFontSize,
                mediaScopeID: identifier,
                libraryRootURL: model.library.rootURL,
                isVisible: editorMode == .visual,
                mediaReferences: mediaReferences,
                onCoordinatorReady: { coordinator in
                    tipTapCoordinator = coordinator
                    visualEditorIsReady = true
                    coordinator.onSelectionChanged = { selection in
                        DispatchQueue.main.async {
                            tipTapSelection = selection
                        }
                    }
                }
            )
        }
        // Shown while the web view is held back until its first paint, and behind
        // it thereafter. Same colour the page is told to paint, so the reveal is
        // invisible.
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear {
            visualEditorIsReady = false
            tipTapSelection = TipTapSelectionState()
        }
    }

    private var visualFormattingToolbar: some View {
        DevotionalEditorToolbarScrollView {
            HStack(alignment: .bottom, spacing: 14) {
                editorControlGroup("Style") {
                    Menu {
                        Button("Paragraph") { tipTapCoordinator?.applyStyle(.paragraph) }
                        Divider()
                        Button("Heading 1") { tipTapCoordinator?.applyStyle(.heading1) }
                        Button("Heading 2") { tipTapCoordinator?.applyStyle(.heading2) }
                        Button("Heading 3") { tipTapCoordinator?.applyStyle(.heading3) }
                    } label: {
                        Label(visualStyleLabel, systemImage: "textformat.size")
                    }
                    .help("Paragraph and heading style")
                }

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
                        Label("Table", systemImage: "tablecells")
                    }
                    .labelStyle(.iconOnly)
                    .help("Insert table")
                }

                Divider()
                    .frame(height: 38)

                editorControlGroup("Insert") {
                    Button("Scripture", systemImage: "book") { insertScriptureLink() }
                        .disabled(model.selectedVerseReference == nil)
                        .help(model.selectedVerseReference == nil
                            ? "Open a verse in the reader to link it"
                            : "Link selected text, or insert the verse reference")
                    Button("Media", systemImage: "paperclip") { attachMedia() }
                        .help("Attach an image or audio file")
                    Button("Record", systemImage: "mic") { showingAudioRecorder = true }
                        .help("Record audio into this devotional")
                }

                editorTextSizeControls
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!visualEditorIsReady)
            .padding(.horizontal, 12)
                .padding(.vertical, 9)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var markdownEditorPane: some View {
        VStack(spacing: 0) {
            DevotionalEditorToolbarScrollView {
                HStack(alignment: .bottom, spacing: 14) {
                    editorControlGroup("Text") {
                        ForEach([MarkdownCommand.bold, .italic]) { command in
                            markdownCommandButton(command)
                        }
                    }

                    editorControlGroup("Blocks") {
                        ForEach([MarkdownCommand.heading, .quote]) { command in
                            markdownCommandButton(command)
                        }
                    }

                    editorControlGroup("Lists") {
                        ForEach([MarkdownCommand.bulletList, .numberedList]) { command in
                            markdownCommandButton(command)
                        }
                    }

                    Divider()
                        .frame(height: 38)

                    editorControlGroup("Insert") {
                        Button("Scripture", systemImage: "book") { insertScriptureLink() }
                            .disabled(model.selectedVerseReference == nil)
                            .help(model.selectedVerseReference == nil
                                ? "Open a verse in the reader to link it"
                                : "Insert the verse selected in the reader")
                        Button("Media", systemImage: "paperclip") { attachMedia() }
                            .help("Attach an image or audio file")
                        Button("Record", systemImage: "mic") { showingAudioRecorder = true }
                            .help("Record audio into this devotional")
                    }

                    editorTextSizeControls
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            }
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            MarkdownTextEditor(
                text: activeTextBinding,
                selection: activeSelectionBinding,
                fontSize: editorFontSize,
                onScrollFractionChanged: previewPlacement == .split
                    ? { editorScrollFraction = $0 }
                    : nil
            )
            // The text view draws no background of its own, so without this it
            // shows whatever happens to be behind the window — which is close to
            // the colour the visual editor is told to paint, but not equal to it.
            // Naming the colour here makes the two surfaces match by construction.
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var previewPane: some View {
        WritingPreviewPane(
            title: activeWorkspaceDocument?.previewTitle ?? title,
            subtitle: isEditingPrimaryDocument ? subtitle : "",
            summary: isEditingPrimaryDocument ? summary : "",
            keyScriptures: isEditingPrimaryDocument ? keyScriptures : [],
            markdown: activeWorkspaceDocument?.text ?? previewContent,
            footnotes: isEditingPrimaryDocument ? footnotes : "",
            libraryRootURL: model.library.rootURL,
            devotionalID: identifier,
            mediaReferences: mediaReferences,
            placement: previewPlacementBinding,
            // The visual surface is a web view whose scrolling this side cannot
            // see, so only the Markdown surface offers a position to follow.
            followedScrollFraction: activeEditorMode == .markdown ? editorScrollFraction : nil
        )
    }

    private var statusBar: some View {
        let statistics = WritingStatistics.measuring(markdown: activeText)
        return HStack(spacing: 10) {
            Text(activeSaveStateDescription)
                .foregroundStyle(activeSaveStateIsProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))

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
            Text(statistics.readingTimeDescription)
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var activeSaveStateIsProblem: Bool {
        if let document = activeWorkspaceDocument {
            return document.errorMessage != nil || document.hasExternalConflict
        }
        if case .failed = saveState { return true }
        return false
    }

    private var detailsPane: some View {
        Form {
            Section("Details") {
                TextField("Title", text: $title)
                TextField("Subtitle", text: $subtitle)
                TextField("Author", text: $author)
                StoredCalendarDateField(title: "Date", storedValue: $date)
                TextField("Tags (comma separated)", text: $tags)
                Picker("Category", selection: $category) {
                    ForEach(Self.categories, id: \.self) { Text($0.capitalized).tag($0) }
                }
            }

            Section("Series") {
                TextField("Series", text: $seriesName)
                Stepper("Order: \(seriesOrder)", value: $seriesOrder, in: 0...10_000)
                    .disabled(seriesName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section("Key Scripture") {
                if keyScriptures.isEmpty {
                    Text("No key scripture added")
                        .foregroundStyle(.secondary)
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Summary") {
                TextEditor(text: $summary)
                    .font(.body)
                    .frame(minHeight: 70)
            }

            Section("Footnotes (Markdown)") {
                TextEditor(text: $footnotes)
                    .font(.body)
                    .frame(minHeight: 90)
            }
        }
        .formStyle(.grouped)
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

        ToolbarItem {
            Picker("Writing Surface", selection: editorSurfaceSelection) {
                ForEach(DevotionalEditorMode.allCases) { mode in
                    Text(mode.title).tag(Optional(mode))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!isEditingPrimaryDocument)
            .help(isEditingPrimaryDocument
                ? previewPlacement == .full
                    ? "Choose a writing surface to return to writing"
                    : "Choose the writing surface"
                : "Supporting documents use the Markdown editor")
        }

        ToolbarItem {
            previewToolbarControl
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
            .help(showsDetails ? "Hide details" : "Show details")
        }

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
            .help(showingAgentWorkspace ? "Hide agent workspace" : "Show agent workspace")
        }

        ToolbarItem {
            presentationToolbarControl
        }
    }

    /// Clicking swaps between writing and reading the way ⌘E does in Obsidian; the
    /// menu beside it chooses where the preview sits. One control, so the toolbar
    /// never implies that "preview" is a third kind of editor.
    private var previewToolbarControl: some View {
        Menu {
            Picker("Preview", selection: previewPlacementBinding) {
                ForEach(WritingPreviewPlacement.allCases, id: \.self) { placement in
                    Label(placement.title, systemImage: placement.systemImage)
                        .tag(placement)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label("Preview", systemImage: previewPlacement.isVisible ? "book.fill" : "book")
        } primaryAction: {
            previewPlacementBinding.wrappedValue = previewPlacement.toggled()
        }
        .help(previewPlacement.isVisible
            ? "Hide the preview (⌘E)"
            : "Preview this writing beside the editor (⌘E)")
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

    private var activeSaveHelp: String {
        if let document = activeWorkspaceDocument {
            if document.hasExternalConflict { return "Resolve this file conflict before saving" }
            return document.isDirty ? "Save \(document.title)" : "This file is up to date"
        }
        return hasSavableContent
            ? "Save this devotional"
            : "Add devotional content before saving"
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
        - Category: \(category)
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

    /// Nil while the preview fills the window, because no writing surface is on
    /// screen for the control to be reporting. Leaving it unselected also means
    /// either segment is a genuine change, so tapping the one that *was* chosen
    /// still brings the editor back — where a disabled control simply sat there,
    /// and a plain binding would have ignored the tap as a no-op.
    private var editorSurfaceSelection: Binding<DevotionalEditorMode?> {
        Binding(
            get: { previewPlacement == .full ? nil : activeEditorMode },
            set: { newMode in
                guard let newMode, isEditingPrimaryDocument else { return }
                // Choosing a surface means "show me that", so make room for it.
                if previewPlacement == .full { previewPlacementBinding.wrappedValue = .split }
                switchEditorMode(to: newMode)
            }
        )
    }

    private var visualStyleLabel: String {
        tipTapSelection.heading == 0 ? "Body" : "H\(tipTapSelection.heading)"
    }

    private func switchEditorMode(to newMode: DevotionalEditorMode) {
        guard isEditingPrimaryDocument, newMode != editorMode else { return }

        if editorMode == .visual, let coordinator = tipTapCoordinator {
            let contentBeforeSwitch = content
            coordinator.getContent { latestMarkdown in
                DispatchQueue.main.async {
                    // Do not overwrite an edit made immediately after switching
                    // into the Markdown surface.
                    if content == contentBeforeSwitch {
                        content = latestMarkdown
                        previewContent = latestMarkdown
                    }
                }
            }
        }
        editorMode = newMode
        // Leaving the Markdown surface leaves its scroll position behind with it.
        editorScrollFraction = nil
    }

    /// Brings the preview up to the current draft immediately. The visual surface
    /// holds the authoritative text inside a web view, so it has to be asked.
    private func refreshPreview() {
        guard isEditingPrimaryDocument else { return }
        guard editorMode == .visual, let coordinator = tipTapCoordinator else {
            previewContent = content
            return
        }
        previewContent = content
        coordinator.getContent { latestMarkdown in
            DispatchQueue.main.async {
                content = latestMarkdown
                previewContent = latestMarkdown
            }
        }
    }

    private func editorControlGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                content()
            }
        }
    }

    private var editorTextSizeControls: some View {
        let scale = LampTextScale.writingEditorText
        return editorControlGroup("Text Size") {
            Button("Smaller", systemImage: "minus") {
                editorFontSize = scale.stepped(editorFontSize, by: -1)
            }
            .labelStyle(.iconOnly)
            .disabled(!scale.canDecrease(editorFontSize))
            .help("Decrease editor text size")

            Text("\(editorFontSize.formatted(.number.precision(.fractionLength(0)))) pt")
                .monospacedDigit()
                .frame(minWidth: 36)

            Button("Larger", systemImage: "plus") {
                editorFontSize = scale.stepped(editorFontSize, by: 1)
            }
            .labelStyle(.iconOnly)
            .disabled(!scale.canIncrease(editorFontSize))
            .help("Increase editor text size")
        }
    }

    private func visualCommandButton(
        _ title: String,
        systemImage: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .frame(minWidth: 24)
            .background(
                isActive ? Color.accentColor.opacity(0.22) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .help(title)
    }

    private func markdownCommandButton(_ command: MarkdownCommand) -> some View {
        Button(command.title, systemImage: command.systemImage) {
            apply(command)
        }
        .labelStyle(.iconOnly)
        .frame(minWidth: 24)
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
        if isEditingPrimaryDocument, editorMode == .visual, let coordinator = tipTapCoordinator {
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
                    let legacyURL = "lamp-media://\(identifier)/\(storedURL.lastPathComponent)"
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
                    insert("[▶︎ \(label)](lamp-media://\(identifier)/\(storedURL.lastPathComponent))")
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
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
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
        do {
            revisionHistoryRequest = DevotionalRevisionHistoryRequest(
                documentID: activeWorkspaceDocument?.id,
                documentPath: documentPath,
                documentTitle: activeWorkspaceDocument?.title ?? "Main Prose",
                revisions: try DevotionalAgentRevisionStore.revisions(
                    in: workspaceURL,
                    documentPath: documentPath
                )
            )
        } catch {
            if let documentID = activeWorkspaceDocument?.id,
               let index = workspaceDocuments.firstIndex(where: { $0.id == documentID }) {
                workspaceDocuments[index].errorMessage = error.localizedDescription
            } else {
                saveState = .failed(error.localizedDescription)
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
        do {
            try recordWorkspaceRevision(
                kind: .restoration,
                documentPath: DevotionalAgentRevisionStore.primaryDocumentPath,
                before: content,
                after: markdown
            )
            try WorkspaceTextFileStore.write(
                markdown,
                to: workspaceURL.appendingPathComponent(
                    DevotionalAgentRevisionStore.primaryDocumentPath
                ),
                in: workspaceURL
            )
            try DevotionalAgentRevisionStore.markSynced(markdown, in: workspaceURL)
            content = markdown
            previewContent = markdown
            save()
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    private func supportsRevisionHistory(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }

    private func recordWorkspaceRevision(
        kind: DevotionalAgentRevisionKind,
        documentPath: String,
        before: String,
        after: String
    ) throws {
        _ = try DevotionalAgentRevisionStore.record(
            kind: kind,
            documentPath: documentPath,
            before: before,
            after: after,
            in: workspaceURL
        )
    }

    private func recordExternalRevisionError(
        for document: DevotionalWorkspaceEditorDocument,
        after externalText: String
    ) -> String? {
        guard supportsRevisionHistory(document.url) else { return nil }
        do {
            try recordWorkspaceRevision(
                kind: .agentEdit,
                documentPath: document.id,
                before: document.persistedText,
                after: externalText
            )
            return nil
        } catch {
            return "Revision history could not be updated: \(error.localizedDescription)"
        }
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

            try WorkspaceTextFileStore.write(
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
            do {
                if let diskText {
                    if diskText != persistedText {
                        try recordWorkspaceRevision(
                            kind: .agentEdit,
                            documentPath: documentID,
                            before: persistedText,
                            after: diskText
                        )
                    }
                    if submittedText != diskText {
                        try recordWorkspaceRevision(
                            kind: changeKind,
                            documentPath: documentID,
                            before: diskText,
                            after: submittedText
                        )
                    }
                } else {
                    if !persistedText.isEmpty {
                        try recordWorkspaceRevision(
                            kind: .agentEdit,
                            documentPath: documentID,
                            before: persistedText,
                            after: ""
                        )
                    }
                    if !submittedText.isEmpty {
                        try recordWorkspaceRevision(
                            kind: changeKind,
                            documentPath: documentID,
                            before: "",
                            after: submittedText
                        )
                    }
                }
            } catch {
                workspaceDocuments[savedIndex].errorMessage =
                    "Saved, but revision history could not be updated: \(error.localizedDescription)"
            }
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
                try? recordWorkspaceRevision(
                    kind: .agentEdit,
                    documentPath: documentID,
                    before: document.text,
                    after: ""
                )
            }
            workspaceDocuments.remove(at: index)
            if selectedWorkspaceDocumentID == documentID {
                selectedWorkspaceDocumentID = nil
            }
            return
        }
        guard let externalText = workspaceDocuments[index].externalText else { return }
        let localText = workspaceDocuments[index].text
        var revisionError: String?
        if supportsRevisionHistory(workspaceDocuments[index].url) {
            do {
                try recordWorkspaceRevision(
                    kind: .agentEdit,
                    documentPath: documentID,
                    before: localText,
                    after: externalText
                )
            } catch {
                revisionError = "Revision history could not be updated: \(error.localizedDescription)"
            }
        }
        workspaceDocuments[index].text = externalText
        workspaceDocuments[index].persistedText = externalText
        workspaceDocuments[index].externalText = nil
        workspaceDocuments[index].errorMessage = revisionError
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

    private func refreshWorkspaceDocuments() {
        do {
            workspaceIsAvailable = FileManager.default.fileExists(atPath: workspaceURL.path)
            let snapshots = try WorkspaceTextFileStore.snapshots(
                in: workspaceURL,
                excludingFilenames: [
                    DevotionalAgentWorkspaceFiles.draftFilename,
                    DevotionalAgentWorkspaceFiles.contextFilename,
                    "AGENTS.md",
                    "CLAUDE.md",
                ]
            )
            let snapshotIDs = Set(snapshots.map(\.id))

            for snapshot in snapshots {
                if let index = workspaceDocuments.firstIndex(where: { $0.id == snapshot.id }) {
                    let document = workspaceDocuments[index]
                    if snapshot.contents == document.persistedText {
                        workspaceDocuments[index].wasRemovedExternally = false
                    } else if snapshot.contents == document.text {
                        let revisionError = recordExternalRevisionError(
                            for: document,
                            after: snapshot.contents
                        )
                        workspaceDocuments[index].persistedText = snapshot.contents
                        workspaceDocuments[index].externalText = nil
                        workspaceDocuments[index].wasRemovedExternally = false
                        workspaceDocuments[index].errorMessage = revisionError
                    } else if document.isDirty {
                        workspaceDocuments[index].externalText = snapshot.contents
                        workspaceDocuments[index].wasRemovedExternally = false
                        workspaceDocuments[index].errorMessage = nil
                    } else {
                        let revisionError = recordExternalRevisionError(
                            for: document,
                            after: snapshot.contents
                        )
                        workspaceDocuments[index].text = snapshot.contents
                        workspaceDocuments[index].persistedText = snapshot.contents
                        workspaceDocuments[index].externalText = nil
                        workspaceDocuments[index].wasRemovedExternally = false
                        workspaceDocuments[index].errorMessage = revisionError
                        let textLength = (snapshot.contents as NSString).length
                        let caret = min(workspaceDocuments[index].selection.location, textLength)
                        workspaceDocuments[index].selection = NSRange(location: caret, length: 0)
                    }
                } else {
                    var document = DevotionalWorkspaceEditorDocument(
                        url: snapshot.url,
                        text: snapshot.contents,
                        persistedText: snapshot.contents
                    )
                    if workspaceDocumentsInitialized, supportsRevisionHistory(snapshot.url) {
                        do {
                            try recordWorkspaceRevision(
                                kind: .agentEdit,
                                documentPath: snapshot.id,
                                before: "",
                                after: snapshot.contents
                            )
                        } catch {
                            document.errorMessage =
                                "Revision history could not be updated: \(error.localizedDescription)"
                        }
                    }
                    workspaceDocuments.append(document)
                }
            }

            for index in workspaceDocuments.indices where
                !snapshotIDs.contains(workspaceDocuments[index].id) {
                workspaceDocuments[index].wasRemovedExternally = true
                workspaceDocuments[index].externalText = nil
                workspaceDocuments[index].errorMessage = nil
            }
            workspaceDocuments.sort {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            workspaceDocumentsInitialized = true
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
        category = devotional.category == "sermon"
            ? "exhortation"
            : devotional.category ?? "devotional"
        seriesName = devotional.seriesName ?? ""
        seriesOrder = devotional.seriesOrder ?? 0
        summary = devotional.summary ?? ""
        content = devotional.displayMarkdown
        originalContentJSON = devotional.contentJSON
        originalPlainContent = devotional.content
        originalProjectedMarkdown = devotional.displayMarkdown
        mediaJSON = devotional.mediaJSON
        previewContent = devotional.displayMarkdown
        footnotes = devotional.footnotes ?? ""
        keyScriptures = devotional.keyScriptures
        saveState = .idle
        savedFields = editedFields
        hasLoaded = true
    }

    private func save() {
        guard hasSavableContent, saveState != .saving else { return }
        let submitted = editedFields
        let previouslySavedContent = savedFields.indices.contains(9) ? savedFields[9] : ""
        let bodyChanged = content != originalProjectedMarkdown
        let contentJSON: String?
        let plainContent: String
        if bodyChanged, let originalContentJSON,
           LampPortableDevotionalMedia.plainMarkdown(from: originalContentJSON) == nil {
            do {
                contentJSON = try LampPortableDevotionalContent.replacingMarkdown(
                    content, in: originalContentJSON
                )
                plainContent = contentJSON.flatMap(LampPortableDevotionalContent.plainText) ?? ""
            } catch {
                saveState = .failed(error.localizedDescription)
                return
            }
        } else if bodyChanged {
            contentJSON = nil
            plainContent = content
        } else {
            contentJSON = originalContentJSON
            plainContent = originalContentJSON == nil ? content : originalPlainContent
        }
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
            category: category,
            seriesName: seriesName,
            seriesOrder: seriesName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : seriesOrder,
            keyScriptures: keyScriptures,
            summary: summary,
            content: plainContent,
            contentJSON: contentJSON,
            footnotes: footnotes,
            mediaJSON: mediaJSON,
            created: createdDate ?? Date(),
            lastModified: Date(),
            isEditable: true
        )
        saveState = .saving
        Task {
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
                recordPrimaryUserRevisionIfNeeded(
                    before: previouslySavedContent,
                    after: submitted[9]
                )
            } catch {
                saveState = .failed(error.localizedDescription)
            }
        }
    }

    private func recordPrimaryUserRevisionIfNeeded(before: String, after: String) {
        guard before != after else { return }
        do {
            let latest = try DevotionalAgentRevisionStore.revisions(
                in: workspaceURL,
                documentPath: DevotionalAgentRevisionStore.primaryDocumentPath
            ).first
            // Agent imports and explicit restores already wrote their transition.
            guard latest?.afterMarkdown != after else { return }
            let revisionBefore: String
            if let latest, latest.beforeMarkdown == before, latest.afterMarkdown != before {
                // The user continued typing after an agent change arrived. Keep
                // the agent result as the immediate base for the saved edit.
                revisionBefore = latest.afterMarkdown
            } else {
                revisionBefore = before
            }
            try recordWorkspaceRevision(
                kind: .userEdit,
                documentPath: DevotionalAgentRevisionStore.primaryDocumentPath,
                before: revisionBefore,
                after: after
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
        while !Task.isCancelled {
            if let decks = try? LinkedPresentationDeckLookup.decks(
                rootURL: model.library.rootURL,
                devotionalID: identifier
            ), decks != linkedPresentationDecks {
                linkedPresentationDecks = decks
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private static var today: String {
        LampCalendarDate.today()
    }

    private static let categories = [
        "devotional", "exhortation", "reflection", "study", "prayer", "testimony", "other",
    ]

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
