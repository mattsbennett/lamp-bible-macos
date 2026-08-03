import Foundation
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampModuleKit

struct DictionaryLookupRequest: Equatable {
    let id = UUID()
    let keys: [String]
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var modules: [LampInstalledModule] = []
    @Published private(set) var books: [LampTranslationBook] = []
    @Published private(set) var chapter: LampChapter?
    @Published private(set) var isRefreshing = false
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
    private let defaults: UserDefaults
    private var navigationHistory: ReaderNavigationHistory
    @Published private(set) var hiddenModuleIDs: Set<String>
    @Published private(set) var moduleOrder: [String]

    var allTranslations: [LampInstalledModule] {
        modules.filter { $0.kind == .translation }
    }

    var translations: [LampInstalledModule] {
        visibleOrderedModules(kind: .translation)
    }

    var dictionaries: [LampInstalledModule] {
        visibleOrderedModules(kind: .dictionary)
    }

    var commentaries: [LampInstalledModule] {
        visibleOrderedModules(kind: .commentary)
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

    init(
        library: LampLibrary? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.library = library ?? LampLibrary(
            bundledModulesArchiveURL: Bundle.main.url(
                forResource: "bundled_modules.db",
                withExtension: "zlib"
            )
        )
        self.defaults = defaults
        if let historyData = defaults.data(forKey: "reader.navigationHistory"),
           let history = try? JSONDecoder().decode(ReaderNavigationHistory.self, from: historyData) {
            navigationHistory = history
        } else {
            navigationHistory = ReaderNavigationHistory()
        }
        hiddenModuleIDs = Set(defaults.stringArray(forKey: "modules.hiddenIDs") ?? [])
        moduleOrder = defaults.stringArray(forKey: "modules.order") ?? []
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

    func moveModule(_ moduleID: String, direction: Int) {
        var order = moduleOrder
        for id in modules.map(\.id) where !order.contains(id) { order.append(id) }
        guard let index = order.firstIndex(of: moduleID) else { return }
        let destination = index + direction
        guard order.indices.contains(destination) else { return }
        order.swapAt(index, destination)
        moduleOrder = order
        defaults.set(order, forKey: "modules.order")
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

    func requestDictionaryLookup(keys: [String]) {
        let normalizedKeys = keys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
        guard !normalizedKeys.isEmpty else { return }
        dictionaryLookupRequest = DictionaryLookupRequest(keys: normalizedKeys)
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
        let completed = !completedReadingIDs.contains(id)
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
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isRefreshing = false
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

    private func visibleOrderedModules(kind: LampModuleKind) -> [LampInstalledModule] {
        let positions = Dictionary(uniqueKeysWithValues: moduleOrder.enumerated().map { ($1, $0) })
        return modules
            .filter { $0.kind == kind && !hiddenModuleIDs.contains($0.id) }
            .sorted {
                let left = positions[$0.id] ?? Int.max
                let right = positions[$1.id] ?? Int.max
                if left != right { return left < right }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
}
