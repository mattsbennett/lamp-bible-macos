import Foundation
import LampCore
import LampModuleKit

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
    @Published private(set) var selectedVerseReference: Int?
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
    private var searchToken: UUID?
    private let defaults: UserDefaults

    var translations: [LampInstalledModule] {
        modules.filter { $0.kind == .translation }
    }

    var dictionaries: [LampInstalledModule] {
        modules.filter { $0.kind == .dictionary }
    }

    var commentaries: [LampInstalledModule] {
        modules.filter { $0.kind == .commentary }
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
        selectedTranslationID = defaults.string(forKey: "reader.translationID")
        let storedBook = defaults.integer(forKey: "reader.bookNumber")
        selectedBookNumber = storedBook > 0 ? storedBook : nil
        selectedChapterNumber = max(defaults.integer(forKey: "reader.chapterNumber"), 1)
    }

    deinit {
        chapterTask?.cancel()
        searchTask?.cancel()
    }

    func start() {
        guard modules.isEmpty, !isRefreshing else { return }
        Task { await refreshLibrary() }
    }

    func refresh() {
        Task { await refreshLibrary() }
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
        persistLocation()
        loadCurrentChapter()
    }

    func selectChapter(_ chapterNumber: Int) {
        guard chapterNumber > 0 else { return }
        selectedChapterNumber = chapterNumber
        selectedVerseReference = nil
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
                let moduleIDs = translationID.map { Set([$0]) }
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

    func openSearchResult(_ result: LampTranslationSearchResult) {
        selectedTranslationID = result.translationID
        selectedBookNumber = result.bookNumber
        selectedChapterNumber = result.chapterNumber
        selectedVerseReference = result.reference
        persistLocation()
        loadTranslation(result.translationID)
    }

    func focusVerse(_ reference: Int?) {
        selectedVerseReference = reference
    }

    func highlights(for reference: Int) -> [LampVerseHighlight] {
        (installedHighlightsByReference[reference] ?? [])
            + (highlightsByReference[reference] ?? [])
    }

    func personalHighlights(for reference: Int) -> [LampVerseHighlight] {
        guard let selectedTranslationID else { return [] }
        let setID = "personal-highlights:\(selectedTranslationID)"
        return (highlightsByReference[reference] ?? []).filter { $0.setID == setID }
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
        content: String
    ) async throws {
        let note = try await library.setPersonalVerseNote(
            reference: reference,
            title: title,
            content: content
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
        persistLocation()
        loadTranslation(translationID)
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
}
