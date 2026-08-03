import AppKit
import LampCore
import LampModuleKit
import SwiftUI
import UniformTypeIdentifiers

struct StudyInspectorView: View {
    @AppStorage("studyInspector.tab") private var selectedTab = "commentary"
    @State private var dictionaryQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("Study Tool", selection: $selectedTab) {
                Text("Commentary").tag("commentary")
                Text("Verse").tag("verse")
                Text("Notes").tag("notes")
                Text("Dictionary").tag("dictionary")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            Divider()

            switch selectedTab {
            case "dictionary":
                DictionaryInspectorView(query: $dictionaryQuery)
            case "verse":
                VerseInspectorView { query in
                    dictionaryQuery = query
                    selectedTab = "dictionary"
                }
            case "notes":
                NotesInspectorView()
            default:
                CommentaryInspectorView()
            }
        }
        .inspectorColumnWidth(min: 330, ideal: 410, max: 580)
    }
}

private struct NotesInspectorView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var title = ""
    @State private var content = ""
    @State private var savedTitle = ""
    @State private var savedContent = ""
    @State private var personalFootnotes: [LampVerseFootnote] = []
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var exportedURL: URL?
    @State private var transferStatus: String?

    private var reference: Int? { model.selectedVerseReference }
    private var verse: LampVerse? {
        guard let reference else { return nil }
        return model.chapter?.verses.first { $0.id == reference }
    }
    private var isDirty: Bool { title != savedTitle || content != savedContent }
    private var selectedHighlightColor: String? {
        reference
            .flatMap { model.personalHighlights(for: $0).first?.color }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased() }
    }
    private var installedNotes: [LampVerseNote] {
        reference.map(model.installedNotes(for:)) ?? []
    }

    var body: some View {
        Group {
            if let reference {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Text(LampBibleReferenceFormatter.describeRange(
                                from: reference,
                                to: reference
                            ))
                            .font(.headline)

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
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 10) {
                                Label("Personal Note", systemImage: "note.text")
                                    .font(.subheadline.weight(.semibold))
                                TextField("Title (optional)", text: $title)
                                    .textFieldStyle(.roundedBorder)
                                TextEditor(text: $content)
                                    .font(.body)
                                    .frame(minHeight: 220)
                                    .padding(7)
                                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 7))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 7)
                                            .stroke(.separator.opacity(0.7))
                                    }
                            }

                            if !personalFootnotes.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("Footnotes", systemImage: "text.append")
                                        .font(.subheadline.weight(.semibold))
                                    ForEach(personalFootnotes) { footnote in
                                        HStack(alignment: .top, spacing: 8) {
                                            Text(footnote.id)
                                                .font(.caption.monospaced().weight(.semibold))
                                            Text(footnote.content)
                                                .textSelection(.enabled)
                                        }
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
                        }
                        .padding()
                    }

                    Divider()

                    HStack {
                        if isLoading || isExporting {
                            ProgressView()
                                .controlSize(.small)
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
                        } else if !isDirty && (!savedTitle.isEmpty || !savedContent.isEmpty) {
                            Label("Saved", systemImage: "checkmark.circle")
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
                        .disabled(isDirty || isSaving || isLoading || isExporting)
                        .help(isDirty ? "Save or revert this note before transferring study data" : "Import or export personal study data")
                        Button("Revert") {
                            title = savedTitle
                            content = savedContent
                            errorMessage = nil
                        }
                        .disabled(!isDirty || isSaving)
                        Button(isSaving ? "Saving…" : "Save") {
                            save(reference: reference)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!isDirty || isSaving || isLoading)
                    }
                    .padding()
                }
                .task(id: reference) {
                    await load(reference: reference)
                }
            } else {
                ContentUnavailableView(
                    "Choose a Verse",
                    systemImage: "note.text",
                    description: Text("Click a verse number in the reader to add a note or highlight.")
                )
            }
        }
    }

    private func load(reference: Int) async {
        isLoading = true
        errorMessage = nil
        do {
            let note = try await model.personalNote(for: reference)
            guard !Task.isCancelled, model.selectedVerseReference == reference else { return }
            title = note?.title ?? ""
            content = note?.content ?? ""
            personalFootnotes = note?.footnotes ?? []
            savedTitle = title
            savedContent = content
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func save(reference: Int) {
        let submittedTitle = title
        let submittedContent = content
        isSaving = true
        errorMessage = nil
        exportedURL = nil
        transferStatus = nil
        Task {
            do {
                try await model.savePersonalNote(
                    reference: reference,
                    title: submittedTitle,
                    content: submittedContent
                )
                if model.selectedVerseReference == reference {
                    savedTitle = submittedTitle
                    savedContent = submittedContent
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func setHighlight(_ color: String?) {
        guard let reference, let verse else { return }
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

    private var currentBookName: String {
        guard let reference else { return "Current Book" }
        let book = LampBibleReferenceFormatter.components(of: reference).book
        return LampBibleReferenceFormatter.bookName(book)
    }

    private func export(_ kind: PersonalStudyExportKind, format: PersonalStudyExportFormat) {
        guard let reference, let translationID = model.selectedTranslationID else { return }
        let bookNumber = LampBibleReferenceFormatter.components(of: reference).book
        isExporting = true
        errorMessage = nil
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
                errorMessage = error.localizedDescription
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
        errorMessage = nil
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
                if let reference {
                    await load(reference: reference)
                }
                transferStatus = skippedCount == 0
                    ? "Imported \(importedCount)"
                    : "Imported \(importedCount), kept \(skippedCount) existing"
            } catch {
                errorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }

    private func moduleName(for moduleID: String) -> String {
        model.noteModules.first { $0.id == moduleID }?.name ?? moduleID
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

private struct DictionarySearchRequest: Hashable {
    let query: String
    let moduleID: String?
}

private struct DictionaryInspectorView: View {
    @EnvironmentObject private var model: LibraryModel
    @Binding var query: String
    @State private var moduleID: String?
    @State private var results: [LampDictionaryResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    private var request: DictionarySearchRequest {
        DictionarySearchRequest(query: query, moduleID: moduleID)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                TextField("Word, lemma, or Strong’s number", text: $query)
                    .textFieldStyle(.roundedBorder)
                if model.dictionaries.count > 1 {
                    Picker("Dictionary", selection: $moduleID) {
                        Text("All Dictionaries").tag(String?.none)
                        ForEach(model.dictionaries) { dictionary in
                            Text(dictionary.name).tag(Optional(dictionary.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()

            Divider()

            Group {
                if model.dictionaries.isEmpty {
                    ContentUnavailableView(
                        "No Dictionary Installed",
                        systemImage: "character.book.closed",
                        description: Text("Install a dictionary .lamp module from the Modules section.")
                    )
                } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        "Dictionary Lookup",
                        systemImage: "character.book.closed",
                        description: Text("Search by English word, lemma, transliteration, or key such as G3056.")
                    )
                } else if isSearching && results.isEmpty {
                    ProgressView("Looking Up…")
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Lookup Failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(results) { result in
                        DictionaryResultView(result: result)
                    }
                    .listStyle(.inset)
                }
            }
        }
        .task(id: request) {
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedQuery.isEmpty else {
                results = []
                isSearching = false
                errorMessage = nil
                return
            }
            isSearching = true
            errorMessage = nil
            do {
                try await Task.sleep(for: .milliseconds(200))
                let dictionaryIDs = moduleID.map { Set([$0]) }
                results = try await model.library.searchDictionaries(
                    query: trimmedQuery,
                    moduleIDs: dictionaryIDs,
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
}

private struct VerseStudyRequest: Hashable {
    let translationID: String?
    let reference: Int?
}

private struct VerseInspectorView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var studyData: LampVerseStudyData?
    @State private var isLoading = false
    @State private var errorMessage: String?
    let openDictionary: (String) -> Void

    private var request: VerseStudyRequest {
        VerseStudyRequest(
            translationID: model.selectedTranslationID,
            reference: model.selectedVerseReference
        )
    }

    private var hasVisibleStudyData: Bool {
        guard let studyData else { return false }
        return !studyData.footnotes.isEmpty
            || !studyData.lexicalAnnotations.isEmpty
            || !studyData.scriptureAnnotations.isEmpty
    }

    var body: some View {
        Group {
            if request.reference == nil {
                ContentUnavailableView(
                    "Choose a Verse",
                    systemImage: "text.book.closed",
                    description: Text("Click a verse number in the reader to inspect its translation notes and original-language links.")
                )
            } else if isLoading && studyData == nil {
                ProgressView("Loading Verse Details…")
            } else if let errorMessage {
                ContentUnavailableView(
                    "Verse Details Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if !hasVisibleStudyData {
                ContentUnavailableView(
                    "No Verse Notes",
                    systemImage: "text.book.closed",
                    description: Text("The selected translation has no footnotes or lexical annotations for \(contextDescription).")
                )
            } else if let studyData {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        Text(contextDescription)
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if !studyData.footnotes.isEmpty {
                            StudySection(title: "Translation Notes", systemImage: "note.text") {
                                ForEach(studyData.footnotes) { footnote in
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

                        if !studyData.lexicalAnnotations.isEmpty {
                            StudySection(title: "Original Language", systemImage: "character.book.closed") {
                                ForEach(studyData.lexicalAnnotations) { annotation in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(annotation.text ?? annotation.lemma ?? "Word")
                                                .font(.headline)
                                            Spacer()
                                            if let strongs = annotation.strongs {
                                                Button(strongs) { openDictionary(strongs) }
                                                    .buttonStyle(.link)
                                            }
                                        }
                                        if let lemma = annotation.lemma,
                                           lemma != annotation.text {
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
                                }
                            }
                        }

                        if !studyData.scriptureAnnotations.isEmpty {
                            StudySection(title: "References", systemImage: "arrow.triangle.branch") {
                                ForEach(studyData.scriptureAnnotations) { annotation in
                                    if let reference = annotation.startReference,
                                       let description = annotation.scriptureDescription {
                                        Button(description) {
                                            model.openReference(reference)
                                        }
                                        .buttonStyle(.link)
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .task(id: request) {
            guard let translationID = request.translationID,
                  let reference = request.reference else {
                studyData = nil
                isLoading = false
                errorMessage = nil
                return
            }
            isLoading = true
            errorMessage = nil
            do {
                studyData = try await model.library.verseStudyData(
                    moduleID: translationID,
                    reference: reference
                )
            } catch {
                errorMessage = error.localizedDescription
                studyData = nil
            }
            isLoading = false
        }
    }

    private var contextDescription: String {
        guard let chapter = model.chapter,
              let reference = model.selectedVerseReference else { return "the selected verse" }
        return "\(chapter.book.name) \(chapter.number):\(reference % 1_000)"
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

    var body: some View {
        DisclosureGroup {
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
                            Text(gloss).fontWeight(.semibold)
                        }
                        if let shortDefinition = sense.shortDefinition {
                            Text(shortDefinition)
                        }
                        if let definition = sense.definition,
                           definition != sense.shortDefinition {
                            Text(definition)
                                .textSelection(.enabled)
                        }
                        if let usage = sense.usage {
                            Text("Usage: \(usage)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if index < result.senses.count - 1 { Divider() }
                }
            }
            .padding(.vertical, 8)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(result.key)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(result.lemma)
                        .font(.headline)
                    Spacer()
                }
                if let transliteration = result.transliteration {
                    Text(transliteration)
                        .font(.callout.italic())
                        .foregroundStyle(.secondary)
                }
                if let summary = result.summary {
                    Text(summary)
                        .font(.callout)
                        .lineLimit(2)
                }
                Text(result.moduleName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct CommentaryRequest: Hashable {
    let bookNumber: Int?
    let chapterNumber: Int?
    let reference: Int?
    let moduleIDs: [String]
}

private struct CommentaryInspectorView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var units: [LampCommentaryUnit] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var request: CommentaryRequest {
        CommentaryRequest(
            bookNumber: model.chapter?.book.id,
            chapterNumber: model.chapter?.number,
            reference: model.selectedVerseReference,
            moduleIDs: model.commentaries.map(\.id)
        )
    }

    var body: some View {
        Group {
            if model.commentaries.isEmpty {
                ContentUnavailableView(
                    "No Commentary Installed",
                    systemImage: "text.book.closed",
                    description: Text("Install a commentary .lamp module from the Modules section.")
                )
            } else if model.chapter == nil {
                ContentUnavailableView(
                    "No Chapter Selected",
                    systemImage: "book",
                    description: Text("Open a Bible chapter to view its commentary.")
                )
            } else if isLoading && units.isEmpty {
                ProgressView("Loading Commentary…")
            } else if let errorMessage {
                ContentUnavailableView(
                    "Commentary Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if units.isEmpty {
                ContentUnavailableView(
                    "No Commentary Here",
                    systemImage: "text.book.closed",
                    description: Text(contextDescription)
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        Text(contextDescription)
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        ForEach(commentaryGroups) { group in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 16) {
                                    ForEach(group.units) { unit in
                                        CommentaryUnitView(unit: unit)
                                        if unit.id != group.units.last?.id { Divider() }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 5)
                            } label: {
                                Label(group.title, systemImage: "text.book.closed")
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .task(id: request) {
            guard let book = request.bookNumber, let chapter = request.chapterNumber else {
                units = []
                return
            }
            isLoading = true
            errorMessage = nil
            do {
                units = try await model.library.commentary(
                    bookNumber: book,
                    chapterNumber: chapter,
                    reference: request.reference
                )
            } catch {
                errorMessage = error.localizedDescription
                units = []
            }
            isLoading = false
        }
    }

    private var contextDescription: String {
        guard let chapter = model.chapter else { return "Current passage" }
        if let reference = model.selectedVerseReference {
            return "\(chapter.book.name) \(chapter.number):\(reference % 1_000)"
        }
        return "\(chapter.book.name) \(chapter.number)"
    }

    private var commentaryGroups: [CommentaryGroup] {
        let grouped = Dictionary(grouping: units, by: \.moduleID)
        return grouped.values.compactMap { units in
            guard let first = units.first else { return nil }
            let title = [first.seriesAbbreviation, first.moduleName]
                .compactMap { $0 }
                .joined(separator: " — ")
            return CommentaryGroup(
                id: first.moduleID,
                title: title,
                units: units.sorted { $0.orderIndex < $1.orderIndex }
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

private struct CommentaryGroup: Identifiable {
    let id: String
    let title: String
    let units: [LampCommentaryUnit]
}

private struct CommentaryUnitView: View {
    @EnvironmentObject private var model: LibraryModel
    let unit: LampCommentaryUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title = unit.title {
                Text(title)
                    .font(unit.level <= 1 ? .headline : .subheadline.weight(.semibold))
            }
            if let introduction = unit.introduction {
                Text(introduction)
                    .textSelection(.enabled)
            }
            if let translation = unit.translation {
                Text(translation)
                    .font(.system(.body, design: .serif).italic())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let commentary = unit.commentary {
                Text(commentary)
                    .textSelection(.enabled)
            }
            if let footnotes = unit.footnotes {
                Text(footnotes)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !unit.scriptureLinks.isEmpty {
                Divider()
                Text("References")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 92), alignment: .leading)],
                    alignment: .leading,
                    spacing: 7
                ) {
                    ForEach(unit.scriptureLinks) { link in
                        Button(link.displayDescription) {
                            model.openReference(link.startReference)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}
