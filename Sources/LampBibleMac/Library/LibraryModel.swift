import Foundation
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampModuleKit

struct DictionaryLookupRequest: Equatable {
    let id = UUID()
    let keys: [String]
    /// The word in the verse that was clicked, when the lookup came from the reader.
    let word: String?
}

enum BiblicalOriginalLanguage: String, CaseIterable {
    case greek
    case hebrew

    /// The language a Strong's key belongs to, or nil for ordinary words.
    ///
    /// Only from a real key. This used to read the first letter of whatever
    /// was typed, so searching "grace" looked in the Greek lexicon alone and
    /// "hope" in the Hebrew one — the wrong dictionary, with nothing on
    /// screen to say the others had been dropped.
    static func inferred(from key: String) -> Self? {
        guard let key = LampStrongsKey.typedKey(key) else { return nil }
        switch key.first {
        case "G": return .greek
        case "H": return .hebrew
        default: return nil
        }
    }
}

extension LampInstalledModule {
    var biblicalOriginalLanguage: BiblicalOriginalLanguage? {
        let declaredLanguage = language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch declaredLanguage {
        case "greek", "grc", "el", "ell", "ancient greek", "koine greek":
            return .greek
        case "hebrew", "heb", "he", "hbo", "aramaic":
            return .hebrew
        default:
            break
        }

        // Some older SWORD imports describe the language of their definitions as
        // English. Their stable ID/name still identifies the source lexicon.
        let identity = [id, name, abbreviation]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if identity.contains("greek") { return .greek }
        if identity.contains("hebrew") { return .hebrew }
        return nil
    }
}

