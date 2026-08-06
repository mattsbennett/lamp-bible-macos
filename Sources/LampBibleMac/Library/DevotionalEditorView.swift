import AppKit
import LampCore
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

private enum DevotionalEditorMode: String, CaseIterable, Identifiable {
    case visual
    case markdown
    case preview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .visual: "Visual"
        case .markdown: "Markdown"
        case .preview: "Preview"
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

    @EnvironmentObject private var model: LibraryModel
    @AppStorage("devotional.editor.fontSize") private var editorFontSize = 15.0
    @AppStorage("devotional.editor.showsDetails") private var showsDetails = true
    @AppStorage("devotional.editor.detailsWidth") private var detailsWidth = 320.0
    @AppStorage("devotional.editor.agentWidth") private var agentWidth = 480.0
    @AppStorage("devotional.fontSize") private var previewFontSize = 17.0
    @AppStorage("agent.moduleAccess.enabled") private var agentModuleAccessEnabled = true
    @AppStorage("agent.moduleAccess.scope") private var agentModuleAccessScope = AgentModuleAccessScope.enabledModules.rawValue
    @AppStorage("agent.moduleAccess.personal") private var agentPersonalContentEnabled = false
    @State private var showingAgentWorkspace = false

    /// Visual editing is deliberately the approachable default. Markdown and
    /// Preview remain temporary modes within this editor window.
    @State private var editorMode: DevotionalEditorMode = .visual
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
        ]
    }

    private var isDirty: Bool {
        hasLoaded && editedFields != savedFields
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
                editorPane
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
        .navigationSubtitle(saveStateDescription)
        .toolbar { editorToolbar }
        .task(id: request) {
            editorMode = .visual
            load()
        }
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
        .onChange(of: editorMode) { _, mode in
            if mode == .preview { previewContent = content }
        }
        .sheet(isPresented: $showingAudioRecorder) {
            DevotionalAudioRecorderView(devotionalID: identifier) { storedURL in
                insertStoredAudio(storedURL)
            }
            .environmentObject(model)
        }
    }

    private var editorPane: some View {
        ZStack {
            visualEditorPane
            if editorMode == .markdown {
                markdownEditorPane
            } else if editorMode == .preview {
                previewPane
            }
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
                text: $content,
                selection: $contentSelection,
                fontSize: editorFontSize
            )
        }
    }

    private var previewPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title.isEmpty ? "Untitled Devotional" : title)
                        .font(.largeTitle.bold())
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.title3).foregroundStyle(.secondary)
                    }
                    if !summary.isEmpty {
                        Text(summary).font(.body).foregroundStyle(.secondary)
                    }
                }

                if !keyScriptures.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(keyScriptures) { scripture in
                            Text(scripture.displayDescription)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }

                Divider()

                DevotionalContentView(
                    markdown: previewContent,
                    libraryRootURL: model.library.rootURL,
                    fontSize: previewFontSize
                )

                if !footnotes.isEmpty {
                    Divider()
                    DevotionalContentView(
                        markdown: footnotes,
                        libraryRootURL: model.library.rootURL,
                        fontSize: max(previewFontSize - 1, 12)
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(.background.secondary)
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
            Button(action: save) {
                Image(nsImage: Self.saveIcon)
            }
            .accessibilityLabel("Save")
            .disabled(!hasSavableContent || !isDirty || saveState == .saving)
            .keyboardShortcut("s", modifiers: .command)
            .help(hasSavableContent
                ? "Save this devotional"
                : "Add devotional content before saving")
        }

        ToolbarItem {
            Picker("Editor Mode", selection: editorModeBinding) {
                ForEach(DevotionalEditorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize(horizontal: true, vertical: false)
            .help("Switch between visual editing, Markdown, and preview")
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
                Label("Agent", systemImage: "terminal")
            }
            .help(showingAgentWorkspace ? "Hide agent workspace" : "Show agent workspace")
        }
    }

    private var saveStateDescription: String {
        if case .failed(let message) = saveState { return "Not saved — \(message)" }
        if saveState == .saving { return "Saving…" }
        if isDirty { return hasSavableContent ? "Unsaved changes" : "Add content to save" }
        if saveState == .saved { return "Saved" }
        return request.devotionalID == nil ? "Not saved yet" : "Up to date"
    }

    private var agentContextDocument: String {
        let scriptureList = keyScriptures.isEmpty
            ? "- None selected"
            : keyScriptures.map { "- \($0.displayDescription)" }.joined(separator: "\n")
        let tagList = tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "None" : tags
        return """
        # Devotional brief

        - Title: \(title.isEmpty ? "Untitled Devotional" : title)
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

    private var visualStyleLabel: String {
        tipTapSelection.heading == 0 ? "Body" : "H\(tipTapSelection.heading)"
    }

    private func switchEditorMode(to newMode: DevotionalEditorMode) {
        guard newMode != editorMode else { return }

        if editorMode == .visual, let coordinator = tipTapCoordinator {
            let contentBeforeSwitch = content
            coordinator.getContent { latestMarkdown in
                DispatchQueue.main.async {
                    // Do not overwrite an edit made immediately after switching
                    // into the Markdown surface.
                    if content == contentBeforeSwitch {
                        content = latestMarkdown
                    }
                    if newMode == .preview {
                        previewContent = content == contentBeforeSwitch
                            ? latestMarkdown
                            : content
                    }
                }
            }
            if newMode == .preview { previewContent = content }
            editorMode = newMode
        } else {
            if newMode == .preview { previewContent = content }
            editorMode = newMode
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
        editorControlGroup("Text Size") {
            Button("Smaller", systemImage: "minus") {
                editorFontSize -= 1
            }
            .labelStyle(.iconOnly)
            .disabled(editorFontSize <= 11)
            .help("Decrease editor text size")

            Text("\(editorFontSize.formatted(.number.precision(.fractionLength(0)))) pt")
                .monospacedDigit()
                .frame(minWidth: 36)

            Button("Larger", systemImage: "plus") {
                editorFontSize += 1
            }
            .labelStyle(.iconOnly)
            .disabled(editorFontSize >= 24)
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
        let result = command.apply(to: content, selection: contentSelection)
        content = result.text
        contentSelection = result.selection
    }

    private func insert(_ snippet: String, onOwnLine: Bool = true) {
        let result = MarkdownEditor.insert(
            snippet,
            in: content,
            selection: contentSelection,
            onOwnLine: onOwnLine
        )
        content = result.text
        contentSelection = result.selection
    }

    private func insertScriptureLink() {
        guard let reference = model.selectedVerseReference else { return }
        let description = LampBibleReferenceFormatter.describeRange(from: reference, to: reference)
        let url = "lampbible://read?reference=\(reference)"
        if editorMode == .visual, let coordinator = tipTapCoordinator {
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
                let portableURL = "lamp-media://\(identifier)/\(storedURL.lastPathComponent)"
                if editorMode == .visual, let coordinator = tipTapCoordinator {
                    if isImage {
                        coordinator.insertImage(
                            mediaID: storedURL.lastPathComponent,
                            caption: label,
                            localURL: storedURL
                        )
                    } else {
                        coordinator.insertAudio(
                            mediaID: storedURL.lastPathComponent,
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
        let label = storedURL.deletingPathExtension().lastPathComponent
        if editorMode == .visual, let coordinator = tipTapCoordinator {
            coordinator.insertAudio(
                mediaID: storedURL.lastPathComponent,
                caption: "▶︎ \(label)"
            )
        } else {
            insert("[▶︎ \(label)](lamp-media://\(identifier)/\(storedURL.lastPathComponent))")
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let devotionalID = request.devotionalID,
              let devotional = model.devotionals.first(where: { $0.id == devotionalID }) else {
            date = Self.today
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
        content = devotional.content
        previewContent = devotional.content
        footnotes = devotional.footnotes ?? ""
        keyScriptures = devotional.keyScriptures
        saveState = .idle
        savedFields = editedFields
        hasLoaded = true
    }

    private func save() {
        guard hasSavableContent, saveState != .saving else { return }
        let submitted = editedFields
        let devotional = LampDevotional(
            id: identifier,
            moduleID: "personal-devotionals",
            moduleName: "My Devotionals",
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
            content: content,
            footnotes: footnotes,
            created: createdDate ?? Date(),
            lastModified: Date(),
            isEditable: true
        )
        saveState = .saving
        Task {
            do {
                let saved = try await model.savePersonalDevotional(devotional)
                createdDate = saved.created
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
            } catch {
                saveState = .failed(error.localizedDescription)
            }
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
