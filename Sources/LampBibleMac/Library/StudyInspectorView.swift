import AppKit
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampModuleKit
import SwiftUI
import UniformTypeIdentifiers

struct ReaderReferenceActions {
    let openInCurrent: (Int) -> Void
    let openInNewTab: (Int) -> Void
}

private struct ReaderReferenceActionsKey: EnvironmentKey {
    static let defaultValue = ReaderReferenceActions(
        openInCurrent: { _ in },
        openInNewTab: { _ in }
    )
}

extension EnvironmentValues {
    var readerReferenceActions: ReaderReferenceActions {
        get { self[ReaderReferenceActionsKey.self] }
        set { self[ReaderReferenceActionsKey.self] = newValue }
    }
}

struct StudyInspectorView: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var scrollLink: ReaderScrollLink
    @Binding var isPresented: Bool
    @AppStorage("studyInspector.tab") private var selectedTab = "commentary"
    @State private var dictionaryQuery = ""
    @State private var dictionaryLookup: DictionaryLookup?

    /// The dictionary answers a query, not a verse, so there is nothing for it to
    /// keep in step with the reader.
    private var tabSupportsScrollLink: Bool {
        selectedTab != "dictionary"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Study Tool", selection: $selectedTab) {
                    Text("Commentary").tag("commentary")
                    Text("Verse").tag("verse")
                    Text("Notes").tag("notes")
                    Text("Dictionary").tag("dictionary")
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Button {
                    scrollLink.isLinked.toggle()
                } label: {
                    Label(
                        scrollLink.isLinked ? "Unlink Scrolling" : "Link Scrolling",
                        systemImage: scrollLink.isLinked ? "link.circle.fill" : "link.circle"
                    )
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!tabSupportsScrollLink)
                .help(scrollLinkHelp)
            }
            .padding()

            Divider()

            switch selectedTab {
            case "dictionary":
                DictionaryInspectorView(
                    query: $dictionaryQuery,
                    lookup: $dictionaryLookup
                )
            case "verse":
                VerseInspectorView { key, word in
                    // The dictionary pane seeds the field from the lookup itself;
                    // clearing the query here would read as the user typing.
                    dictionaryLookup = DictionaryLookup(keys: [key], word: word)
                    selectedTab = "dictionary"
                }
            case "notes":
                NotesInspectorView()
            default:
                CommentaryInspectorView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Inspector content can exist while its column is hidden. Leave the
            // request pending until the presented instance can retain the lookup.
            guard isPresented else { return }
            adoptDictionaryLookup(model.dictionaryLookupRequest)
        }
        .onChange(of: model.dictionaryLookupRequest) { _, request in
            guard isPresented else { return }
            adoptDictionaryLookup(request)
        }
        .onChange(of: isPresented) { _, presented in
            guard presented else { return }
            adoptDictionaryLookup(model.dictionaryLookupRequest)
        }
    }

    private var scrollLinkHelp: String {
        guard tabSupportsScrollLink else {
            return "Dictionary lookups don’t follow the reader"
        }
        return scrollLink.isLinked
            ? "Stop this panel following the reader"
            : "Keep this panel on the verse you are reading"
    }

    private func adoptDictionaryLookup(_ request: DictionaryLookupRequest?) {
        guard let request, !request.keys.isEmpty else { return }
        dictionaryLookup = DictionaryLookup(keys: request.keys, word: request.word)
        selectedTab = "dictionary"
        model.consumeDictionaryLookupRequest(request)
    }
}

