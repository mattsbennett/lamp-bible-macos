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

    static func inferred(from key: String) -> Self? {
        switch key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().first {
        case "G": .greek
        case "H": .hebrew
        default: nil
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
    @Published private(set) var books: [LampTranslationBook] = []
    @Published private(set) var chapter: LampChapter?
    @Published private(set) var isRefreshing = false
    /// False until the library has been read and the opening chapter is on screen,
    /// so the window can hold a splash rather than assemble itself around empty
    /// states. One-way: later refreshes never send the interface away again.
    @Published private(set) var hasLoadedInitialContent = false
    @Published private(set) var isImporting = false
    @Published private(set) var isImportingStudyData = false
    @Published private(set) var isLoadingChapter = false
    @Published private(set) var isSearching = false
    @Published private(set) var searchResults: [LampTranslationSearchResult] = []
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
    @Published private(set) var planProgressYear = Calendar.current.component(.year, from: Date())
    @Published var errorMessage: String?
    @Published var studyImportMessage: String?

    @Published private(set) var selectedTranslationID: String?
    @Published private(set) var selectedBookNumber: Int?
    @Published private(set) var selectedChapterNumber = 1

    let library: LampLibrary
    private var chapterTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var moduleSearchTask: Task<Void, Never>?
    private var searchToken: UUID?
    private let lexiconMappingStore: LexiconMappingStore
    private let defaults: UserDefaults
    private var navigationHistory: ReaderNavigationHistory
    @Published private(set) var hiddenModuleIDs: Set<String>

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

    var canNavigateBackward: Bool {
        guard let selectedBookNumber,
              let bookIndex = books.firstIndex(where: { $0.id == selectedBookNumber }) else {
            return false
        }
        return selectedChapterNumber > 1 || bookIndex > books.startIndex
    }

    var canNavigateForward: Bool {
        guard let selectedBook,
              let bookIndex = books.firstIndex(where: { $0.id == selectedBook.id }) else {
            return false
        }
        return selectedChapterNumber < selectedBook.chapterCount || bookIndex < books.index(before: books.endIndex)
    }

    var canGoBackInHistory: Bool { navigationHistory.canGoBack }
    var canGoForwardInHistory: Bool { navigationHistory.canGoForward }
    var recentReaderLocations: [ReaderLocation] {
        Array(navigationHistory.backStack.reversed().prefix(20))
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
        self.library = resolvedLibrary
        self.lexiconMappingStore = LexiconMappingStore(library: resolvedLibrary)
        self.defaults = defaults
        if let historyData = defaults.data(forKey: "reader.navigationHistory"),
           let history = try? JSONDecoder().decode(ReaderNavigationHistory.self, from: historyData) {
            navigationHistory = history
        } else {
            navigationHistory = ReaderNavigationHistory()
        }
        hiddenModuleIDs = Set(defaults.stringArray(forKey: "modules.hiddenIDs") ?? [])
        selectedTranslationID = defaults.string(forKey: "reader.translationID")
        let storedBook = defaults.integer(forKey: "reader.bookNumber")
        selectedBookNumber = storedBook > 0 ? storedBook : nil
        selectedChapterNumber = max(defaults.integer(forKey: "reader.chapterNumber"), 1)
    }

    deinit {
        chapterTask?.cancel()
        searchTask?.cancel()
        moduleSearchTask?.cancel()
    }

    func start() {
        guard modules.isEmpty, !isRefreshing else { return }
        Task { await refreshLibrary() }
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
        if hidden, selectedTranslationID == moduleID, let replacement = translations.first {
            selectTranslation(replacement.id)
        }
    }

    func setDefaultTranslation(_ moduleID: String?) {
        defaults.set(moduleID, forKey: "reader.defaultTranslationID")
        if let moduleID { selectTranslation(moduleID) }
    }

    func reloadCurrentChapterStudyData() {
        loadCurrentChapter()
    }

    func install(_ urls: [URL]) {
        let lampURLs = urls.filter { $0.pathExtension.lowercased() == "lamp" }
        guard !lampURLs.isEmpty, !isImporting else {
            if lampURLs.isEmpty {
                errorMessage = LampLibraryError.invalidFileExtension.localizedDescription
            }
            return
        }

        isImporting = true
        errorMessage = nil
        Task {
            var lastInstalledTranslationID: String?
            do {
                for url in lampURLs {
                    let module = try await library.install(from: url)
                    if module.kind == .translation {
                        lastInstalledTranslationID = module.id
                    } else if module.kind == .plan {
                        try await library.setPlanSelected(moduleID: module.id, selected: true)
                    }
                }
                if let lastInstalledTranslationID {
                    selectedTranslationID = lastInstalledTranslationID
                }
                await refreshLibrary()
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

    func openReference(_ encodedReference: Int, translationID: String?) {
        if let translationID,
           translations.contains(where: { $0.id == translationID }) {
            selectedTranslationID = translationID
        }
        openReference(encodedReference)
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
                    studyImportMessage = "Imported \(importedCount) Markdown devotional\(importedCount == 1 ? "" : "s")."
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

    func selectTranslation(_ moduleID: String) {
        guard selectedTranslationID != moduleID || books.isEmpty else { return }
        selectedTranslationID = moduleID
        selectedBookNumber = nil
        selectedChapterNumber = 1
        selectedVerseReference = nil
        persistLocation()
        loadTranslation(moduleID)
    }

    func selectBook(_ bookNumber: Int) {
        guard selectedBookNumber != bookNumber || chapter == nil else { return }
        selectedBookNumber = bookNumber
        selectedChapterNumber = 1
        selectedVerseReference = nil
        recordCurrentLocation()
        persistLocation()
        loadCurrentChapter()
    }

    func selectChapter(_ chapterNumber: Int) {
        guard chapterNumber > 0 else { return }
        selectedChapterNumber = chapterNumber
        selectedVerseReference = nil
        recordCurrentLocation()
        persistLocation()
        loadCurrentChapter()
    }

    func selectPassage(
        translationID: String,
        bookNumber: Int,
        chapterNumber: Int
    ) {
        guard !translationID.isEmpty, bookNumber > 0, chapterNumber > 0 else { return }
        guard selectedTranslationID != translationID
                || selectedBookNumber != bookNumber
                || selectedChapterNumber != chapterNumber else { return }

        let translationChanged = selectedTranslationID != translationID
        selectedTranslationID = translationID
        selectedBookNumber = bookNumber
        selectedChapterNumber = chapterNumber
        selectedVerseReference = nil
        recordCurrentLocation()
        persistLocation()

        if translationChanged || !books.contains(where: { $0.id == bookNumber }) {
            loadTranslation(translationID)
        } else {
            loadCurrentChapter()
        }
    }

    func navigateBackward() {
        guard let selectedBookNumber,
              let bookIndex = books.firstIndex(where: { $0.id == selectedBookNumber }) else { return }
        if selectedChapterNumber > 1 {
            selectedChapterNumber -= 1
        } else if bookIndex > books.startIndex {
            let previousBook = books[books.index(before: bookIndex)]
            self.selectedBookNumber = previousBook.id
            selectedChapterNumber = previousBook.chapterCount
        }
        selectedVerseReference = nil
        recordCurrentLocation()
        persistLocation()
        loadCurrentChapter()
    }

    func navigateForward() {
        guard let selectedBookNumber,
              let bookIndex = books.firstIndex(where: { $0.id == selectedBookNumber }) else { return }
        let book = books[bookIndex]
        if selectedChapterNumber < book.chapterCount {
            selectedChapterNumber += 1
        } else if bookIndex < books.index(before: books.endIndex) {
            let nextBook = books[books.index(after: bookIndex)]
            self.selectedBookNumber = nextBook.id
            selectedChapterNumber = 1
        }
        selectedVerseReference = nil
        recordCurrentLocation()
        persistLocation()
        loadCurrentChapter()
    }

    func search(_ query: String, translationID: String? = nil) {
        searchTask?.cancel()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            searchToken = nil
            searchResults = []
            isSearching = false
            return
        }

        let token = UUID()
        searchToken = token
        isSearching = true
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let moduleIDs = translationID.map { Set([$0]) } ?? Set(translations.map(\.id))
                let results = try await library.searchTranslations(
                    query: trimmedQuery,
                    moduleIDs: moduleIDs,
                    limit: 150
                )
                guard !Task.isCancelled, searchToken == token else { return }
                searchResults = results
            } catch is CancellationError {
                return
            } catch {
                guard searchToken == token else { return }
                errorMessage = error.localizedDescription
                searchResults = []
            }
            if searchToken == token {
                isSearching = false
            }
        }
    }

    func searchModules(
        _ query: String,
        kind: LampModuleKind? = nil,
        moduleID: String? = nil
    ) {
        moduleSearchTask?.cancel()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            moduleSearchResults = []
            isModuleSearching = false
            return
        }
        isModuleSearching = true
        moduleSearchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let results = try await library.searchModules(
                    query: trimmedQuery,
                    kinds: kind.map { Set([$0]) },
                    moduleIDs: moduleID.map { Set([$0]) }
                        ?? Set(modules.filter { !hiddenModuleIDs.contains($0.id) }.map(\.id)),
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

    func openSearchResult(_ result: LampTranslationSearchResult) {
        selectedTranslationID = result.translationID
        selectedBookNumber = result.bookNumber
        selectedChapterNumber = result.chapterNumber
        selectedVerseReference = result.reference
        recordCurrentLocation()
        persistLocation()
        loadTranslation(result.translationID)
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

    func highlights(for reference: Int) -> [LampVerseHighlight] {
        (installedHighlightsByReference[reference] ?? [])
            + (highlightsByReference[reference] ?? [])
    }

    func personalHighlights(for reference: Int) -> [LampVerseHighlight] {
        highlightsByReference[reference] ?? []
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
        try await library.deleteVerseHighlights(
            setID: setID,
            reference: reference
        )
        let retainedHighlights = (highlightsByReference[reference] ?? [])
            .filter { $0.setID != setID }
        if let color {
            let highlight = try await library.saveVerseHighlight(
                translationID: translationID,
                reference: reference,
                startOffset: 0,
                endOffset: textLength,
                color: color
            )
            guard selectedTranslationID == translationID else { return }
            highlightsByReference[reference] = retainedHighlights + [highlight]
        } else {
            guard selectedTranslationID == translationID else { return }
            if retainedHighlights.isEmpty {
                highlightsByReference.removeValue(forKey: reference)
            } else {
                highlightsByReference[reference] = retainedHighlights
            }
        }
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

    func deleteVerseHighlight(id: Int64, reference: Int) async throws {
        try await library.deleteVerseHighlight(id: id)
        highlightsByReference[reference]?.removeAll { $0.id == id }
        if highlightsByReference[reference]?.isEmpty == true {
            highlightsByReference.removeValue(forKey: reference)
        }
    }

    func openReading(_ reading: LampPlanReading) {
        openReference(reading.startReference)
    }

    func openReference(_ encodedReference: Int) {
        guard let translationID = selectedTranslationID ?? translations.first?.id else {
            errorMessage = "Install a translation before opening this scripture reference."
            return
        }
        let reference = LampBibleReferenceFormatter.components(of: encodedReference)
        selectedTranslationID = translationID
        selectedBookNumber = reference.book
        selectedChapterNumber = reference.chapter
        selectedVerseReference = encodedReference
        recordCurrentLocation()
        persistLocation()
        loadTranslation(translationID)
    }

    func goBackInHistory() {
        guard let location = navigationHistory.goBack() else { return }
        applyHistoryLocation(location)
    }

    func goForwardInHistory() {
        guard let location = navigationHistory.goForward() else { return }
        applyHistoryLocation(location)
    }

    func openHistoryLocation(_ location: ReaderLocation) {
        navigationHistory.visit(location)
        applyHistoryLocation(location)
    }

    /// Restores a tab without treating the tab switch as a new reading-history
    /// visit. Navigation performed inside the tab continues to use normal history.
    func openReaderTabLocation(_ location: ReaderLocation) {
        applyHistoryLocation(location)
    }

    func clearNavigationHistory() {
        navigationHistory.clear(keeping: currentReaderLocation)
        persistNavigationHistory()
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
        return saved
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
        let id = "\(planID)_\(day)_r\(readingIndex)_\(year)"
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
        let id = "\(planID)_\(day)_r\(readingIndex)_\(year)"
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

    private func refreshLibrary() async {
        isRefreshing = true
        errorMessage = nil
        do {
            modules = try await library.installedModules()
            plans = try await library.readingPlans()
            devotionals = try await library.devotionals()
            quizModules = try await library.quizModules()
            selectedPlanIDs = try await library.selectedPlanIDs()
            let completed = try await library.completedReadings(year: planProgressYear)
            completedReadingIDs = Set(completed.map(\.id))
            let availableTranslations = translations
            if let selectedTranslationID,
               availableTranslations.contains(where: { $0.id == selectedTranslationID }) {
                loadTranslation(selectedTranslationID)
            } else if let preferred = defaults.string(forKey: "reader.defaultTranslationID"),
                      availableTranslations.contains(where: { $0.id == preferred }) {
                selectedTranslationID = preferred
                loadTranslation(preferred)
            } else if let first = availableTranslations.first {
                selectedTranslationID = first.id
                loadTranslation(first.id)
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
        } catch {
            errorMessage = error.localizedDescription
            markInitialContentLoaded()
        }
        isRefreshing = false
    }

    /// Marked even when a chapter load is cancelled or fails: a splash that never
    /// leaves is worse than an interface that opens onto an error.
    private func markInitialContentLoaded() {
        guard !hasLoadedInitialContent else { return }
        hasLoadedInitialContent = true
    }

    private func loadTranslation(_ moduleID: String) {
        chapterTask?.cancel()
        isLoadingChapter = true
        chapterTask = Task {
            do {
                let loadedBooks = try await library.translationBooks(moduleID: moduleID)
                guard !Task.isCancelled, selectedTranslationID == moduleID else { return }
                books = loadedBooks
                let selected = loadedBooks.first { $0.id == selectedBookNumber } ?? loadedBooks.first
                selectedBookNumber = selected?.id
                if let selected {
                    selectedChapterNumber = min(max(selectedChapterNumber, 1), selected.chapterCount)
                    recordCurrentLocation()
                    try await loadChapter(moduleID: moduleID, book: selected.id, chapter: selectedChapterNumber)
                } else {
                    chapter = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                chapter = nil
            }
            if !Task.isCancelled { isLoadingChapter = false }
            markInitialContentLoaded()
        }
    }

    private func loadCurrentChapter() {
        guard let moduleID = selectedTranslationID, let book = selectedBookNumber else { return }
        chapterTask?.cancel()
        isLoadingChapter = true
        chapterTask = Task {
            do {
                try await loadChapter(moduleID: moduleID, book: book, chapter: selectedChapterNumber)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                chapter = nil
            }
            if !Task.isCancelled { isLoadingChapter = false }
            markInitialContentLoaded()
        }
    }

    private func loadChapter(moduleID: String, book: Int, chapter: Int) async throws {
        async let chapterRequest = library.chapter(
            moduleID: moduleID,
            bookNumber: book,
            chapterNumber: chapter
        )
        async let highlightsRequest = library.verseHighlights(
            translationID: moduleID,
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
            let moduleHighlights = (try? await library.moduleVerseHighlights(
                moduleID: highlightsModule.id,
                bookNumber: book,
                chapterNumber: chapter
            )) ?? []
            installedHighlights += moduleHighlights.filter { $0.translationID == moduleID }
        }
        guard !Task.isCancelled,
              selectedTranslationID == moduleID,
              selectedBookNumber == book,
              selectedChapterNumber == chapter else { return }
        self.chapter = loadedChapter
        highlightsByReference = Dictionary(grouping: loadedHighlights, by: \.reference)
        installedHighlightsByReference = Dictionary(grouping: installedHighlights, by: \.reference)
        noteReferences = Set(
            loadedNotes
                .filter { $0.moduleID == "personal-notes" }
                .map(\.reference)
        )
        installedNotesByReference = Dictionary(grouping: installedNotes, by: \.reference)
        persistLocation()
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

    private func recordCurrentLocation() {
        guard let location = currentReaderLocation else { return }
        navigationHistory.visit(location)
        persistNavigationHistory()
    }

    private func applyHistoryLocation(_ location: ReaderLocation) {
        selectedTranslationID = location.translationID
        selectedBookNumber = location.bookNumber
        selectedChapterNumber = location.chapterNumber
        selectedVerseReference = location.verseReference
        persistNavigationHistory()
        persistLocation()
        loadTranslation(location.translationID)
    }

    private func persistNavigationHistory() {
        if let data = try? JSONEncoder().encode(navigationHistory) {
            defaults.set(data, forKey: "reader.navigationHistory")
        }
    }

    private func visibleModules(kind: LampModuleKind) -> [LampInstalledModule] {
        return modules
            .filter { $0.kind == kind && !hiddenModuleIDs.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