/// Remembers Strong's-to-lexicon mappings, off the main actor.
///
/// Deliberately its own actor rather than state on `LibraryModel`. The model is
/// `@MainActor`, so warming a cache through it has to be *scheduled on the main
/// thread* — which during a study-column open is busy reflowing the reader and
/// running the reveal for 130–210 ms. A prefetch that cannot start until that is
/// over is not a prefetch. Here the query begins on the click regardless of what
/// the main thread is doing.
actor LexiconMappingStore {
    private let library: LampLibrary
    private var mappingsByKey: [String: [String]] = [:]
    private var tasksByKey: [String: Task<[String], Error>] = [:]

    init(library: LampLibrary) {
        self.library = library
    }

    /// Concurrent callers for one key share a single query rather than queueing
    /// behind each other on the library actor.
    func mappings(sourceKey: String) async throws -> [String] {
        if let cached = mappingsByKey[sourceKey] { return cached }
        if let inFlight = tasksByKey[sourceKey] { return try await inFlight.value }

        let task = Task { [library] in try await library.lexiconMappings(sourceKey: sourceKey) }
        tasksByKey[sourceKey] = task
        defer { tasksByKey[sourceKey] = nil }
        let mappings = try await task.value
        mappingsByKey[sourceKey] = mappings
        return mappings
    }

    /// Fire-and-forget warming, for the moment a lookup is asked for rather than
    /// the moment a view exists to display it.
    nonisolated func prefetch(sourceKeys: [String]) {
        Task.detached(priority: .userInitiated) { [self] in
            for key in sourceKeys {
                _ = try? await mappings(sourceKey: key)
            }
        }
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var modules: [LampInstalledModule] = []
    /// The reader's own highlight sets, for the search filters: a custom
    /// set's module ID is a UUID, which is no use in a menu.
    @Published private(set) var highlightSets: [LampHighlightSet] = []
    @Published private(set) var books: [LampTranslationBook] = []
    @Published private(set) var chapter: LampChapter?
    @Published private(set) var isRefreshing = false
    /// False until the library has been read once: which translations there
    /// are, and which note and highlight modules a chapter is read with. A
    /// window opens its first chapter after this, so that chapter is read
    /// once and whole.
    @Published private(set) var hasReadLibrary = false
    /// False until the library has been read and the opening chapter is on screen,
    /// so the window can hold a splash rather than assemble itself around empty
    /// states. One-way: later refreshes never send the interface away again.
    @Published private(set) var hasLoadedInitialContent = false
    @Published private(set) var isImporting = false
    @Published private(set) var isReadingTranslation = false
    /// A Bible file read and waiting for the user to name it.
    @Published var pendingTranslationImport: PendingTranslationImport?
    @Published var translationUnlockRequest: TranslationUnlockRequest?
    @Published var translationImportMessage: String?
    /// What the last install of finished modules did, for the pane whose
    /// button started it to show. Installing used to succeed in silence.
    @Published var moduleInstallMessage: String?
    @Published private(set) var isImportingStudyData = false
    @Published private(set) var moduleSearchResults: [LampModuleSearchResult] = []
    @Published private(set) var isModuleSearching = false
    @Published private(set) var selectedVerseReference: Int?
    @Published private(set) var dictionaryLookupRequest: DictionaryLookupRequest?
    @Published private(set) var highlightsByReference: [Int: [LampVerseHighlight]] = [:]
    @Published private(set) var installedHighlightsByReference: [Int: [LampVerseHighlight]] = [:]
    @Published private(set) var noteReferences: Set<Int> = []
    @Published private(set) var installedNotesByReference: [Int: [LampVerseNote]] = [:]
    @Published private(set) var plans: [LampReadingPlan] = []
    @Published private(set) var devotionals: [LampDevotional] = []
    @Published private(set) var quizModules: [LampQuizModule] = []
    @Published private(set) var selectedPlanIDs: Set<String> = []
    @Published private(set) var completedReadingIDs: Set<String> = []
    @Published private(set) var planProgressYear = LampPlanCalendar.year(for: Date())
    @Published var errorMessage: String?
    @Published var studyImportMessage: String?

    @Published private(set) var selectedTranslationID: String?
    @Published private(set) var selectedBookNumber: Int?
    @Published private(set) var selectedChapterNumber = 1

    let library: LampLibrary
    private var searchTask: Task<Void, Never>?
    private var moduleSearchTask: Task<Void, Never>?
    private var searchToken: UUID?
    private let lexiconMappingStore: LexiconMappingStore
    private let defaults: UserDefaults
    @Published private(set) var hiddenModuleIDs: Set<String>
    /// The background index build, cancelled when the library is read again
    /// so two refreshes do not index at once.
    private var strongsIndexTask: Task<Void, Never>?

    var translations: [LampInstalledModule] {
        visibleModules(kind: .translation)
    }

    var dictionaries: [LampInstalledModule] {
        visibleModules(kind: .dictionary)
    }

    var commentaries: [LampInstalledModule] {
        visibleModules(kind: .commentary)
    }

    var planModules: [LampInstalledModule] {
        modules.filter { $0.kind == .plan }
    }

    var noteModules: [LampInstalledModule] {
        modules.filter { $0.kind == .notes }
    }

    var highlightModules: [LampInstalledModule] {
        modules.filter { $0.kind == .highlights }
    }

    var devotionalModules: [LampInstalledModule] {
        modules.filter { $0.kind == .devotional }
    }

    var quizModuleInstallations: [LampInstalledModule] {
        modules.filter { $0.kind == .quiz }
    }

    var selectedTranslation: LampInstalledModule? {
        translations.first { $0.id == selectedTranslationID }
    }

    var selectedBook: LampTranslationBook? {
        books.first { $0.id == selectedBookNumber }
    }

    var readerLocation: ReaderLocation? { currentReaderLocation }

    init(
        library: LampLibrary? = nil,
        defaults: UserDefaults = .standard
    ) {
        let resolvedLibrary = library ?? LampLibrary(
            bundledModulesArchiveURL: Bundle.main.url(
                forResource: "bundled_modules.db",
                withExtension: "zlib"
            )
        )
        let settingsRecoveryError: Error?
        do {
            try LampSyncSettingsCommit.recover(
                from: resolvedLibrary.rootURL, to: defaults
            )
            settingsRecoveryError = nil
        } catch {
            settingsRecoveryError = error
        }
        self.library = resolvedLibrary
        self.lexiconMappingStore = LexiconMappingStore(library: resolvedLibrary)
        self.defaults = defaults
        hiddenModuleIDs = Set(defaults.stringArray(forKey: "modules.hiddenIDs") ?? [])
        selectedTranslationID = defaults.string(forKey: "reader.translationID")
        let storedBook = defaults.integer(forKey: "reader.bookNumber")
        selectedBookNumber = storedBook > 0 ? storedBook : nil
        selectedChapterNumber = max(defaults.integer(forKey: "reader.chapterNumber"), 1)
        errorMessage = settingsRecoveryError?.localizedDescription
    }

    deinit {
        searchTask?.cancel()
        moduleSearchTask?.cancel()
    }

    /// Reads the library for the first time. No reader is open yet to read
    /// a chapter again: each window reads its own once this is done.
    func start() {
        guard modules.isEmpty, !isRefreshing else { return }
        Task { await refreshLibrary(reloadingReader: false) }
    }

    func refresh() {
        Task { await refreshLibrary() }
    }

    func setModuleHidden(_ moduleID: String, hidden: Bool) {
        if hidden {
            hiddenModuleIDs.insert(moduleID)
        } else {
            hiddenModuleIDs.remove(moduleID)
        }
        defaults.set(Array(hiddenModuleIDs).sorted(), forKey: "modules.hiddenIDs")
        if hidden, activeReader?.selectedTranslationID == moduleID, let replacement = translations.first {
            activeReader?.selectTranslation(replacement.id)
        }
    }

    func setDefaultTranslation(_ moduleID: String?) {
        defaults.set(moduleID, forKey: "reader.defaultTranslationID")
        if let moduleID { activeReader?.selectTranslation(moduleID) }
    }

    /// Reads the active reader's chapter again, for notes and highlights
    /// just imported or edited.
    func reloadCurrentChapterStudyData() {
        activeReader?.reload()
    }

    /// Installs finished `.lamp` modules, and says what it installed.
    ///
    /// A file that is not a module is not turned away over its extension: a
    /// Bible in another format, chosen here rather than in the Bible
    /// importer, is read there instead. Which pane someone was standing in is
    /// not something the file has to agree with.
    func install(_ urls: [URL]) {
        guard !isImporting else { return }
        switch LampLibraryAddition.route(urls) {
        case .readBible(let url):
            readTranslation(at: url)
        case .unusable:
            errorMessage = LampLibraryError.invalidFileExtension.localizedDescription
        case .installModules(let lampURLs, let others):
            isImporting = true
            errorMessage = nil
            moduleInstallMessage = nil
            Task {
                var installed: [LampInstalledModule] = []
                do {
                    for url in lampURLs {
                        let module = try await library.install(from: url)
                        installed.append(module)
                        if module.kind == .plan {
                            try await library.setPlanSelected(moduleID: module.id, selected: true)
                        }
                    }
                    if let translation = installed.last(where: { $0.kind == .translation }) {
                        selectedTranslationID = translation.id
                    }
                    await refreshLibrary()
                } catch {
                    errorMessage = error.localizedDescription
                }
                // Said even when one of several modules failed: what was
                // installed is installed, and the error names the one that
                // was not.
                moduleInstallMessage = LampLibraryAddition.installSummary(
                    installed, notModules: others
                )
                isImporting = false
            }
        }
    }

    /// Reads a Bible the user has in another format. Reading a whole Bible
    /// takes a second or more, so it happens off the main actor; the sheet
    /// that names it opens when it is done.
    /// A locked SWORD module comes back as a request for its key, and is
    /// read again with it.
    func readTranslation(at url: URL, unlockKey: String? = nil) {
        guard !isReadingTranslation, !isImporting else { return }
        // A finished module offered here is installed rather than told it
        // "isn't a Bible format Lamp can import": it is a Bible, and one Lamp
        // converted already.
        guard !LampLibraryAddition.isModule(url) else {
            install([url])
            return
        }
        isReadingTranslation = true
        errorMessage = nil
        Task {
            do {
                let translation = try await Task.detached(priority: .userInitiated) {
                    try LampTranslationImporter().read(url, unlockKey: unlockKey)
                }.value
                pendingTranslationImport = PendingTranslationImport(
                    sourceName: url.lastPathComponent,
                    translation: translation
                )
            } catch let error as LampTranslationImportError where error.unlockPrompt != nil {
                translationUnlockRequest = TranslationUnlockRequest(url: url, prompt: error.unlockPrompt ?? "")
            } catch {
                errorMessage = error.localizedDescription
            }
            isReadingTranslation = false
        }
    }

    func importTranslation(
        _ pending: PendingTranslationImport,
        name: String,
        abbreviation: String,
        language: String
    ) {
        guard !isImporting else { return }
        let destination = LampTranslationImporter.destination(abbreviation: abbreviation, installed: modules)
        let translation = pending.translation
        isImporting = true
        errorMessage = nil
        Task {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("lamp-translation-import-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let compiled = try await Task.detached(priority: .userInitiated) {
                    try translation.compile(
                        into: directory,
                        id: destination.moduleID,
                        name: name,
                        abbreviation: abbreviation,
                        language: language
                    )
                }.value
                let module = try await library.install(from: compiled.outputURL)
                selectedTranslationID = module.id
                await refreshLibrary()
                translationImportMessage = translation.report.completionMessage(
                    translationName: name,
                    replaced: destination.replacedModuleID != nil
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }

    func openDataFile(_ url: URL) {
        guard !isImportingStudyData else { return }
        isImportingStudyData = true
        Task {
            do {
                do {
                    _ = try await library.importPersonalDevotional(from: url)
                    await refreshLibrary()
                } catch {
                    _ = try await library.importPersonalStudyData(from: url)
                    reloadCurrentChapterStudyData()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isImportingStudyData = false
        }
    }

    /// Opens a reference in the reader being used.
    ///
    /// Called from windows that are not readers — a search result, a deep
    /// link, a cross-reference in a writing — so it goes to the active reader
    /// rather than to a place of the library's own. With no reader open it is
    /// kept for the next one, which is what used to happen by the library
    /// simply holding the place itself.
    func openReference(_ encodedReference: Int, translationID: String?) {
        guard let activeReader else {
            let parts = LampBibleReferenceFormatter.components(of: encodedReference)
            let translation = translationID
                ?? selectedTranslationID
                ?? translations.first?.id
            guard let translation else { return }
            pendingReaderLocation = ReaderLocation(
                translationID: translation,
                bookNumber: parts.book,
                chapterNumber: parts.chapter,
                verseReference: encodedReference
            )
            return
        }
        let translation = translationID.flatMap { id in
            translations.contains { $0.id == id } ? id : nil
        }
        activeReader.openReference(encodedReference, translationID: translation)
    }

    func importPersonalStudyData(_ urls: [URL]) {
        guard !urls.isEmpty, !isImportingStudyData else { return }
        isImportingStudyData = true
        errorMessage = nil
        studyImportMessage = nil
        Task {
            do {
                var importedCount = 0
                var skippedCount = 0
                for url in urls {
                    let result = try await library.importPersonalStudyData(from: url)
                    importedCount += result.importedCount
                    skippedCount += result.skippedCount
                }
                reloadCurrentChapterStudyData()
                studyImportMessage = skippedCount == 0
                    ? "Imported \(importedCount) note or highlight entr\(importedCount == 1 ? "y" : "ies")."
                    : "Imported \(importedCount); kept \(skippedCount) existing entr\(skippedCount == 1 ? "y" : "ies")."
            } catch {
                errorMessage = error.localizedDescription
            }
            isImportingStudyData = false
        }
    }

    func importPersonalMarkdown(_ urls: [URL], as kind: LampPersonalMarkdownKind) {
        guard !urls.isEmpty, !isImportingStudyData else { return }
        isImportingStudyData = true
        errorMessage = nil
        studyImportMessage = nil
        Task {
            do {
                var importedCount = 0
                for url in urls {
                    let result = try await library.importPersonalMarkdown(from: url, as: kind)
                    importedCount += result.importedCount
                }
                switch kind {
                case .notes:
                    reloadCurrentChapterStudyData()
                    studyImportMessage = "Imported \(importedCount) Markdown note entr\(importedCount == 1 ? "y" : "ies")."
                case .devotionals:
                    await refreshLibrary()
                    studyImportMessage = "Imported \(importedCount) Markdown writing entr\(importedCount == 1 ? "y" : "ies")."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isImportingStudyData = false
        }
    }

    func remove(_ module: LampInstalledModule) {
        Task {
            do {
                // Written down before it goes: afterwards there is nothing
                // left to say it was ever here, and sync would fetch it back.
                try? LampSyncRemovedModules.record(module, inLibraryAt: library.rootURL)
                try await library.remove(moduleID: module.id)
                if selectedTranslationID == module.id {
                    selectedTranslationID = nil
                    selectedBookNumber = nil
                    chapter = nil
                    highlightsByReference = [:]
                    installedHighlightsByReference = [:]
                }
                await refreshLibrary()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }


    /// Stops any running search and empties the results.
    ///
    /// For a caller that has taken over the list — the Strong's analysis
    /// shows its own occurrences — so that a search already in flight does
    /// not land afterwards and replace them.
    func clearModuleSearch() {
        moduleSearchTask?.cancel()
        moduleSearchTask = nil
        moduleSearchResults = []
        isModuleSearching = false
    }

    func searchModules(
        _ query: String,
        kind: LampModuleKind? = nil,
        moduleID: String? = nil,
        bookRange: ClosedRange<Int>? = nil,
        strongsKey: String? = nil,
        highlightColors: Set<String>? = nil,
        devotionalCriteria: LampDevotionalSearchCriteria = .init()
    ) {
        moduleSearchTask?.cancel()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // A date, tag or category is a search in its own right: core answers
        // one now, and without this the fields did nothing on their own.
        guard !trimmedQuery.isEmpty
            || strongsKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || highlightColors?.isEmpty == false
            || devotionalCriteria != LampDevotionalSearchCriteria() else {
            moduleSearchResults = []
            isModuleSearching = false
            return
        }
        isModuleSearching = true
        moduleSearchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let includedModuleIDs: Set<String>?
                if let moduleID {
                    includedModuleIDs = [moduleID]
                } else if hiddenModuleIDs.isEmpty {
                    includedModuleIDs = nil
                } else {
                    let personalSetIDs = Set((try await library.highlightSets()).map(\.id))
                    includedModuleIDs = Set(modules.filter {
                        !hiddenModuleIDs.contains($0.id)
                    }.map(\.id))
                        .union(["personal-notes", "personal-devotionals"])
                        .union(personalSetIDs)
                }
                let results = try await library.searchModules(
                    query: trimmedQuery,
                    kinds: kind.map { Set([$0]) },
                    moduleIDs: includedModuleIDs,
                    bookRange: bookRange,
                    strongsKey: strongsKey,
                    highlightColors: highlightColors,
                    devotionalCriteria: devotionalCriteria,
                    limit: 250
                )
                guard !Task.isCancelled else { return }
                moduleSearchResults = results
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                moduleSearchResults = []
            }
            if !Task.isCancelled { isModuleSearching = false }
        }
    }

    func focusVerse(_ reference: Int?) {
        selectedVerseReference = reference
    }

    func requestDictionaryLookup(keys: [String], word: String? = nil) {
        let normalizedKeys = keys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
        guard !normalizedKeys.isEmpty else { return }
        dictionaryLookupRequest = DictionaryLookupRequest(keys: normalizedKeys, word: word)

        // Start the lookup on the click, rather than leaving it until the dictionary
        // pane exists. The pane's own load does not get a turn until the study column
        // has mounted and laid out — measured at 130–210 ms after the click. This
        // call does not touch the main actor, so the query runs during that window
        // instead of after it.
        lexiconMappingStore.prefetch(sourceKeys: normalizedKeys)
    }

    /// Strong's-to-lexicon mappings for a key, fetched once and remembered.
    func lexiconMappings(sourceKey: String) async throws -> [String] {
        try await lexiconMappingStore.mappings(sourceKey: sourceKey)
    }

    func consumeDictionaryLookupRequest(_ request: DictionaryLookupRequest) {
        guard dictionaryLookupRequest?.id == request.id else { return }
        dictionaryLookupRequest = nil
    }

    /// A chapter of another translation, with its highlights, for reading
    /// beside the selected one. Asked for by the reader rather than kept here:
    /// nothing else in the library follows it.
    func companionChapter(
        translationID: String,
        book: Int,
        chapter: Int
    ) async throws -> (chapter: LampChapter, highlights: [LampVerseHighlight]) {
        async let chapterRequest = library.chapter(
            moduleID: translationID,
            bookNumber: book,
            chapterNumber: chapter
        )
        async let highlightsRequest = library.verseHighlights(
            translationID: translationID,
            bookNumber: book,
            chapterNumber: chapter
        )
        let (loadedChapter, personalHighlights) = try await (chapterRequest, highlightsRequest)
        var installedHighlights: [LampVerseHighlight] = []
        for highlightsModule in highlightModules {
            installedHighlights += (try? await library.moduleVerseHighlights(
                moduleID: highlightsModule.id,
                bookNumber: book,
                chapterNumber: chapter
            )) ?? []
        }
        // Installed first, as `highlights(for:)` lays them, so the reader's
        // own are drawn over them.
        return (loadedChapter, installedHighlights + personalHighlights)
    }

    func highlights(for reference: Int) -> [LampVerseHighlight] {
        (installedHighlightsByReference[reference] ?? [])
            + (highlightsByReference[reference] ?? [])
    }

    func personalHighlights(for reference: Int) -> [LampVerseHighlight] {
        highlightsByReference[reference] ?? []
    }

    /// Every verse in the chapter with a note of either kind, including any
    /// the translation being read leaves out.
    var notedReferences: Set<Int> {
        noteReferences.union(installedNotesByReference.keys)
    }

    func hasPersonalNote(for reference: Int) -> Bool {
        noteReferences.contains(reference)
    }

    func installedNotes(for reference: Int) -> [LampVerseNote] {
        installedNotesByReference[reference] ?? []
    }

    func hasInstalledNote(for reference: Int) -> Bool {
        installedNotesByReference[reference]?.isEmpty == false
    }

    func personalNote(for reference: Int) async throws -> LampVerseNote? {
        try await library.verseNotes(reference: reference)
            .first { $0.moduleID == "personal-notes" }
    }

    func savePersonalNote(
        reference: Int,
        title: String?,
        content: String,
        verseReferences: [Int],
        footnotes: [LampVerseFootnote]
    ) async throws {
        let note = try await library.setPersonalVerseNote(
            reference: reference,
            title: title,
            content: content,
            verseReferences: verseReferences,
            footnotes: footnotes
        )
        if note == nil {
            noteReferences.remove(reference)
        } else {
            noteReferences.insert(reference)
        }
    }

    func setWholeVerseHighlight(
        reference: Int,
        textLength: Int,
        color: String?
    ) async throws {
        guard let translationID = selectedTranslationID else { return }
        let setID = "personal-highlights:\(translationID)"

        // Removing clears every set of this reader's own, not just the
        // default one. The menu offers "Remove Highlight" whenever the verse
        // carries any highlight of theirs, so clearing one set left the others
        // on the page and the command looked as though it had done nothing.
        // A module's highlights are not this reader's and are left alone.
        guard let color else {
            for id in Set((highlightsByReference[reference] ?? []).map(\.setID)) {
                try await library.deleteVerseHighlights(setID: id, reference: reference)
            }
            guard selectedTranslationID == translationID else { return }
            highlightsByReference.removeValue(forKey: reference)
            return
        }

        try await library.deleteVerseHighlights(
            setID: setID,
            reference: reference
        )
        let retainedHighlights = (highlightsByReference[reference] ?? [])
            .filter { $0.setID != setID }
        let highlight = try await library.saveVerseHighlight(
            translationID: translationID,
            reference: reference,
            startOffset: 0,
            endOffset: textLength,
            color: color
        )
        guard selectedTranslationID == translationID else { return }
        highlightsByReference[reference] = retainedHighlights + [highlight]
    }

    func saveVerseHighlight(
        reference: Int,
        startOffset: Int,
        endOffset: Int,
        style: LampHighlightStyle,
        color: String,
        setID: String
    ) async throws {
        guard let translationID = selectedTranslationID else { return }
        let highlight = try await library.saveVerseHighlight(
            translationID: translationID,
            reference: reference,
            startOffset: startOffset,
            endOffset: endOffset,
            style: style,
            color: color,
            setID: setID
        )
        guard selectedTranslationID == translationID else { return }
        highlightsByReference[reference, default: []].append(highlight)
        highlightsByReference[reference]?.sort {
            ($0.startOffset, $0.endOffset, $0.id) < ($1.startOffset, $1.endOffset, $1.id)
        }
    }

    /// Removes a set of the reader's own, and every highlight in it.
    ///
    /// The default set is not offered for deletion: it is where an ordinary
    /// highlight goes, so removing it would mean the next highlight recreated
    /// it with nothing in it.
    func deleteHighlightSet(id: String) async throws {
        guard id != "personal-highlights:\(selectedTranslationID ?? "")" else { return }
        try await library.deleteHighlightSet(id: id)
        for (reference, highlights) in highlightsByReference {
            let kept = highlights.filter { $0.setID != id }
            if kept.isEmpty {
                highlightsByReference.removeValue(forKey: reference)
            } else {
                highlightsByReference[reference] = kept
            }
        }
    }

    func deleteVerseHighlight(id: Int64, reference: Int) async throws {
        try await library.deleteVerseHighlight(id: id)
        highlightsByReference[reference]?.removeAll { $0.id == id }
        if highlightsByReference[reference]?.isEmpty == true {
            highlightsByReference.removeValue(forKey: reference)
        }
    }

    func openReading(_ reading: LampPlanReading) {
        openReference(reading.startReference, translationID: nil)
    }

    func setPlanSelected(_ planID: String, selected: Bool) {
        Task {
            do {
                try await library.setPlanSelected(moduleID: planID, selected: selected)
                if selected {
                    selectedPlanIDs.insert(planID)
                } else {
                    selectedPlanIDs.remove(planID)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func quizQuestions(
        moduleID: String,
        day: Int,
        ageGroup: String
    ) async -> [LampQuizQuestion] {
        do {
            return try await library.quizQuestions(
                moduleID: moduleID,
                day: day,
                ageGroup: ageGroup
            )
        } catch {
            guard !Task.isCancelled else { return [] }
            errorMessage = error.localizedDescription
            return []
        }
    }

    @discardableResult
    func savePersonalDevotional(_ devotional: LampDevotional) async throws -> LampDevotional {
        let saved = try await library.savePersonalDevotional(devotional)
        devotionals = try await library.devotionals()
        await refreshManuscriptNotes(for: saved)
        return saved
    }

    /// Re-splits the writing across any deck whose notes follow it, and reports
    /// each split into the writing's agent workspace.
    ///
    /// Every save comes through here — the editor, an agent's edit picked up
    /// from the workspace, a sync merge — which is the point: a speaker's notes
    /// keep up with the prose without anyone running anything, and an agent is
    /// told when an edit broke a slide's anchor. A deck whose notes are
    /// authored is untouched.
    ///
    /// Handed off rather than awaited: the work is coalesced across a burst of
    /// autosaves, so a save returns without waiting for every deck in the
    /// library to be decoded.
    private func refreshManuscriptNotes(for devotional: LampDevotional) async {
        await LampManuscriptNotesRefresh.shared.schedule(
            .init(
                libraryRootURL: library.rootURL,
                devotionalID: devotional.id,
                manuscript: devotional.displayMarkdown,
                // Named whether or not it exists: a writing with no workspace
                // has no status file, and the refresh then has nobody to tell
                // and says nothing. Checking here would put a stat on the save
                // path for no answer the refresh does not already have.
                workspaceURL: DevotionalAgentWorkspaceFiles.workspaceURL(
                    libraryRootURL: library.rootURL,
                    devotionalID: devotional.id
                )
            )
        )
    }

    func deletePersonalDevotional(id: String) async throws {
        try await library.deletePersonalDevotional(id: id)
        devotionals = try await library.devotionals()
    }

    func loadPlanProgress(year: Int) async {
        do {
            let completed = try await library.completedReadings(year: year)
            guard !Task.isCancelled else { return }
            planProgressYear = year
            completedReadingIDs = Set(completed.map(\.id))
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func toggleReading(
        planID: String,
        day: Int,
        readingIndex: Int,
        year: Int
    ) {
        let id = LampLibrary.completedReadingID(
            planID: planID, day: day, readingIndex: readingIndex, year: year
        )
        setReadingCompleted(
            planID: planID,
            day: day,
            readingIndex: readingIndex,
            year: year,
            completed: !completedReadingIDs.contains(id)
        )
    }

    func setReadingCompleted(
        planID: String,
        day: Int,
        readingIndex: Int,
        year: Int,
        completed: Bool
    ) {
        let id = LampLibrary.completedReadingID(
            planID: planID, day: day, readingIndex: readingIndex, year: year
        )
        guard completedReadingIDs.contains(id) != completed else { return }
        Task {
            do {
                try await library.setReadingCompleted(
                    planID: planID,
                    day: day,
                    readingIndex: readingIndex,
                    year: year,
                    completed: completed
                )
                guard planProgressYear == year else { return }
                if completed {
                    completedReadingIDs.insert(id)
                } else {
                    completedReadingIDs.remove(id)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Reads what is installed, and chooses the translation a window with
    /// nowhere of its own opens. After the first read the active reader
    /// reads its chapter again, since what changed may be its notes and
    /// highlights.
    private func refreshLibrary(reloadingReader: Bool = true) async {
        isRefreshing = true
        do {
            try LampSyncSettingsCommit.recover(from: library.rootURL, to: defaults)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        do {
            modules = try await library.installedModules()
            highlightSets = (try? await library.highlightSets()) ?? []
            plans = try await library.readingPlans()
            devotionals = try await library.devotionals()
            quizModules = try await library.quizModules()
            selectedPlanIDs = try await library.selectedPlanIDs()
            let completed = try await library.completedReadings(year: planProgressYear)
            completedReadingIDs = Set(completed.map(\.id))
            let availableTranslations = translations
            if availableTranslations.contains(where: { $0.id == selectedTranslationID }) {
                // Still installed: kept.
            } else if let preferred = defaults.string(forKey: "reader.defaultTranslationID"),
                      availableTranslations.contains(where: { $0.id == preferred }) {
                selectedTranslationID = preferred
            } else if let first = availableTranslations.first {
                selectedTranslationID = first.id
            } else {
                selectedTranslationID = nil
                selectedBookNumber = nil
                books = []
                chapter = nil
                highlightsByReference = [:]
                installedHighlightsByReference = [:]
                noteReferences = []
                installedNotesByReference = [:]
                // Nothing to open — an empty library is a loaded library.
                markInitialContentLoaded()
            }
            if reloadingReader { activeReader?.reload() }
        } catch {
            errorMessage = error.localizedDescription
            markInitialContentLoaded()
        }
        hasReadLibrary = true
        isRefreshing = false
        // Only once the reader is already up. On the launch pass this would
        // start in the same turn that sets `hasReadLibrary`, which is what
        // triggers the reader's restore — see `buildStrongsIndexes`.
        if hasLoadedInitialContent { buildStrongsIndexes() }
    }

    /// Builds the Strong's index for the installed translations, in the
    /// background.
    ///
    /// The translation being read first, then the rest: the one the reader is
    /// in is the one they are most likely to search or analyse next, and the
    /// index is useful per translation rather than only when all of them are
    /// done. Core works a book at a time and yields between books, and reads
    /// verses directly until a translation's index is whole, so searches and
    /// analyses keep working throughout.
    ///
    /// Started once the reader's first chapter is in, not when the library
    /// has been read.
    ///
    /// Even when every index is current, this fingerprints each tagged
    /// translation: it reads every annotations_json row and hashes it, on the
    /// `LampLibrary` actor, and the cache is in memory only so every launch
    /// pays it. Core yields between *books of a build*, so the all-current
    /// path has no suspension point at all — it is one actor job of roughly
    /// 0.15–0.2 s over six translations. Started at `hasReadLibrary`, that
    /// job sits in the same turn that triggers the reader's restore and can
    /// land between its `translationBooks` and `chapterContents` calls,
    /// delaying the first chapter. Timed against clones of a real library's
    /// databases, not a synthetic one, since the cost is in how much
    /// annotation the translations actually carry.
    ///
    /// Later refreshes — an install, the launch sync's own refresh — call it
    /// from `refreshLibrary` as before, by which time the reader is up. Core
    /// rebuilds only what is out of date, so a repeated call costs that
    /// digest check and nothing more.
    private func buildStrongsIndexes() {
        strongsIndexTask?.cancel()
        let library = library
        let reading = selectedTranslationID
        strongsIndexTask = Task.detached(priority: .utility) {
            if let reading {
                try? await library.buildStrongsIndexes(moduleIDs: [reading])
            }
            try? await library.buildStrongsIndexes()
        }
    }

    /// Marked by the reader when its first chapter is in, even when that read
    /// fails: a splash that never leaves is worse than an interface that
    /// opens onto an error.
    func markInitialContentLoaded() {
        guard !hasLoadedInitialContent else { return }
        hasLoadedInitialContent = true
        // The first chapter is in, so the actor is free for the index's
        // fingerprint pass.
        buildStrongsIndexes()
    }

    /// Reads everything a reader shows for one chapter, and changes nothing.
    ///
    /// Separate from the model's own place in scripture on purpose: a reader
    /// window will ask for its own chapter, and the answer must not depend on,
    /// or disturb, where any other reader happens to be. What it needs from
    /// the library beyond the chapter itself — which note and highlight
    /// modules are installed — is library-wide and stays here.
    func chapterContents(
        translationID: String,
        book: Int,
        chapter: Int
    ) async throws -> ReaderChapterContents {
        async let chapterRequest = library.chapter(
            moduleID: translationID,
            bookNumber: book,
            chapterNumber: chapter
        )
        async let highlightsRequest = library.verseHighlights(
            translationID: translationID,
            bookNumber: book,
            chapterNumber: chapter
        )
        async let notesRequest = library.verseNotes(
            bookNumber: book,
            chapterNumber: chapter
        )
        let (loadedChapter, loadedHighlights, loadedNotes) = try await (
            chapterRequest,
            highlightsRequest,
            notesRequest
        )
        var installedNotes: [LampVerseNote] = []
        for notesModule in noteModules {
            installedNotes += (try? await library.moduleVerseNotes(
                moduleID: notesModule.id,
                bookNumber: book,
                chapterNumber: chapter
            )) ?? []
        }
        var installedHighlights: [LampVerseHighlight] = []
        for highlightsModule in highlightModules {
            installedHighlights += (try? await library.moduleVerseHighlights(
                moduleID: highlightsModule.id,
                bookNumber: book,
                chapterNumber: chapter
            )) ?? []
        }
        return ReaderChapterContents(
            chapter: loadedChapter,
            translationID: translationID,
            highlights: loadedHighlights,
            notes: loadedNotes,
            installedHighlights: installedHighlights,
            installedNotes: installedNotes
        )
    }

    /// The reader window being used, which is the one other windows mean.
    ///
    /// The writing editor inserting a verse reference, Slide Studio, the
    /// highlight editor: each asks the library for the current verse, and once
    /// two readers disagree there is no answer in the data. The rule is the
    /// reader last used, and this is where it is kept.
    ///
    /// It also means a reader view that still reads from the library rather
    /// than from its own workspace shows the active window's place, which is
    /// what this app did for every window until now.
    /// The reader window being used, when one is open.
    ///
    /// Held weakly: a window owns its workspace, and the library outlives
    /// every window.
    weak var activeReader: ReaderWorkspace?

    /// A place asked for while no reader was open, for the next one to take.
    private(set) var pendingReaderLocation: ReaderLocation?

    func takePendingReaderLocation() -> ReaderLocation? {
        defer { pendingReaderLocation = nil }
        return pendingReaderLocation
    }

    func adoptActiveReader(
        translationID: String?,
        book: Int?,
        chapter: Int,
        verse: Int?,
        books: [LampTranslationBook],
        contents: ReaderChapterContents
    ) {
        selectedTranslationID = translationID
        selectedBookNumber = book
        selectedChapterNumber = chapter
        selectedVerseReference = verse
        self.books = books
        apply(contents)
        persistLocation()
    }

    /// Takes in what a reader window read for a chapter.
    ///
    /// Highlights and notes stay here rather than going to the window,
    /// because a verse reference is unique across the whole Bible: two windows
    /// on different chapters never collide, and one made in either is seen by
    /// both. A window owning its own copy would mean a highlight made in one
    /// not appearing in the other, and not appearing in the window that made
    /// it until its chapter was read again.
    ///
    /// The chapter's own references are replaced rather than merged, so a
    /// highlight deleted on another device and synced away actually goes.
    func absorbChapterContents(_ contents: ReaderChapterContents) {
        guard let loaded = contents.chapter else { return }
        let first = loaded.book.id * 1_000_000 + loaded.number * 1_000
        let references = first..<(first + 1_000)

        highlightsByReference = highlightsByReference
            .filter { !references.contains($0.key) }
            .merging(contents.highlightsByReference) { _, read in read }
        installedHighlightsByReference = installedHighlightsByReference
            .filter { !references.contains($0.key) }
            .merging(contents.installedHighlightsByReference) { _, read in read }
        installedNotesByReference = installedNotesByReference
            .filter { !references.contains($0.key) }
            .merging(contents.installedNotesByReference) { _, read in read }
        noteReferences = noteReferences
            .filter { !references.contains($0) }
            .union(contents.noteReferences)
    }

    /// Shows what was read for a chapter.
    private func apply(_ contents: ReaderChapterContents) {
        chapter = contents.chapter
        highlightsByReference = contents.highlightsByReference
        installedHighlightsByReference = contents.installedHighlightsByReference
        noteReferences = contents.noteReferences
        installedNotesByReference = contents.installedNotesByReference
    }

    private func persistLocation() {
        defaults.set(selectedTranslationID, forKey: "reader.translationID")
        defaults.set(selectedBookNumber ?? 0, forKey: "reader.bookNumber")
        defaults.set(selectedChapterNumber, forKey: "reader.chapterNumber")
    }

    private var currentReaderLocation: ReaderLocation? {
        guard let translationID = selectedTranslationID,
              let bookNumber = selectedBookNumber else { return nil }
        return ReaderLocation(
            translationID: translationID,
            bookNumber: bookNumber,
            chapterNumber: selectedChapterNumber,
            verseReference: selectedVerseReference
        )
    }

    private func visibleModules(kind: LampModuleKind) -> [LampInstalledModule] {
        LampModuleSelection.visible(
            modules.filter { $0.kind == kind }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            hiddenIDs: hiddenModuleIDs, id: \.id
        )
    }
}