private extension View {
    /// Pins a study pane's empty or loading state to the top of the column.
    ///
    /// `ContentUnavailableView` and a labelled `ProgressView` both take all the
    /// height offered and centre themselves in it, which in a tall narrow column
    /// leaves the message floating in the middle and moves it every time the
    /// window resizes. Sizing to the content first gives the alignment something
    /// to act on.
    func studyPaneState() -> some View {
        fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// A verse in the current chapter that has something to show in the notes panel.
private struct NoteGroup: Identifiable {
    let id: Int
    let endReference: Int?
    let verse: LampVerse
    let hasPersonalNote: Bool
    let installedNotes: [LampVerseNote]
}

private enum NoteEditorField: Hashable {
    case title
    case footnote(UUID)
}

private struct NotesInspectorView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var isExporting = false
    @State private var exportedURL: URL?
    @State private var transferStatus: String?
    @State private var exportError: String?
    @State private var editorIsDirty = false
    @State private var reloadToken = UUID()
    @State private var highlightVerse: LampVerse?

    /// Every verse in the chapter worth a card: one that already carries a note of
    /// either kind, plus whichever verse is selected — so the panel is a chapter to
    /// scroll through rather than a single form, and there is always somewhere to
    /// start writing.
    private var groups: [NoteGroup] {
        guard let chapter = model.chapter else { return [] }
        return chapter.verses.compactMap { verse in
            let installed = model.installedNotes(for: verse.id)
            let hasPersonal = model.hasPersonalNote(for: verse.id)
            let isSelected = model.selectedVerseReference == verse.id
            guard hasPersonal || !installed.isEmpty || isSelected else { return nil }
            return NoteGroup(
                id: verse.id,
                endReference: installed.flatMap(\.verseReferences).max(),
                verse: verse,
                hasPersonalNote: hasPersonal,
                installedNotes: installed
            )
        }
    }

    var body: some View {
        Group {
            if model.chapter == nil {
                ContentUnavailableView(
                    "No Chapter Selected",
                    systemImage: "note.text",
                    description: Text("Open a Bible chapter to read and write notes on it.")
                )
                .studyPaneState()
            } else {
                let groups = groups
                VStack(spacing: 0) {
                    if groups.isEmpty {
                        ContentUnavailableView(
                            "No Notes in This Chapter",
                            systemImage: "note.text",
                            description: Text("Click a verse number in the reader to add a note or highlight.")
                        )
                        .studyPaneState()
                    } else {
                        VerseAnchoredScrollView(
                            anchors: groups.map { VerseAnchor(reference: $0.id, endReference: $0.endReference) },
                            focusedReference: model.selectedVerseReference
                        ) {
                            ForEach(groups) { group in
                                noteCard(group)
                                    .id(group.id)
                            }
                        }
                    }

                    Divider()
                    footer
                }
            }
        }
        .sheet(item: $highlightVerse) { verse in
            VerseHighlightEditorView(verse: verse)
                .environmentObject(model)
        }
    }

    @ViewBuilder
    private func noteCard(_ group: NoteGroup) -> some View {
        if group.id == model.selectedVerseReference {
            PersonalNoteEditor(
                verse: group.verse,
                installedNotes: group.installedNotes,
                reloadToken: reloadToken,
                isDirty: $editorIsDirty,
                editHighlightSelection: { highlightVerse = group.verse }
            )
        } else {
            Button {
                model.focusVerse(group.id)
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(LampBibleReferenceFormatter.describeRange(
                            from: group.id,
                            to: group.endReference ?? group.id
                        ))
                        .font(.headline)
                        Spacer()
                        if group.hasPersonalNote {
                            Image(systemName: "square.and.pencil")
                                .foregroundStyle(.orange)
                        }
                        if !group.installedNotes.isEmpty {
                            Image(systemName: "books.vertical")
                                .foregroundStyle(.purple)
                        }
                    }
                    if let installed = group.installedNotes.first {
                        Text(installed.content)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    } else if group.hasPersonalNote {
                        Text("Personal note")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .help("Edit the note on this verse")
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if isExporting {
                ProgressView()
                    .controlSize(.small)
            } else if let exportError {
                Label(exportError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let exportedURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
                } label: {
                    Label("Exported", systemImage: "checkmark.circle")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Show \(exportedURL.lastPathComponent) in Finder")
            } else if let transferStatus {
                Label(transferStatus, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Study Data", systemImage: "arrow.up.arrow.down.square") {
                Menu("Notes for \(currentBookName)") {
                    Button("JSON…") { export(.notes, format: .json) }
                    Button("Lamp Module…") { export(.notes, format: .lamp) }
                }
                Menu("Highlights for \(model.selectedTranslation?.abbreviation ?? "Translation")") {
                    Button("JSON…") { export(.highlights, format: .json) }
                    Button("Lamp Module…") { export(.highlights, format: .lamp) }
                }
                Divider()
                Button("Import Study Data…", systemImage: "square.and.arrow.down") {
                    importStudyData()
                }
            }
            .disabled(editorIsDirty || isExporting)
            .help(editorIsDirty
                ? "Save or revert this note before transferring study data"
                : "Import or export personal study data")
            .fixedSize()
        }
        .padding()
    }

    private var currentBookName: String {
        model.chapter?.book.name ?? "Current Book"
    }

    private func export(_ kind: PersonalStudyExportKind, format: PersonalStudyExportFormat) {
        guard let bookNumber = model.chapter?.book.id,
              let translationID = model.selectedTranslationID else { return }
        isExporting = true
        exportError = nil
        exportedURL = nil
        transferStatus = nil
        Task {
            do {
                let document: LampPortableStudyDocument
                switch kind {
                case .notes:
                    document = try await model.library.personalNotesDocument(bookNumber: bookNumber)
                case .highlights:
                    document = try await model.library.personalHighlightsDocument(
                        translationID: translationID
                    )
                }

                let panel = NSSavePanel()
                panel.title = format == .json ? "Export Study Data" : "Export Lamp Module"
                panel.prompt = "Export"
                panel.nameFieldStringValue = format == .json
                    ? document.suggestedJSONFilename
                    : document.suggestedModuleFilename
                panel.allowedContentTypes = format == .json
                    ? [.json]
                    : [UTType(exportedAs: "com.neus.lamp-bible.lamp", conformingTo: .data)]
                panel.canCreateDirectories = true

                guard panel.runModal() == .OK, let destinationURL = panel.url else {
                    isExporting = false
                    return
                }
                try await Task.detached(priority: .userInitiated) {
                    switch format {
                    case .json:
                        let hasSecurityScope = destinationURL.startAccessingSecurityScopedResource()
                        defer {
                            if hasSecurityScope { destinationURL.stopAccessingSecurityScopedResource() }
                        }
                        try document.jsonData.write(to: destinationURL, options: .atomic)
                    case .lamp:
                        _ = try LampModuleCompiler().compile(
                            data: document.jsonData,
                            sourceFilename: document.suggestedJSONFilename,
                            destinationURL: destinationURL
                        )
                    }
                }.value
                exportedURL = destinationURL
            } catch {
                exportError = error.localizedDescription
            }
            isExporting = false
        }
    }

    private func importStudyData() {
        let panel = NSOpenPanel()
        panel.title = "Import Personal Study Data"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.json, .data]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let sourceURLs = panel.urls
        isExporting = true
        exportError = nil
        exportedURL = nil
        transferStatus = nil
        Task {
            do {
                var importedCount = 0
                var skippedCount = 0
                for sourceURL in sourceURLs {
                    let result = try await model.library.importPersonalStudyData(from: sourceURL)
                    importedCount += result.importedCount
                    skippedCount += result.skippedCount
                }
                model.reloadCurrentChapterStudyData()
                // The open editor is keyed on this, so it picks up whatever the
                // import wrote over the note it is showing.
                reloadToken = UUID()
                transferStatus = skippedCount == 0
                    ? "Imported \(importedCount)"
                    : "Imported \(importedCount), kept \(skippedCount) existing"
            } catch {
                exportError = error.localizedDescription
            }
            isExporting = false
        }
    }
}

private struct PersonalNoteEditor: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var scrollLink: ReaderScrollLink
    let verse: LampVerse
    let installedNotes: [LampVerseNote]
    let reloadToken: UUID
    @Binding var isDirty: Bool
    let editHighlightSelection: () -> Void

    @State private var title = ""
    @State private var content = ""
    @State private var savedTitle = ""
    @State private var savedContent = ""
    @State private var rangeEndVerse = 0
    @State private var savedRangeEndVerse = 0
    @State private var personalFootnotes: [NoteFootnoteDraft] = []
    @State private var savedFootnotes: [NoteFootnoteDraft] = []
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var editorCoordinator: TipTapEditorCoordinator?
    @State private var editorSelection = TipTapSelectionState()
    @State private var editorIsReady = false
    @State private var editorIsFocused = false
    @State private var editorHeight = NoteEditorMetrics.minimumHeight
    @FocusState private var focusedField: NoteEditorField?

    private var reference: Int { verse.id }
    private var hasUnsavedEdits: Bool {
        title != savedTitle
            || content != savedContent
            || rangeEndVerse != savedRangeEndVerse
            || personalFootnotes != savedFootnotes
    }
    private var selectedHighlightColor: String? {
        model.personalHighlights(for: reference).first?.color
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(LampBibleReferenceFormatter.describeRange(from: reference, to: reference))
                    .font(.headline)
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Highlight", systemImage: "highlighter")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 10) {
                    ForEach(StudyHighlightPalette.colors) { item in
                        Button {
                            setHighlight(item.hex)
                        } label: {
                            Circle()
                                .fill(item.color.opacity(0.78))
                                .frame(width: 24, height: 24)
                                .overlay {
                                    if selectedHighlightColor == item.hex {
                                        Circle()
                                            .stroke(.primary, lineWidth: 2)
                                            .padding(2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help(item.name)
                        .accessibilityLabel("\(item.name) highlight")
                    }
                    if selectedHighlightColor != nil {
                        Button("Remove Highlight", systemImage: "xmark.circle") {
                            setHighlight(nil)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .help("Remove highlight")
                    }
                }
                Button("Highlight Part of Verse…", systemImage: "selection.pin.in.out") {
                    editHighlightSelection()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Label("Personal Note", systemImage: "note.text")
                    .font(.subheadline.weight(.semibold))
                TextField("Title (optional)", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .title)
                noteEditor
            }

            if let chapter = model.chapter {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Verse Range", systemImage: "arrow.left.and.right.text.vertical")
                        .font(.subheadline.weight(.semibold))
                    Picker("Applies through", selection: $rangeEndVerse) {
                        ForEach(chapter.verses.filter { $0.number >= verse.number }) { candidate in
                            Text(candidate.number == verse.number
                                ? "Verse \(candidate.number) only"
                                : "Verses \(verse.number)–\(candidate.number)")
                                .tag(candidate.number)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Footnotes", systemImage: "text.append")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Add Footnote", systemImage: "plus") {
                        personalFootnotes.append(NoteFootnoteDraft(
                            id: nextFootnoteID,
                            kind: "study",
                            content: ""
                        ))
                    }
                }
                ForEach($personalFootnotes) { $footnote in
                    HStack(alignment: .top, spacing: 8) {
                        TextField("ID", text: $footnote.id)
                            .frame(width: 52)
                        TextField("Footnote", text: $footnote.content, axis: .vertical)
                            .lineLimit(2...5)
                            .focused($focusedField, equals: .footnote(footnote.uuid))
                        Button("Remove", systemImage: "minus.circle", role: .destructive) {
                            personalFootnotes.removeAll { $0.uuid == footnote.uuid }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
            }

            if !installedNotes.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Label("Installed Notes", systemImage: "books.vertical")
                        .font(.subheadline.weight(.semibold))
                    ForEach(installedNotes) { note in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(moduleName(for: note.moduleID))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            if let title = note.title {
                                Text(title)
                                    .font(.headline)
                            }
                            Text(note.content)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                if !hasUnsavedEdits && (!savedTitle.isEmpty || !savedContent.isEmpty) {
                    Label("Saved", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert") {
                    title = savedTitle
                    content = savedContent
                    rangeEndVerse = savedRangeEndVerse
                    personalFootnotes = savedFootnotes
                    errorMessage = nil
                }
                .disabled(!hasUnsavedEdits || isSaving)
                Button(isSaving ? "Saving…" : "Save") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!hasUnsavedEdits || isSaving || isLoading)
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9))
        .task(id: NoteEditorLoad(reference: reference, token: reloadToken)) {
            await load()
        }
        .onChange(of: hasUnsavedEdits, initial: true) { _, dirty in
            isDirty = dirty
        }
        // Typing reflows this card, and a reflow is indistinguishable from a scroll
        // to the link — without pausing it the reader would drift off the verse
        // being written about. The web editor is opaque to `@FocusState`, so it
        // reports its own caret focus.
        .onChange(of: focusedField) { _, field in
            scrollLink.isSuspended = field != nil || editorIsFocused
        }
        .onChange(of: editorIsFocused) { _, focused in
            scrollLink.isSuspended = focused || focusedField != nil
        }
        .onDisappear {
            scrollLink.isSuspended = false
            isDirty = false
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let note = try await model.personalNote(for: reference)
            guard !Task.isCancelled, model.selectedVerseReference == reference else { return }
            title = note?.title ?? ""
            content = note?.content ?? ""
            rangeEndVerse = note?.verseReferences
                .map { LampBibleReferenceFormatter.components(of: $0).verse }
                .max() ?? verse.number
            personalFootnotes = note?.footnotes.map(NoteFootnoteDraft.init) ?? []
            savedTitle = title
            savedContent = content
            savedRangeEndVerse = rangeEndVerse
            savedFootnotes = personalFootnotes
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// TipTap reports edits on a debounce, so ⌘S struck straight after a keystroke
    /// would otherwise persist the note as it stood a moment earlier.
    private func save() {
        guard let editorCoordinator else {
            submit(content: content)
            return
        }
        isSaving = true
        editorCoordinator.getContent { latest in
            content = latest
            submit(content: latest)
        }
    }

    private func submit(content submittedContent: String) {
        let submittedTitle = title
        let submittedRangeEndVerse = rangeEndVerse
        let submittedFootnotes = personalFootnotes.compactMap(\.lampFootnote)
        let submittedReferences = model.chapter?.verses
            .filter { $0.id >= reference && $0.number <= submittedRangeEndVerse }
            .map(\.id) ?? [reference]
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await model.savePersonalNote(
                    reference: reference,
                    title: submittedTitle,
                    content: submittedContent,
                    verseReferences: submittedReferences,
                    footnotes: submittedFootnotes
                )
                if model.selectedVerseReference == reference {
                    savedTitle = submittedTitle
                    savedContent = submittedContent
                    savedRangeEndVerse = submittedRangeEndVerse
                    personalFootnotes = submittedFootnotes.map(NoteFootnoteDraft.init)
                    savedFootnotes = personalFootnotes
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func setHighlight(_ color: String?) {
        Task {
            do {
                try await model.setWholeVerseHighlight(
                    reference: reference,
                    textLength: verse.text.count,
                    color: color
                )
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var nextFootnoteID: String {
        var candidate = personalFootnotes.count + 1
        while personalFootnotes.contains(where: { $0.id == String(candidate) }) { candidate += 1 }
        return String(candidate)
    }

    /// The same visual editor the devotional editor uses, in its compact layout so
    /// it grows with the note instead of scrolling inside the notes column.
    private var noteEditor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                noteFormatButton("Bold", systemImage: "bold", isActive: editorSelection.bold) {
                    editorCoordinator?.applyStyle(.bold)
                }
                noteFormatButton("Italic", systemImage: "italic", isActive: editorSelection.italic) {
                    editorCoordinator?.applyStyle(.italic)
                }
                noteFormatButton(
                    "Bulleted List",
                    systemImage: "list.bullet",
                    isActive: editorSelection.bulletList
                ) {
                    editorCoordinator?.applyStyle(.bullet)
                }
                noteFormatButton(
                    "Numbered List",
                    systemImage: "list.number",
                    isActive: editorSelection.orderedList
                ) {
                    editorCoordinator?.applyStyle(.numberedList)
                }
                noteFormatButton("Quote", systemImage: "text.quote", isActive: editorSelection.blockquote) {
                    editorCoordinator?.applyStyle(.quote)
                }
                if editorSelection.link {
                    noteFormatButton("Remove Link", systemImage: "link", isActive: true) {
                        editorCoordinator?.removeLink()
                    }
                }
                Spacer()
            }
            .disabled(!editorIsReady)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(.background.tertiary)

            Divider()

            TipTapEditorView(
                markdownContent: $content,
                fontSize: NoteEditorMetrics.fontSize,
                // Notes carry no media of their own, so this scope resolves to no
                // media folder and relative links stay note-local.
                mediaScopeID: "note-\(reference)",
                libraryRootURL: model.library.rootURL,
                isVisible: true,
                compactLayout: true,
                onCoordinatorReady: { coordinator in
                    editorCoordinator = coordinator
                    editorIsReady = true
                    coordinator.onSelectionChanged = { selection in
                        DispatchQueue.main.async { editorSelection = selection }
                    }
                    coordinator.onContentHeightChanged = { height in
                        DispatchQueue.main.async {
                            editorHeight = NoteEditorMetrics.clamped(height)
                        }
                    }
                    coordinator.onFocusChanged = { focused in
                        DispatchQueue.main.async { editorIsFocused = focused }
                    }
                }
            )
            .frame(height: editorHeight)
        }
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(.separator.opacity(0.7))
        }
        .onDisappear {
            editorIsReady = false
            editorIsFocused = false
            editorSelection = TipTapSelectionState()
        }
    }

    private func noteFormatButton(
        _ title: String,
        systemImage: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(4)
            .background(
                isActive ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .help(title)
    }

    private func moduleName(for moduleID: String) -> String {
        model.noteModules.first { $0.id == moduleID }?.name ?? moduleID
    }
}

private struct NoteEditorLoad: Hashable {
    let reference: Int
    let token: UUID
}

/// The visual note editor grows with its content, within bounds: tall enough to
/// invite writing when empty, and capped so a long note still leaves the rest of
/// the card reachable — past the cap the editor scrolls itself.
private enum NoteEditorMetrics {
    static let fontSize = 14.0
    static let minimumHeight: CGFloat = 150
    static let maximumHeight: CGFloat = 520

    static func clamped(_ height: Double) -> CGFloat {
        min(max(CGFloat(height), minimumHeight), maximumHeight)
    }
}

private struct NoteFootnoteDraft: Identifiable, Equatable {
    let uuid: UUID
    var id: String
    var kind: String
    var content: String

    init(uuid: UUID = UUID(), id: String, kind: String = "study", content: String) {
        self.uuid = uuid
        self.id = id
        self.kind = kind
        self.content = content
    }

    init(_ footnote: LampVerseFootnote) {
        self.init(id: footnote.id, kind: footnote.kind ?? "study", content: footnote.content)
    }

    var lampFootnote: LampVerseFootnote? {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !trimmedContent.isEmpty else { return nil }
        return LampVerseFootnote(id: trimmedID, kind: kind, content: content)
    }
}

private enum PersonalStudyExportKind: Sendable {
    case notes
    case highlights
}

private enum PersonalStudyExportFormat: Sendable {
    case json
    case lamp
}

/// What the dictionary pane is currently answering.
///
/// A lookup arrives from clicking a word in the reader and is answered by key; a
/// search is typed and is answered by matching text. Keeping them apart is the
/// whole point — `searchDictionaries` matches the query against definition bodies
/// too, and Strong's dictionaries cite each other constantly, so searching for
/// `H7225` returns every entry that merely *mentions* it.
private struct DictionaryLookup: Equatable {
    let keys: [String]
    let word: String?
}

private struct DictionarySearchRequest: Hashable {
    let query: String
    let moduleIDs: Set<String>
}

private struct DictionaryLookupRequestKey: Hashable {
    let keys: [String]
    let moduleIDs: Set<String>
}

/// One source lexicon key and its exact entries, including entries reached
/// through a bundled lexicon mapping such as Strong's Hebrew to BDB.
private struct DictionaryKeySection: Identifiable {
    let id: String
    let entries: [LampDictionaryResult]
    /// Entries that only mention the key in their definition text. Kept, but folded
    /// away, so a dictionary that spells its keys differently still shows something.
    let mentions: [LampDictionaryResult]
}

private struct DictionaryInspectorView: View {
    @EnvironmentObject private var model: LibraryModel
    @Binding var query: String
    @Binding var lookup: DictionaryLookup?
    @AppStorage("commentary.fontSize") private var fontSize = LampTextScale.commentaryText.defaultValue
    @AppStorage("commentary.lineSpacing") private var lineSpacing = LampTextScale.commentaryLineSpacing.defaultValue
    @AppStorage("commentary.typeface") private var typeface = ProseTypeface.commentaryDefault
    @AppStorage("studyInspector.greekDictionaryModuleID") private var preferredGreekModuleID = ""
    @AppStorage("studyInspector.hebrewDictionaryModuleID") private var preferredHebrewModuleID = ""
    @State private var moduleID: String?
    @State private var results: [LampDictionaryResult] = []
    @State private var sections: [DictionaryKeySection] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    /// The key text this view put in the field on the user's behalf. Typing is
    /// meant to abandon the lookup, and seeding the field is not typing.
    @State private var seededQuery: String?

    private var searchRequest: DictionarySearchRequest {
        DictionarySearchRequest(query: query, moduleIDs: activeDictionaryIDs(for: [query]))
    }

    private var lookupRequest: DictionaryLookupRequestKey? {
        lookup.map {
            DictionaryLookupRequestKey(
                keys: $0.keys,
                moduleIDs: activeDictionaryIDs(for: $0.keys)
            )
        }
    }

    private var overrideModuleID: String? {
        model.dictionaries.contains(where: { $0.id == moduleID })
            ? moduleID
            : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                TextField("Word, lemma, or Strong’s number", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        // Submitting the seeded key means "search this text", so the
                        // lookup has to go; otherwise there is nothing to submit.
                        clearLookup(keepingQuery: true)
                    }

                HStack(spacing: 8) {
                    if model.dictionaries.count > 1 {
                        Picker("Dictionary", selection: Binding(
                            get: { overrideModuleID },
                            set: { moduleID = $0 }
                        )) {
                            Text("Default Dictionaries").tag(String?.none)
                            ForEach(model.dictionaries) { dictionary in
                                Text(dictionary.name).tag(Optional(dictionary.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        // A menu picker sizes to its widest title and ignores a
                        // wider frame. Keep its leading edge aligned with search.
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer(minLength: 0)
                    }

                    TextSizeMenu(
                        fontSize: $fontSize,
                        lineSpacing: $lineSpacing,
                        typeface: $typeface,
                        defaultTypeface: .commentaryDefault,
                        fontScale: .commentaryText,
                        lineSpacingScale: .commentaryLineSpacing,
                        help: "Choose the shared dictionary and commentary text appearance"
                    )
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .labelStyle(.iconOnly)
                    .frame(width: 24)
                }
            }
            .padding()

            Divider()

            if let lookup {
                lookupHeader(lookup)
                Divider()
            }

            content
        }
        .onChange(of: query) { _, newValue in
            // Typing is a search, and a search replaces whatever word was looked up.
            // The key this view seeded into the field is not typing.
            guard newValue != seededQuery else { return }
            clearLookup(keepingQuery: true)
        }
        .task(id: lookupRequest) {
            await loadLookup()
        }
        .task(id: searchRequest) {
            await loadSearch()
        }
    }

    /// The word under study, given room of its own between the controls and the
    /// entries so it reads as the subject of the pane rather than another field.
    private func lookupHeader(_ lookup: DictionaryLookup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let word = lookup.word {
                    Text(word)
                        .font(.system(
                            size: dictionaryFontSize + 5,
                            weight: .semibold,
                            design: typeface.design
                        ))
                        .textSelection(.enabled)
                    Text(lookup.keys.joined(separator: " · "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    Text(lookup.keys.joined(separator: " · "))
                        .font(.title3.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)

            Button("Clear", systemImage: "xmark.circle.fill") {
                clearLookup(keepingQuery: false)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Stop showing this word and search instead")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35))
    }

    @ViewBuilder
    private var content: some View {
        if model.dictionaries.isEmpty {
            ContentUnavailableView(
                "No Dictionary Installed",
                systemImage: "character.book.closed",
                description: Text("Install a dictionary .lamp module from the Modules section.")
            )
            .studyPaneState()
        } else if let errorMessage {
            ContentUnavailableView(
                "Lookup Failed",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
            .studyPaneState()
        } else if lookup != nil {
            if isSearching && sections.isEmpty {
                ProgressView("Looking Up…")
                    .studyPaneState()
            } else if sections.allSatisfy({ $0.entries.isEmpty && $0.mentions.isEmpty }) {
                ContentUnavailableView(
                    "Not in Any Dictionary",
                    systemImage: "character.book.closed",
                    description: Text("No installed dictionary has an entry for \(lookupKeyList).")
                )
                .studyPaneState()
            } else {
                List {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.entries) { result in
                                dictionaryResult(result, isExpanded: true)
                            }
                            if !section.mentions.isEmpty {
                                DisclosureGroup(
                                    section.entries.isEmpty
                                        ? "No exact entry — \(referencingEntriesLabel(section.mentions.count))"
                                        : referencingEntriesLabel(section.mentions.count)
                                ) {
                                    ForEach(section.mentions) { result in
                                        dictionaryResult(result)
                                    }
                                }
                                .font(.caption)
                            }
                        } header: {
                            Text(section.id)
                                .font(.caption.monospaced().weight(.semibold))
                        }
                    }
                }
                .listStyle(.inset)
            }
        } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "Dictionary Lookup",
                systemImage: "character.book.closed",
                description: Text("Click a linked word in the reader, or search by English word, lemma, transliteration, or key such as G3056.")
            )
            .studyPaneState()
        } else if isSearching && results.isEmpty {
            ProgressView("Searching…")
                .studyPaneState()
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
                .studyPaneState()
        } else {
            List(results) { result in
                dictionaryResult(result)
            }
            .listStyle(.inset)
        }
    }

    private var dictionaryFontSize: Double {
        LampTextScale.commentaryText.clamped(fontSize)
    }

    private var dictionaryLineSpacing: Double {
        LampTextScale.commentaryLineSpacing.clamped(lineSpacing)
    }

    private func dictionaryResult(
        _ result: LampDictionaryResult,
        isExpanded: Bool = false
    ) -> some View {
        DictionaryResultView(
            result: result,
            isExpanded: isExpanded,
            fontSize: dictionaryFontSize,
            lineSpacing: dictionaryLineSpacing,
            typeface: typeface
        )
    }

    private var lookupKeyList: String {
        lookup?.keys.joined(separator: ", ") ?? ""
    }

    private func referencingEntriesLabel(_ count: Int) -> String {
        count == 1 ? "Referenced by 1 other entry" : "Referenced by \(count) other entries"
    }

    private func activeDictionaryIDs(for terms: [String]) -> Set<String> {
        if let overrideModuleID { return [overrideModuleID] }

        let languages = Set(terms.compactMap(BiblicalOriginalLanguage.inferred(from:)))
        let requestedLanguages = languages.isEmpty
            ? Set(BiblicalOriginalLanguage.allCases)
            : languages
        let defaults = requestedLanguages.compactMap(defaultDictionaryID(for:))
        return defaults.isEmpty ? Set(model.dictionaries.map(\.id)) : Set(defaults)
    }

    private func defaultDictionaryID(for language: BiblicalOriginalLanguage) -> String? {
        let compatibleModules = model.dictionaries.filter {
            $0.biblicalOriginalLanguage == language
        }
        let preferredID = switch language {
        case .greek: preferredGreekModuleID
        case .hebrew: preferredHebrewModuleID
        }
        return compatibleModules.contains(where: { $0.id == preferredID })
            ? preferredID
            : compatibleModules.first?.id
    }

    /// Drops the lookup without letting `onChange(of: query)` mistake the seeded
    /// key for something the user typed.
    private func clearLookup(keepingQuery: Bool) {
        seededQuery = nil
        if !keepingQuery { query = "" }
        lookup = nil
    }

    private func loadLookup() async {
        guard let lookup else {
            sections = []
            return
        }
        // Show the keys being looked up in the field, so the pane says what it is
        // showing and the user can edit that text into a search.
        let seed = lookup.keys.joined(separator: " ")
        seededQuery = seed
        if query != seed { query = seed }
        isSearching = true
        errorMessage = nil
        var loaded: [DictionaryKeySection] = []
        do {
            for key in lookup.keys {
                try Task.checkCancellation()
                let dictionaryIDs = activeDictionaryIDs(for: [key])
                let mappedKeys = try await model.library.lexiconMappings(sourceKey: key)
                let normalizedSourceKey = StrongsKey.normalized(key)
                let exactKeys = [key, normalizedSourceKey] + mappedKeys
                let exactKeySet = Set(exactKeys.map { $0.uppercased() })
                let exactEntries = try await model.library.dictionaryEntries(
                    keys: exactKeys,
                    moduleIDs: dictionaryIDs
                )
                let matches = try await model.library.searchDictionaries(
                    query: key,
                    moduleIDs: dictionaryIDs,
                    limit: 60
                )
                var seenEntryIDs = Set<String>()
                let entries = (exactEntries + matches.filter { StrongsKey.matches($0.key, key) })
                    .filter { seenEntryIDs.insert($0.id).inserted }
                loaded.append(DictionaryKeySection(
                    id: key,
                    entries: entries,
                    mentions: matches.filter {
                        !exactKeySet.contains($0.key.uppercased())
                            && !seenEntryIDs.contains($0.id)
                    }
                ))
            }
            sections = loaded
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            sections = []
        }
        isSearching = false
    }

    private func loadSearch() async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // A lookup owns the field's text; leave its in-flight progress alone.
        guard lookup == nil else {
            results = []
            return
        }
        guard !trimmedQuery.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        errorMessage = nil
        do {
            try await Task.sleep(for: .milliseconds(200))
            results = try await model.library.searchDictionaries(
                query: trimmedQuery,
                moduleIDs: activeDictionaryIDs(for: [trimmedQuery]),
                limit: 100
            )
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            results = []
        }
        isSearching = false
    }
}

private struct VerseStudyRequest: Hashable {
    let translationID: String?
    let bookNumber: Int?
    let chapterNumber: Int?
}

/// A verse's footnotes, original-language words and cross-references, kept together
/// because they are all anchored to the same verse and scroll as one block.
private struct VerseStudyGroup: Identifiable {
    let id: Int
    let title: String
    let footnotes: [LampVerseFootnote]
    let lexical: [LampVerseAnnotation]
    let scripture: [LampVerseAnnotation]

    var isEmpty: Bool {
        footnotes.isEmpty && lexical.isEmpty && scripture.isEmpty
    }
}

private struct VerseInspectorView: View {
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("reader.showStrongsHints") private var showStrongsHints = true
    @AppStorage("reader.crossReferences.canonicalOrder") private var canonicalCrossReferenceOrder = false
    @State private var footnotesByReference: [Int: [LampVerseFootnote]] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    let openDictionary: (String, String?) -> Void

    private var request: VerseStudyRequest {
        VerseStudyRequest(
            translationID: model.selectedTranslationID,
            bookNumber: model.chapter?.book.id,
            chapterNumber: model.chapter?.number
        )
    }

    /// Built from the chapter already in memory — lexical annotations and
    /// cross-references ride along on every verse — so only footnote bodies need
    /// fetching, and only for the verses that advertise having any.
    private var groups: [VerseStudyGroup] {
        guard let chapter = model.chapter else { return [] }
        return chapter.verses.compactMap { verse in
            let group = VerseStudyGroup(
                id: verse.id,
                title: "\(chapter.book.name) \(chapter.number):\(verse.number)",
                footnotes: footnotesByReference[verse.id] ?? [],
                lexical: verse.annotations.filter {
                    $0.strongs != nil || $0.lemma != nil || $0.morphology != nil
                },
                scripture: sortedScriptureAnnotations(
                    verse.annotations.filter { $0.startReference != nil }
                )
            )
            return group.isEmpty ? nil : group
        }
    }

    var body: some View {
        Group {
            if model.chapter == nil {
                ContentUnavailableView(
                    "No Chapter Selected",
                    systemImage: "text.book.closed",
                    description: Text("Open a Bible chapter to inspect its translation notes and original-language links.")
                )
                .studyPaneState()
            } else if let errorMessage {
                ContentUnavailableView(
                    "Verse Details Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
                .studyPaneState()
            } else if isLoading && footnotesByReference.isEmpty && groups.isEmpty {
                ProgressView("Loading Verse Details…")
                    .studyPaneState()
            } else if groups.isEmpty {
                ContentUnavailableView(
                    "No Verse Notes",
                    systemImage: "text.book.closed",
                    description: Text("The selected translation has no footnotes or lexical annotations for \(contextDescription).")
                )
                .studyPaneState()
            } else {
                let groups = groups
                VerseAnchoredScrollView(
                    anchors: groups.map { VerseAnchor(reference: $0.id) },
                    focusedReference: model.selectedVerseReference
                ) {
                    ForEach(groups) { group in
                        verseGroupView(group)
                            .id(group.id)
                    }
                }
            }
        }
        .task(id: request) {
            await loadFootnotes()
        }
    }

    @ViewBuilder
    private func verseGroupView(_ group: VerseStudyGroup) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(group.title) { model.focusVerse(group.id) }
                .buttonStyle(.plain)
                .font(.headline)
                .foregroundStyle(model.selectedVerseReference == group.id ? Color.accentColor : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !group.footnotes.isEmpty {
                StudySection(title: "Translation Notes", systemImage: "note.text") {
                    ForEach(group.footnotes) { footnote in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Text(footnote.id)
                                    .font(.caption.monospaced().weight(.semibold))
                                if let kind = footnote.kind {
                                    Text(kind.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(footnote.content)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if !group.lexical.isEmpty {
                StudySection(title: "Original Language", systemImage: "character.book.closed") {
                    InterlinearTokenFlowLayout(horizontalSpacing: 16, verticalSpacing: 12) {
                        ForEach(group.lexical) { annotation in
                            lexicalToken(annotation)
                        }
                    }
                }
            }

            if !group.scripture.isEmpty {
                StudySection(title: "Cross-References", systemImage: "arrow.triangle.branch") {
                    ForEach(group.scripture) { annotation in
                        if let reference = annotation.startReference,
                           let description = annotation.scriptureDescription {
                            ScriptureReferenceButton(link: LampScriptureLink(
                                text: description,
                                startReference: reference,
                                endReference: annotation.endReference
                            ))
                        }
                    }
                }
            }
        }
    }

    private func lexicalToken(_ annotation: LampVerseAnnotation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(annotation.text ?? annotation.lemma ?? "Word")
                    .font(.headline)
                if showStrongsHints, let strongs = annotation.strongs {
                    Button(strongs) {
                        openDictionary(strongs, annotation.text ?? annotation.lemma)
                    }
                    .buttonStyle(.link)
                }
            }
            if let lemma = annotation.lemma, lemma != annotation.text {
                Text(lemma)
                    .font(.system(.body, design: .serif))
                    .textSelection(.enabled)
            }
            if let morphology = annotation.morphology {
                Text(morphology)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private func loadFootnotes() async {
        guard let translationID = request.translationID,
              let chapter = model.chapter else {
            footnotesByReference = [:]
            isLoading = false
            errorMessage = nil
            return
        }
        let references = chapter.verses.filter(\.hasFootnotes).map(\.id)
        guard !references.isEmpty else {
            footnotesByReference = [:]
            isLoading = false
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil
        var loaded: [Int: [LampVerseFootnote]] = [:]
        do {
            for reference in references {
                try Task.checkCancellation()
                let data = try await model.library.verseStudyData(
                    moduleID: translationID,
                    reference: reference
                )
                if let footnotes = data?.footnotes, !footnotes.isEmpty {
                    loaded[reference] = footnotes
                }
            }
            footnotesByReference = loaded
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            footnotesByReference = [:]
        }
        isLoading = false
    }

    private var contextDescription: String {
        guard let chapter = model.chapter else { return "the current chapter" }
        return "\(chapter.book.name) \(chapter.number)"
    }

    private func sortedScriptureAnnotations(
        _ annotations: [LampVerseAnnotation]
    ) -> [LampVerseAnnotation] {
        guard canonicalCrossReferenceOrder else { return annotations }
        return annotations.sorted {
            ($0.startReference ?? Int.max) < ($1.startReference ?? Int.max)
        }
    }
}

/// Places interlinear token stacks in reading order, moving a whole token to the
/// next line when the inspector is too narrow. Each token keeps its translation,
/// original-language data and dictionary link together as one visual unit.
private struct InterlinearTokenFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let availableWidth = finiteWidth(proposal.width) ?? .greatestFiniteMagnitude
        let result = arrangement(for: subviews, availableWidth: availableWidth)
        return CGSize(width: finiteWidth(proposal.width) ?? result.contentWidth, height: result.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = arrangement(for: subviews, availableWidth: max(bounds.width, 0))
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                anchor: .topLeading,
                proposal: .unspecified
            )
        }
    }

    private func arrangement(
        for subviews: Subviews,
        availableWidth: CGFloat
    ) -> (origins: [CGPoint], contentWidth: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let proposedX = x == 0 ? 0 : x + horizontalSpacing
            if x > 0, proposedX + size.width > availableWidth {
                x = 0
                y += lineHeight + verticalSpacing
                lineHeight = 0
            } else {
                x = proposedX
            }

            origins.append(CGPoint(x: x, y: y))
            x += size.width
            lineHeight = max(lineHeight, size.height)
            contentWidth = max(contentWidth, x)
        }

        return (origins, contentWidth, subviews.isEmpty ? 0 : y + lineHeight)
    }

    private func finiteWidth(_ width: CGFloat?) -> CGFloat? {
        guard let width, width.isFinite else { return nil }
        return max(width, 0)
    }
}

private struct StudySection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

private struct DictionaryResultView: View {
    let result: LampDictionaryResult
    /// Expanded for a looked-up word, where there are only a handful of entries and
    /// the definition is the thing you came for; collapsed in a search result list.
    var isExpanded = false
    let fontSize: Double
    let lineSpacing: Double
    let typeface: ProseTypeface

    @State private var isShowingDetail: Bool?

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { isShowingDetail ?? isExpanded },
            set: { isShowingDetail = $0 }
        )) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(result.senses.enumerated()), id: \.offset) { index, sense in
                    VStack(alignment: .leading, spacing: 6) {
                        if result.senses.count > 1 {
                            Text("Sense \(index + 1)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        if let partOfSpeech = sense.partOfSpeech {
                            Text(partOfSpeech)
                                .font(.caption.italic())
                                .foregroundStyle(.secondary)
                        }
                        if let gloss = sense.gloss {
                            Text(gloss)
                                .font(.system(size: fontSize, weight: .semibold, design: typeface.design))
                        }
                        if let shortDefinition = sense.shortDefinition {
                            Text(shortDefinition)
                                .font(.system(size: fontSize, design: typeface.design))
                        }
                        if let definition = sense.definition,
                           definition != sense.shortDefinition {
                            Text(definition)
                                .font(.system(size: fontSize, design: typeface.design))
                                .textSelection(.enabled)
                        }
                        if let usage = sense.usage {
                            Text("Usage: \(usage)")
                                .font(.system(size: max(fontSize - 1, 9), design: typeface.design))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if index < result.senses.count - 1 { Divider() }
                }
            }
            .padding(.vertical, 8)
            .lineSpacing(lineSpacing)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    // Which dictionary this came from leads the row: with several
                    // installed, the same key yields several entries, and the source
                    // is the only thing that tells them apart.
                    Text(result.moduleName)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    Text(result.key)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(result.lemma)
                        .font(.system(size: fontSize + 2, weight: .semibold, design: typeface.design))
                    Spacer()
                }
                if let transliteration = result.transliteration {
                    Text(transliteration)
                        .font(.system(size: max(fontSize - 1, 9), design: typeface.design).italic())
                        .foregroundStyle(.secondary)
                }
                if let summary = result.summary {
                    Text(summary)
                        .font(.system(size: max(fontSize - 1, 9), design: typeface.design))
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 4)
            .lineSpacing(lineSpacing)
        }
    }
}

private struct CommentaryRequest: Hashable {
    let bookNumber: Int?
    let chapterNumber: Int?
    let moduleID: String?
}

private struct CommentaryInspectorView: View {
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("studyInspector.commentaryModuleID") private var preferredModuleID = ""
    @AppStorage("commentary.fontSize") private var fontSize = LampTextScale.commentaryText.defaultValue
    @AppStorage("commentary.lineSpacing") private var lineSpacing = LampTextScale.commentaryLineSpacing.defaultValue
    @AppStorage("commentary.typeface") private var typeface = ProseTypeface.commentaryDefault
    @State private var units: [LampCommentaryUnit] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    /// One commentary at a time. Interleaving several turns a chapter into a wall of
    /// competing voices, and with the panel grouped by verse there is no running
    /// order that keeps any one commentary readable.
    private var activeModuleID: String? {
        if model.commentaries.contains(where: { $0.id == preferredModuleID }) {
            return preferredModuleID
        }
        return model.commentaries.first?.id
    }

    /// The whole chapter loads at once, deliberately: a panel that only held the
    /// selected verse would have nothing to scroll through, and reloading on every
    /// verse would make following the reader a stutter of database reads.
    private var request: CommentaryRequest {
        CommentaryRequest(
            bookNumber: model.chapter?.book.id,
            chapterNumber: model.chapter?.number,
            moduleID: activeModuleID
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if model.commentaries.count > 1 {
                    Picker("Commentary", selection: Binding(
                        get: { activeModuleID ?? "" },
                        set: { preferredModuleID = $0 }
                    )) {
                        ForEach(model.commentaries) { commentary in
                            Text(commentaryName(commentary)).tag(commentary.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                Spacer(minLength: 0)

                TextSizeMenu(
                    fontSize: $fontSize,
                    lineSpacing: $lineSpacing,
                    typeface: $typeface,
                    defaultTypeface: .commentaryDefault,
                    fontScale: .commentaryText,
                    lineSpacingScale: .commentaryLineSpacing,
                    help: "Choose the commentary typeface, text size, and line spacing"
                )
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .labelStyle(.iconOnly)
                // The commentary picker is greedy enough to squeeze a menu that
                // sizes itself out of the row altogether.
                .frame(width: 24)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            panelContent
        }
        .task(id: request) {
            guard let book = request.bookNumber,
                  let chapter = request.chapterNumber,
                  let moduleID = request.moduleID else {
                units = []
                return
            }
            isLoading = true
            errorMessage = nil
            do {
                units = try await model.library.commentary(
                    bookNumber: book,
                    chapterNumber: chapter,
                    moduleIDs: [moduleID]
                )
            } catch {
                errorMessage = error.localizedDescription
                units = []
            }
            isLoading = false
        }
    }

    private func commentaryName(_ commentary: LampInstalledModule) -> String {
        commentary.abbreviation.map { "\($0) — \(commentary.name)" } ?? commentary.name
    }

    @ViewBuilder
    private var panelContent: some View {
        Group {
            if model.commentaries.isEmpty {
                ContentUnavailableView(
                    "No Commentary Installed",
                    systemImage: "text.book.closed",
                    description: Text("Install a commentary .lamp module from the Modules section.")
                )
                .studyPaneState()
            } else if model.chapter == nil {
                ContentUnavailableView(
                    "No Chapter Selected",
                    systemImage: "book",
                    description: Text("Open a Bible chapter to view its commentary.")
                )
                .studyPaneState()
            } else if isLoading && units.isEmpty {
                ProgressView("Loading Commentary…")
                    .studyPaneState()
            } else if let errorMessage {
                ContentUnavailableView(
                    "Commentary Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
                .studyPaneState()
            } else if units.isEmpty {
                ContentUnavailableView(
                    "No Commentary Here",
                    systemImage: "text.book.closed",
                    description: Text(contextDescription)
                )
                .studyPaneState()
            } else {
                let groups = commentaryGroups
                VerseAnchoredScrollView(
                    anchors: groups.map(\.anchor),
                    focusedReference: model.selectedVerseReference
                ) {
                    Text(contextDescription)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(groups) { group in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(group.units) { unit in
                                    CommentaryUnitView(
                                        unit: unit,
                                        fontSize: LampTextScale.commentaryText.clamped(fontSize),
                                        lineSpacing: LampTextScale.commentaryLineSpacing.clamped(lineSpacing),
                                        typeface: typeface
                                    )
                                    if unit.id != group.units.last?.id { Divider() }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                        } label: {
                            Label(group.title, systemImage: "text.book.closed")
                        }
                        .id(group.id)
                    }
                }
            }
        }
    }

    private var contextDescription: String {
        guard let chapter = model.chapter else { return "Current passage" }
        return "\(chapter.book.name) \(chapter.number)"
    }

    /// Grouped by the passage a unit comments on rather than by module, so that a
    /// verse the reader is sitting on is one place in this panel even when three
    /// commentaries have something to say about it.
    private var commentaryGroups: [CommentaryGroup] {
        Dictionary(grouping: units, by: \.startReference)
            .compactMap { startReference, units -> CommentaryGroup? in
                let endReference = units.compactMap(\.endReference).max()
                return CommentaryGroup(
                    id: startReference,
                    endReference: endReference,
                    title: LampBibleReferenceFormatter.describeRange(
                        from: startReference,
                        to: endReference ?? startReference
                    ),
                    units: units.sorted {
                        ($0.moduleName, $0.orderIndex) < ($1.moduleName, $1.orderIndex)
                    }
                )
            }
            .sorted { $0.id < $1.id }
    }
}

private struct CommentaryGroup: Identifiable {
    let id: Int
    let endReference: Int?
    let title: String
    let units: [LampCommentaryUnit]

    var anchor: VerseAnchor {
        VerseAnchor(reference: id, endReference: endReference)
    }
}

private struct CommentaryUnitView: View {
    let unit: LampCommentaryUnit
    let fontSize: Double
    let lineSpacing: Double
    let typeface: ProseTypeface

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title = unit.title {
                Text(title)
                    .font(.system(
                        size: fontSize + (unit.level <= 1 ? 2 : 1),
                        weight: .semibold,
                        design: typeface.design
                    ))
            }
            if let introduction = unit.introduction {
                CommentaryLinkedText(text: introduction, links: unit.scriptureLinks)
                    .font(.system(size: fontSize, design: typeface.design))
            }
            if let translation = unit.translation {
                CommentaryLinkedText(text: translation, links: unit.scriptureLinks)
                    .font(.system(size: fontSize, design: typeface.design).italic())
                    .foregroundStyle(.secondary)
            }
            if let commentary = unit.commentary {
                CommentaryLinkedText(text: commentary, links: unit.scriptureLinks)
                    .font(.system(size: fontSize, design: typeface.design))
            }
            if let footnotes = unit.footnotes {
                CommentaryLinkedText(text: footnotes, links: unit.scriptureLinks)
                    .font(.system(size: max(fontSize - 2, 9), design: typeface.design))
                    .foregroundStyle(.secondary)
            }
            if !unmatchedScriptureLinks.isEmpty {
                CommentaryLinkedText(
                    text: "",
                    links: [],
                    appendedLinks: unmatchedScriptureLinks
                )
                .font(.system(size: fontSize, design: typeface.design))
            }
        }
        // Prose about a verse is denser than the verse itself, so the panel opens
        // its lines further than SwiftUI's default and lets the reader go further.
        .lineSpacing(lineSpacing)
    }

    /// Annotation offsets are local to the source JSON objects and the core model
    /// exposes their derived labels. Almost every annotation therefore maps back
    /// to its phrase exactly; this keeps malformed legacy annotations available as
    /// inline trailing links without bringing back a separate references panel.
    private var unmatchedScriptureLinks: [LampScriptureLink] {
        let textValues = [
            unit.introduction,
            unit.translation,
            unit.commentary,
            unit.footnotes,
        ].compactMap { $0 }
        return unit.scriptureLinks.filter { link in
            let label = link.inlineLabel
            return !textValues.contains {
                $0.range(of: label, options: [.caseInsensitive]) != nil
            }
        }
    }
}

private struct CommentaryLinkedText: View {
    let text: String
    let links: [LampScriptureLink]
    var appendedLinks: [LampScriptureLink] = []
    @State private var previewLink: LampScriptureLink?
    @State private var hoverLocation: CGPoint?
    @State private var previewAnchor = CGRect.zero

    var body: some View {
        Text(attributedText)
            .textSelection(.enabled)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                case .ended:
                    hoverLocation = nil
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "lampbible",
                      url.host == "read",
                      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      let value = components.queryItems?.first(where: { $0.name == "reference" })?.value,
                      let reference = Int(value) else { return .systemAction }
                let endReference = components.queryItems?
                    .first(where: { $0.name == "end" })?
                    .value
                    .flatMap(Int.init)
                previewAnchor = hoverLocation.map {
                    CGRect(x: $0.x - 1, y: $0.y - 1, width: 2, height: 2)
                } ?? .zero
                previewLink = LampScriptureLink(
                    startReference: reference,
                    endReference: endReference
                )
                return .handled
            })
            .popover(
                item: $previewLink,
                attachmentAnchor: previewAnchor == .zero
                    ? .rect(.bounds)
                    : .rect(.rect(previewAnchor))
            ) { link in
                ScriptureReferencePopover(link: link)
            }
    }

    private var attributedText: AttributedString {
        var result = AttributedString(text)
        var occupiedRanges: [Range<String.Index>] = []

        for link in links {
            guard let stringRange = firstAvailableRange(
                of: link.inlineLabel,
                occupiedRanges: occupiedRanges
            ),
                  let attributedRange = attributedRange(for: stringRange, in: result),
                  let url = link.inlineURL else { continue }
            result[attributedRange].link = url
            result[attributedRange].foregroundColor = .accentColor
            result[attributedRange].underlineStyle = .single
            occupiedRanges.append(stringRange)
        }

        if !appendedLinks.isEmpty {
            if !text.isEmpty { result.append(AttributedString(" ")) }
            result.append(AttributedString("("))
            for (index, link) in appendedLinks.enumerated() {
                if index > 0 { result.append(AttributedString("; ")) }
                var label = AttributedString(link.inlineLabel)
                if let url = link.inlineURL {
                    label.link = url
                    label.foregroundColor = .accentColor
                    label.underlineStyle = .single
                }
                result.append(label)
            }
            result.append(AttributedString(")"))
        }

        return result
    }

    private func firstAvailableRange(
        of label: String,
        occupiedRanges: [Range<String.Index>]
    ) -> Range<String.Index>? {
        guard !label.isEmpty else { return nil }
        for options: String.CompareOptions in [[], [.caseInsensitive]] {
            var searchRange = text.startIndex..<text.endIndex
            while let range = text.range(of: label, options: options, range: searchRange) {
                if !occupiedRanges.contains(where: { $0.overlaps(range) }) { return range }
                guard range.upperBound < text.endIndex else { break }
                searchRange = range.upperBound..<text.endIndex
            }
        }
        return nil
    }

    private func attributedRange(
        for stringRange: Range<String.Index>,
        in attributed: AttributedString
    ) -> Range<AttributedString.Index>? {
        guard let lowerBound = AttributedString.Index(stringRange.lowerBound, within: attributed),
              let upperBound = AttributedString.Index(stringRange.upperBound, within: attributed) else {
            return nil
        }
        return lowerBound..<upperBound
    }
}

private extension LampScriptureLink {
    var inlineLabel: String {
        if let label = text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            return label
        }
        return displayDescription
    }

    var inlineURL: URL? {
        var components = URLComponents()
        components.scheme = "lampbible"
        components.host = "read"
        components.queryItems = [
            URLQueryItem(name: "reference", value: String(startReference)),
        ]
        if let endReference {
            components.queryItems?.append(
                URLQueryItem(name: "end", value: String(endReference))
            )
        }
        return components.url
    }
}

private struct ScriptureReferenceButton: View {
    let link: LampScriptureLink
    @State private var isShowingPreview = false

    var body: some View {
        Button(link.displayDescription) {
            isShowingPreview = true
        }
        .buttonStyle(.link)
        .popover(isPresented: $isShowingPreview) {
            ScriptureReferencePopover(link: link)
        }
    }
}

private struct ScriptureReferencePopover: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.readerReferenceActions) private var referenceActions
    @EnvironmentObject private var model: LibraryModel
    let link: LampScriptureLink
    @State private var chapter: LampChapter?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(referenceDescription)
                    .font(.headline)
                if let translation {
                    Text(translation.abbreviation ?? translation.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)

            Divider()

            Group {
                if isLoading {
                    ProgressView("Loading passage…")
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Passage Unavailable",
                        systemImage: "book.closed",
                        description: Text(errorMessage)
                    )
                    .frame(minHeight: 150)
                } else if previewVerses.isEmpty {
                    ContentUnavailableView(
                        "Passage Unavailable",
                        systemImage: "book.closed",
                        description: Text("No verses were found for this reference.")
                    )
                    .frame(minHeight: 150)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(previewVerses) { verse in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(verse.number.formatted())
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(minWidth: 20, alignment: .trailing)
                                    Text(verse.text)
                                        .font(.system(.body, design: .serif))
                                        .textSelection(.enabled)
                                }
                            }
                            if hasMoreVerses {
                                Text("Passage continues…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 28)
                            }
                        }
                        .padding(16)
                    }
                    .frame(maxHeight: 300)
                }
            }

            Divider()

            HStack {
                Button("Open in Current View") {
                    referenceActions.openInCurrent(link.startReference)
                    dismiss()
                }
                Spacer()
                Button("Open in New Tab", systemImage: "plus.square.on.square") {
                    referenceActions.openInNewTab(link.startReference)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 420)
        .task(id: loadID) {
            await loadPassage()
        }
    }

    private var translation: LampInstalledModule? {
        model.selectedTranslation ?? model.translations.first
    }

    private var referenceDescription: String {
        LampBibleReferenceFormatter.describeRange(
            from: link.startReference,
            to: link.endReference ?? link.startReference
        )
    }

    private var loadID: String {
        "\(translation?.id ?? "none"):\(link.startReference):\(link.endReference ?? link.startReference)"
    }

    private var allPreviewVerses: [LampVerse] {
        guard let chapter else { return [] }
        let start = LampBibleReferenceFormatter.components(of: link.startReference)
        let endReference = max(link.endReference ?? link.startReference, link.startReference)
        let end = LampBibleReferenceFormatter.components(of: endReference)
        return chapter.verses.filter { verse in
            guard verse.id >= link.startReference else { return false }
            if start.book == end.book, start.chapter == end.chapter {
                return verse.id <= endReference
            }
            return true
        }
    }

    private var previewVerses: [LampVerse] {
        Array(allPreviewVerses.prefix(12))
    }

    private var hasMoreVerses: Bool {
        allPreviewVerses.count > previewVerses.count
            || LampBibleReferenceFormatter.components(of: link.startReference).chapter
                != LampBibleReferenceFormatter.components(of: link.endReference ?? link.startReference).chapter
            || LampBibleReferenceFormatter.components(of: link.startReference).book
                != LampBibleReferenceFormatter.components(of: link.endReference ?? link.startReference).book
    }

    @MainActor
    private func loadPassage() async {
        guard let translation else {
            chapter = nil
            errorMessage = "Install a translation to preview scripture references."
            return
        }
        let reference = LampBibleReferenceFormatter.components(of: link.startReference)
        isLoading = true
        errorMessage = nil
        do {
            chapter = try await model.library.chapter(
                moduleID: translation.id,
                bookNumber: reference.book,
                chapterNumber: reference.chapter
            )
        } catch {
            chapter = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
