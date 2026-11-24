import AppKit
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

    /// The dictionaries this language falls back to when the reader has chosen
    /// none, ahead of the library's by-name order. Shared with iOS through core
    /// so the two apps cannot drift apart on which dictionary a default means.
    var preferredDictionaryIDs: [String] {
        switch self {
        case .greek: LampModuleSelection.preferredGreekDictionaryIDs
        case .hebrew: []
        }
    }
}

extension LampInstalledModule {
    var biblicalOriginalLanguage: BiblicalOriginalLanguage? {
        switch LampTranslationLanguages.strongsSide(of: language) {
        case .greek: return .greek
        case .hebrew: return .hebrew
        case nil: break
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
    /// Each translation's own book names, by translation and book number,
    /// read with the modules: a Spanish translation's Génesis rather than
    /// the app's Genesis.
    @Published private(set) var translationBookNames: [String: [Int: String]] = [:]
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
    @Published var pendingWritingImport: PendingWritingImport?
    @Published var translationUnlockRequest: TranslationUnlockRequest?
    @Published var translationImportMessage: String?
    /// What the last install of finished modules did, for the pane whose
    /// button started it to show. Installing used to succeed in silence.
    @Published var moduleInstallMessage: String?
    @Published private(set) var isImportingStudyData = false
    @Published private(set) var moduleSearchResults: [LampModuleSearchResult] = []
    /// The kinds that found more than the search across every kind kept of
    /// them: Search offers "More in …" for these, which searches that kind
    /// alone. Not how many more; core doesn't count past its limit.
    @Published private(set) var moduleSearchKindsWithMore: Set<LampModuleKind> = []
    /// The kinds cut short in what was shown — a "+" on their count. Not the
    /// same as offering more: Scripture from one translation offers the other
    /// translations, but that translation's own verses may all be there.
    @Published private(set) var moduleSearchCutKinds: Set<LampModuleKind> = []
    /// Where the search across every kind took Scripture from: the reading
    /// translation, or the one with the most matches where it had none.
    @Published private(set) var moduleSearchScripture: ModuleSearchScripture?
    @Published private(set) var isModuleSearching = false
    /// The last few searches and what they found, most recent last.
    private var recentModuleSearches: [(request: ModuleSearchRequest, answer: ModuleSearchAnswer)] = []
    @Published private(set) var selectedVerseReference: Int?
    @Published private(set) var dictionaryLookupRequest: DictionaryLookupRequest?
    @Published private(set) var highlightsByReference: [Int: [LampVerseHighlight]] = [:]
    @Published private(set) var installedHighlightsByReference: [Int: [LampVerseHighlight]] = [:]
    @Published private(set) var noteReferences: Set<Int> = []
    /// The chapter read last taken into the sets here: see `adoptActiveReader`.
    private var lastAbsorbedContents = ReaderChapterContents.empty
    @Published private(set) var installedNotesByReference: [Int: [LampVerseNote]] = [:]
    @Published private(set) var plans: [LampReadingPlan] = []
    @Published private(set) var devotionals: [LampDevotional] = []
    /// Bumped whenever `devotionals` changes, so a view that works something
    /// out from the list off the main actor can tell whether its answer is
    /// still about the list in hand. A count and a newest date would nearly
    /// do; nearly is how a stale list gets shown.
    @Published private(set) var devotionalsRevision = 0
    @Published private(set) var quizModules: [LampQuizModule] = []
    @Published private(set) var selectedPlanIDs: Set<String> = []
    @Published private(set) var completedReadingIDs: Set<String> = []
    @Published private(set) var planProgressYear = LampPlanCalendar.year(for: Date())
    /// What the last take-in of plans asked for in other apps did, for the
    /// plans views to show. Nil when there is nothing to say.
    @Published var addedPlanMessage: String?
    /// What the last take-in of writings asked for in other apps did, for
    /// the Writing section to show. Nil when there is nothing to say. A
    /// writing started from a reader chat is shown in that chat instead.
    @Published var startedWritingMessage: String?
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
    /// Where the reader's place is kept: apart from the standard defaults,
    /// since a write there wakes every view that reads a setting, and the
    /// place changes with every chapter turned and every tab chosen.
    private let locationDefaults: UserDefaults
    /// The hidden modules, as the question is asked of what is installed.
    ///
    /// Distinct from what is stored. A hidden ID is never rewritten — it
    /// stays "ESVs" in settings, which sync shares with devices that still
    /// call it that — but the question asked of it resolves: hide the module
    /// whose own ID is hidden, and the module a hidden ID resolves to once
    /// that ID is gone. Resolved here, once, because five places test this
    /// set with an exact `contains`, and the alternative was fixing each of
    /// them and forgetting one, leaving a module the reader had hidden to
    /// reappear after the rename.
    @Published private(set) var hiddenModuleIDs: Set<String>
    /// The hidden list exactly as settings hold it, which is what is written
    /// back and what sync carries.
    private var storedHiddenModuleIDs: Set<String>
    /// The background index build, cancelled when the library is read again
    /// so two refreshes do not index at once.
    private var strongsIndexTask: Task<Void, Never>?

    var translations: [LampInstalledModule] {
        visibleModules(kind: .translation)
    }

    /// Every installed translation, hidden ones included.
    ///
    /// This, not `translations`, is what a stored ID is resolved against. A
    /// rename asks "which installed module did this name?", and hiding one
    /// does not uninstall it: resolving against the visible ones made a
    /// hidden "ESVs" look gone, so a link or a tab naming it opened the
    /// separately installed "ESV" — another module's text, silently.
    /// Visibility is a question to ask afterwards, of the module found.
    var installedTranslationIDs: [String] {
        modules.filter { $0.kind == .translation }.map(\.id)
    }

    /// `book` as the translation names it, for a place named away from its
    /// text, as a tab or a history entry names it; the app's own name for
    /// a translation not yet read or one without that book.
    func bookName(_ book: Int, in translationID: String?) -> String {
        translationID.flatMap { translationBookNames[$0]?[book] }
            ?? LampBibleReferenceFormatter.bookName(book)
    }

    /// A translation that has `book`, for a reader sent to it in one that
    /// doesn't: one in the same language as `translationID` first, then the
    /// first listed.
    func translation(having book: Int, near translationID: String?) -> LampInstalledModule? {
        LampTranslationCoverage.alternative(
            having: book,
            near: translations.first { $0.id == translationID }?.language,
            among: translations.filter { $0.id != translationID },
            language: \.language,
            covers: { translationBookNames[$0.id]?[book] != nil }
        )
    }

    /// A translation's own book names, by number, for reading or naming a
    /// passage in it; none for a translation not yet read.
    func bookNames(of translationID: String?) -> [Int: String] {
        translationID.flatMap { translationBookNames[$0] } ?? [:]
    }

    /// "Génesis 1:1": one verse, its book as the translation names it.
    func describeVerse(_ reference: Int, in translationID: String?) -> String {
        let place = LampBibleReferenceFormatter.components(of: reference)
        return "\(bookName(place.book, in: translationID)) \(place.chapter):\(place.verse)"
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
        let locationDefaults = defaults === UserDefaults.standard
            ? Self.locationStore(adoptingFrom: defaults)
            : defaults
        self.locationDefaults = locationDefaults
        let storedHidden = Set(defaults.stringArray(forKey: "modules.hiddenIDs") ?? [])
        storedHiddenModuleIDs = storedHidden
        // Nothing is installed yet to resolve against; `resolveHiddenModules`
        // runs when the modules arrive.
        hiddenModuleIDs = storedHidden
        selectedTranslationID = locationDefaults.string(forKey: "reader.translationID")
        let storedBook = locationDefaults.integer(forKey: "reader.bookNumber")
        selectedBookNumber = storedBook > 0 ? storedBook : nil
        selectedChapterNumber = max(locationDefaults.integer(forKey: "reader.chapterNumber"), 1)
        errorMessage = settingsRecoveryError?.localizedDescription
        // Before any window draws, so a library that uses AI never shows a
        // moment without it; then whenever the preferences change, however
        // they changed — Settings, a sync from another device, an older
        // Lamp dropping the key — with or without a window open.
        settleAIFeatures()
        aiFeaturesObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.aiPreferencesChanged() }
        }
        // An agent outside Lamp asks for an import while the person is in
        // that app; coming back to Lamp is when they can review it.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.takeInRequestedWritingImport() }
            }
        }
        readerTurnObserver = NotificationCenter.default.addObserver(
            forName: .lampReaderChatTurnFinished, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.takeInRequestedWritings() }
            }
        }
    }

    deinit {
        searchTask?.cancel()
        moduleSearchTask?.cancel()
        aiSettleTask?.cancel()
        if let aiFeaturesObserver { NotificationCenter.default.removeObserver(aiFeaturesObserver) }
        if let readerTurnObserver { NotificationCenter.default.removeObserver(readerTurnObserver) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    /// Reads the library for the first time. No reader is open yet to read
    /// a chapter again: each window reads its own once this is done.
    func start() {
        guard modules.isEmpty, !isRefreshing else { return }
        Task {
            await refreshLibrary(reloadingReader: false)
            await takeInRequestedReadingPlans()
            await takeInRequestedWritings()
        }
    }

    func refresh() {
        Task { await refreshLibrary() }
    }

    /// `refresh`, for a caller that goes on only once the library is read
    /// again: a paired phone's turn on a writing sync has just brought in.
    ///
    /// Including the part a launch does not wait for — the writings, the
    /// quizzes, the other translations' book names — because "read again" has
    /// to mean read. A test caught this the day the deferral landed: the
    /// caller here is a writing arriving from the phone, and it is the
    /// writings it is waiting for.
    func refreshNow() async {
        await refreshLibrary()
        await restOfTheLibrary?.value
    }

    /// Whether the AI features are shown, working it out where nothing is
    /// stored (`AIFeatures`), so a value an older Lamp dropped from the
    /// shared preferences is worked out again rather than read as off.
    ///
    /// Acts on each change of it, from whichever direction: off withdraws
    /// what an outside app may read; on again offers it once more, as the
    /// settings say. Neither waits for a window or the Settings pane.
    @discardableResult
    func settleAIFeatures() -> Bool {
        let enabled = AIFeatures.settleIfUnset(libraryRootURL: library.rootURL, defaults: defaults)
        guard enabled != lastAIFeaturesEnabled else { return enabled }
        let isFirst = lastAIFeaturesEnabled == nil
        lastAIFeaturesEnabled = enabled
        if !enabled {
            AgentModuleAccessPreferences.withdrawIfPublished(libraryRootURL: library.rootURL)
        } else if !isFirst {
            republishAgentAccess()
        }
        return enabled
    }

    /// The switch as last worked out; nil until it first is.
    private var lastAIFeaturesEnabled: Bool?
    private var aiFeaturesObserver: NSObjectProtocol?
    private var readerTurnObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    /// An agent's writing import is being planned for review.
    private var isTakingInWritingImport = false
    /// When this run of Lamp began, which says whether a reply that asked
    /// for a writing can still finish: one from an earlier run cannot.
    private let launchedAt = Date()
    /// A take-in of writings is under way, and whether another was asked for
    /// meanwhile. Take-ins are run one at a time: two at once could each see
    /// the same request waiting, and both start it.
    private var isTakingInWritings = false
    private var takeInWritingsAgain = false
    /// Bumped whenever a writing is started from a reader chat, for a chat
    /// pane to read its list again.
    @Published private(set) var startedWritingsRevision = 0
    private var aiSettleTask: Task<Void, Never>?

    /// Preferences change often (a reader's place, a text size), so the
    /// switch is settled on the next turn, once for a burst of changes.
    private func aiPreferencesChanged() {
        guard aiSettleTask == nil else { return }
        aiSettleTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.aiSettleTask = nil
            self.settleAIFeatures()
        }
    }

    /// Offers outside apps what the AI settings allow, as Settings would on
    /// showing its pane: for AI features turned on from somewhere else.
    private func republishAgentAccess() {
        let accessEnabled = defaults.object(forKey: "agent.moduleAccess.enabled") as? Bool ?? true
        let scope = defaults.string(forKey: "agent.moduleAccess.scope")
            .flatMap(AgentModuleAccessScope.init(rawValue:)) ?? .enabledModules
        try? AgentModuleAccessPreferences.publish(
            AgentModuleAccessPreferences.policy(
                isEnabled: accessEnabled,
                scope: scope,
                includesPersonalContent: defaults.bool(forKey: "agent.moduleAccess.personal"),
                modules: modules,
                hiddenModuleIDs: hiddenModuleIDs
            ),
            libraryRootURL: library.rootURL,
            bundledModulesArchiveURL: Bundle.main.url(forResource: "bundled_modules.db", withExtension: "zlib"),
            allowsExternalApps: defaults.bool(forKey: AgentModuleAccessPreferences.allowsExternalAppsKey),
            allowsExternalWriting: defaults.bool(forKey: AgentModuleAccessPreferences.allowsExternalWritingKey),
            allowsExternalReadingPlans: defaults.bool(forKey: AgentModuleAccessPreferences.allowsExternalReadingPlansKey),
            allowsWritingStarts: defaults.bool(forKey: AgentModuleAccessPreferences.allowsWritingStartsKey)
        )
    }

    /// Asks the stored hidden list about the modules actually installed.
    private func resolveHiddenModules() {
        let installedIDs = modules.map(\.id)
        let resolved = Set(storedHiddenModuleIDs.compactMap {
            LampTranslationID.held($0, among: installedIDs)
        })
        if resolved != hiddenModuleIDs { hiddenModuleIDs = resolved }
    }

    func setModuleHidden(_ moduleID: String, hidden: Bool) {
        // The ID of the module the reader picked, which is an installed one,
        // and every spelling of it that was hidden before: unhiding has to
        // clear the old spelling too, or the module stays hidden by a name
        // nothing shows any more.
        if hidden {
            storedHiddenModuleIDs.insert(moduleID)
        } else {
            // Every stored spelling that names THIS module, which is not
            // every spelling: with both ESVs and ESV installed they are two
            // modules, and unhiding one must leave the other hidden.
            let installed = installedTranslationIDs
            storedHiddenModuleIDs = storedHiddenModuleIDs.filter { stored in
                LampTranslationID.held(stored, among: installed) != moduleID
            }
        }
        defaults.set(Array(storedHiddenModuleIDs).sorted(), forKey: "modules.hiddenIDs")
        resolveHiddenModules()
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

    /// Reads the chosen Markdown files or folders and plans their import,
    /// for the review sheet. Nothing is written here.
    func planWritingImport(_ urls: [URL]) {
        // Not over an import already waiting to be chosen, an agent's
        // included: it would replace that one's sheet.
        guard !urls.isEmpty, !isImportingStudyData, pendingWritingImport == nil else { return }
        isImportingStudyData = true
        errorMessage = nil
        studyImportMessage = nil
        Task {
            do {
                let files = try await Task.detached {
                    try urls.flatMap { url in
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        return try LampWritingImport.files(at: url)
                    }
                }.value
                guard !files.isEmpty else {
                    throw LampLibraryError.invalidPersonalContent("There are no Markdown files there.")
                }
                let plan = try await library.planWritingImport(files)
                pendingWritingImport = PendingWritingImport(
                    sourceName: urls.count == 1
                        ? urls[0].lastPathComponent
                        : "\(urls.count) Items",
                    plan: plan
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isImportingStudyData = false
        }
    }

    func applyWritingImport(_ pending: PendingWritingImport, selecting itemIDs: Set<String>) {
        guard !itemIDs.isEmpty else { return }
        isImportingStudyData = true
        Task {
            do {
                let result = try await LampWritingImport.apply(
                    pending.plan, selecting: itemIDs, to: LampMacWritingImportStore(library: library)
                )
                decideWritingImportRequest(pending, outcome: .init(
                    requestID: pending.requestID ?? "",
                    imported: result.imported.map(\.path),
                    refused: result.refused.map(\.path),
                    cancelled: false,
                    failed: Dictionary(
                        result.failed.map { ($0.item.path, $0.reason) }, uniquingKeysWith: { first, _ in first }
                    )
                ))
                if let applicationSupportURL = LampAgentDescriptorStore.defaultApplicationSupportURL() {
                    try? LampWritingImportUndoHistory.record(
                        result.undo, sourceName: pending.sourceName,
                        inApplicationSupport: applicationSupportURL
                    )
                    refreshWritingImportUndo(applicationSupportURL: applicationSupportURL)
                }
                await refreshLibrary()
                let count = result.imported.filter { $0.kind == .writing }.count
                let decks = result.imported.count - count
                var message = "Imported \(count) writing\(count == 1 ? "" : "s")"
                    + (decks == 0 ? "." : " and \(decks) deck\(decks == 1 ? "" : "s").")
                if !result.refused.isEmpty {
                    message += " \(result.refused.count) changed in Lamp while you were choosing and \(result.refused.count == 1 ? "was" : "were") left as \(result.refused.count == 1 ? "it was" : "they were"); import again to see them."
                }
                if !result.problems.isEmpty {
                    message += " " + result.problems.joined(separator: " ")
                }
                if !result.failed.isEmpty {
                    message += " Not imported: " + result.failed
                        .map { "\($0.item.title) (\($0.reason))" }.joined(separator: "; ") + "."
                }
                studyImportMessage = message
            } catch {
                errorMessage = error.localizedDescription
            }
            isImportingStudyData = false
            await showNextWritingImport()
        }
    }

    /// The import Undo Last Import would undo, if any.
    @Published private(set) var lastWritingImport: LampWritingImportUndoHistory.Entry?

    func refreshWritingImportUndo(
        applicationSupportURL: URL? = LampAgentDescriptorStore.defaultApplicationSupportURL()
    ) {
        lastWritingImport = applicationSupportURL.flatMap {
            LampWritingImportUndoHistory.entries(inApplicationSupport: $0).first
        }
    }

    /// Undoes the most recent writing import: what it made goes, what it
    /// changed is put back, and anything changed since is left and named.
    func undoLastWritingImport(
        applicationSupportURL: URL? = LampAgentDescriptorStore.defaultApplicationSupportURL()
    ) {
        guard let applicationSupportURL, let entry = lastWritingImport, !isImportingStudyData else { return }
        isImportingStudyData = true
        studyImportMessage = nil
        Task {
            do {
                let result = try await LampWritingImport.undo(
                    entry.undo, in: LampMacWritingImportStore(library: library)
                )
                LampWritingImportUndoHistory.forget(id: entry.id, inApplicationSupport: applicationSupportURL)
                try? LampWritingImportUndoHistory.carry(
                    restored: result.restored, inApplicationSupport: applicationSupportURL
                )
                refreshWritingImportUndo(applicationSupportURL: applicationSupportURL)
                await refreshLibrary()
                var message = "Undid the import from \(entry.sourceName): \(result.undone.count) taken away or put back as before."
                if !result.kept.isEmpty {
                    message += " Left as \(result.kept.count == 1 ? "it is" : "they are"), changed since: \(result.kept.joined(separator: ", "))."
                }
                studyImportMessage = message
            } catch {
                errorMessage = error.localizedDescription
            }
            isImportingStudyData = false
        }
    }

    func cancelWritingImport(_ pending: PendingWritingImport) {
        decideWritingImportRequest(pending, outcome: .init(
            requestID: pending.requestID ?? "", imported: [], refused: [], cancelled: true
        ))
        Task { await showNextWritingImport() }
    }

    /// Once an import is decided and written, the next one waiting, if any.
    /// A moment after, so the sheet just closed has gone before the next
    /// one is presented.
    private func showNextWritingImport() async {
        try? await Task.sleep(for: .milliseconds(400))
        await takeInRequestedWritingImport()
    }

    /// Leaves what the person chose for the agent that asked.
    private func decideWritingImportRequest(
        _ pending: PendingWritingImport,
        outcome: LampWritingImportRequests.Outcome,
        applicationSupportURL: URL? = LampAgentDescriptorStore.defaultApplicationSupportURL()
    ) {
        guard pending.requestID != nil, let applicationSupportURL else { return }
        do {
            try LampWritingImportRequests.decide(outcome, inApplicationSupport: applicationSupportURL)
        } catch {
            errorMessage = "Could not record the writing import\u{2019}s review: \(error.localizedDescription)"
        }
    }

    /// Shows the oldest writing import an agent has asked for, for review.
    /// One at a time, and never over an import the person is choosing.
    /// Behind the AI switch: an agent's import is an AI feature; the Import
    /// window's own files are not.
    func takeInRequestedWritingImport(
        applicationSupportURL: URL? = LampAgentDescriptorStore.defaultApplicationSupportURL()
    ) async {
        guard settleAIFeatures(), let applicationSupportURL,
              pendingWritingImport == nil, !isImportingStudyData, !isTakingInWritingImport,
              let request = LampWritingImportRequests.pending(
                inApplicationSupport: applicationSupportURL
              ).first else { return }
        // Claimed before the plan suspends, so a second take-in — Lamp coming
        // to the front as it launches — cannot plan the same request too.
        isTakingInWritingImport = true
        defer { isTakingInWritingImport = false }
        do {
            let plan = try await library.planWritingImport(LampWritingImportRequests.importFiles(
                of: request, inApplicationSupport: applicationSupportURL
            ))
            // Asked again after the wait: the switch may have been turned
            // off, the person may have started an import of their own, and
            // the request may have been decided elsewhere.
            guard settleAIFeatures(), pendingWritingImport == nil, !isImportingStudyData,
                  LampWritingImportRequests.status(
                    id: request.id, inApplicationSupport: applicationSupportURL
                  ) == .waiting else { return }
            pendingWritingImport = PendingWritingImport(
                sourceName: request.sourceName,
                plan: plan,
                requestID: request.id,
                note: request.note
            )
        } catch {
            errorMessage = "Could not read the writing import an agent asked for: \(error.localizedDescription)"
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
        moduleSearchKindsWithMore = []
        moduleSearchCutKinds = []
        moduleSearchScripture = nil
        isModuleSearching = false
    }

    /// The modules a search may look in: all of them (nil) unless some are
    /// hidden, then every module but those, and the reader's own notes,
    /// writing and highlights. Given to core rather than filtered from its
    /// answer, so a hidden module's matches never take a place a shared page
    /// gives out.
    func searchableModuleIDs() async throws -> Set<String>? {
        guard !hiddenModuleIDs.isEmpty else { return nil }
        let personalSetIDs = Set((try await library.highlightSets()).map(\.id))
        return Set(modules.filter { !hiddenModuleIDs.contains($0.id) }.map(\.id))
            .union(["personal-notes", "personal-devotionals"])
            .union(personalSetIDs)
    }

    /// The themes of my highlight sets, one per mark, the first name kept:
    /// what Search finds highlights by besides colours and styles.
    func highlightThemesForSearch() async -> [LampHighlightTheme] {
        var seen = Set<LampHighlightMark>()
        var themes: [LampHighlightTheme] = []
        for set in (try? await library.highlightSets()) ?? [] {
            for theme in (try? await library.highlightThemes(setID: set.id)) ?? []
            where seen.insert(LampHighlightMark(color: theme.color, style: theme.style)).inserted {
                themes.append(theme)
            }
        }
        return themes
    }

    func searchModules(
        _ query: String,
        kind: LampModuleKind? = nil,
        moduleID: String? = nil,
        bookRange: ClosedRange<Int>? = nil,
        strongsKey: String? = nil,
        highlightColors: Set<String>? = nil,
        highlightStyles: Set<LampHighlightStyle>? = nil,
        highlightThemes: Set<LampHighlightMark>? = nil,
        listsHighlights: Bool = false,
        devotionalCriteria: LampDevotionalSearchCriteria = .init()
    ) {
        moduleSearchTask?.cancel()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // A date, tag or category is a search in its own right: core answers
        // one now, and without this the fields did nothing on their own.
        guard !trimmedQuery.isEmpty
            || strongsKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || highlightColors?.isEmpty == false
            || highlightStyles?.isEmpty == false || highlightThemes?.isEmpty == false || listsHighlights
            || devotionalCriteria != LampDevotionalSearchCriteria() else {
            moduleSearchResults = []
            moduleSearchKindsWithMore = []
            moduleSearchCutKinds = []
            moduleSearchScripture = nil
            isModuleSearching = false
            return
        }
        // Scripture from the reading translation, on the page of every kind.
        let reading = kind == nil ? readingTranslationID : nil
        let request = ModuleSearchRequest(
            query: trimmedQuery, kind: kind, moduleID: moduleID, bookRange: bookRange,
            strongsKey: strongsKey, highlightColors: highlightColors,
            highlightStyles: highlightStyles, highlightThemes: highlightThemes, listsHighlights: listsHighlights,
            devotionalCriteria: devotionalCriteria, readingTranslationID: reading
        )
        // A search asked again — a Search tab chosen again, mostly — shows
        // what it found last time at once, then runs again quietly in case a
        // note or a writing has changed since. Switching tabs used to leave
        // the last tab's results up for the typing delay, then swap them.
        let recent = recentModuleSearches.last { $0.request == request }
        if let recent {
            show(recent.answer)
            isModuleSearching = false
        } else {
            isModuleSearching = true
        }
        moduleSearchTask = Task {
            do {
                // The delay is for typing; a search already on screen is only
                // being checked.
                if recent == nil { try await Task.sleep(for: .milliseconds(250)) }
                let includedModuleIDs: Set<String>?
                if let moduleID {
                    includedModuleIDs = [moduleID]
                } else {
                    includedModuleIDs = try await searchableModuleIDs()
                }
                // Across every kind, a page shared among the kinds that
                // matched, each kind's best, a dozen or so each: one merged
                // list cut at 250 gave a common word's every place to
                // Scripture, and commentaries and books matched unseen, but a
                // 250 shared would bury the second shelf fifty rows down (the
                // phone measured it at 100). "More in …" carries the depth:
                // one kind, chosen, gets a page of 250 to itself.
                let results: [LampModuleSearchResult]
                let kindsWithMore: Set<LampModuleKind>
                let cutKinds: Set<LampModuleKind>
                var scripture: ModuleSearchScripture?
                if let kind {
                    results = try await library.searchModules(
                        query: trimmedQuery,
                        kinds: [kind],
                        moduleIDs: includedModuleIDs,
                        bookRange: bookRange,
                        strongsKey: strongsKey,
                        highlightColors: highlightColors,
                        highlightStyles: highlightStyles,
                        highlightThemes: highlightThemes,
                        listsHighlights: listsHighlights,
                        devotionalCriteria: devotionalCriteria,
                        limit: 250
                    )
                    kindsWithMore = []
                    cutKinds = []
                } else {
                    // Scripture from the reading translation: every
                    // translation searched together put the same verse on
                    // the page once per translation. "More in Scripture" has
                    // them all.
                    let groups = try await library.searchModulesByKind(
                        query: trimmedQuery,
                        moduleIDs: includedModuleIDs,
                        bookRange: bookRange,
                        strongsKey: strongsKey,
                        highlightColors: highlightColors,
                        highlightStyles: highlightStyles,
                        highlightThemes: highlightThemes,
                        listsHighlights: listsHighlights,
                        devotionalCriteria: devotionalCriteria,
                        preferredTranslationID: reading,
                        limit: 60
                    )
                    results = groups.flatMap(\.results)
                    kindsWithMore = Set(groups.filter { $0.hasMore || !$0.alsoInTranslationIDs.isEmpty }.map(\.kind))
                    cutKinds = Set(groups.filter(\.hasMore).map(\.kind))
                    scripture = groups.first { $0.kind == .translation }?.translationID.map { shown in
                        ModuleSearchScripture(
                            translationID: shown,
                            readingTranslationID: reading,
                            alsoIn: groups.first { $0.kind == .translation }?.alsoInTranslationIDs ?? []
                        )
                    }
                }
                guard !Task.isCancelled else { return }
                let answer = ModuleSearchAnswer(
                    results: results, kindsWithMore: kindsWithMore, cutKinds: cutKinds, scripture: scripture
                )
                recentModuleSearches.removeAll { $0.request == request }
                recentModuleSearches.append((request, answer))
                if recentModuleSearches.count > 8 { recentModuleSearches.removeFirst() }
                show(answer)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                moduleSearchResults = []
                moduleSearchKindsWithMore = []
                moduleSearchCutKinds = []
                moduleSearchScripture = nil
            }
            if !Task.isCancelled { isModuleSearching = false }
        }
    }

    /// Puts a search's answer on screen, publishing only what changed: a
    /// search shown from the recent ones and run again unchanged would
    /// otherwise lay the list out twice.
    private func show(_ answer: ModuleSearchAnswer) {
        if moduleSearchResults != answer.results { moduleSearchResults = answer.results }
        if moduleSearchKindsWithMore != answer.kindsWithMore { moduleSearchKindsWithMore = answer.kindsWithMore }
        if moduleSearchCutKinds != answer.cutKinds { moduleSearchCutKinds = answer.cutKinds }
        if moduleSearchScripture != answer.scripture { moduleSearchScripture = answer.scripture }
    }

    /// The translation being read: the reader's open one, else the last
    /// chosen. What Search's page of every kind takes Scripture from.
    var readingTranslationID: String? {
        activeReader?.selectedTranslationID ?? selectedTranslationID
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

    /// `translationID`: the translation the verse is read in. A highlight of
    /// the reader's own marks words by where they fall in the translation it
    /// was made in, and the library holds the chapters of every tab and
    /// window, so one is drawn on that translation's text alone. Nil for
    /// every translation's.
    func highlights(for reference: Int, in translationID: String? = nil) -> [LampVerseHighlight] {
        (installedHighlightsByReference[reference] ?? [])
            + personalHighlights(for: reference, in: translationID)
    }

    func personalHighlights(for reference: Int, in translationID: String? = nil) -> [LampVerseHighlight] {
        let highlights = highlightsByReference[reference] ?? []
        guard let translationID else { return highlights }
        // By translation, not by exact id: a highlight carries the id its
        // translation had first, so an exact test dropped every highlight
        // made before the rename.
        return highlights.filter {
            LampTranslationID.sameTranslation($0.translationID, translationID)
        }
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

    /// `mediaJSON` nil leaves the note's media as it is, so a caller that
    /// only edits text cannot take the pictures off it.
    func savePersonalNote(
        reference: Int,
        title: String?,
        content: String,
        verseReferences: [Int],
        footnotes: [LampVerseFootnote],
        mediaJSON: String? = nil
    ) async throws {
        let note = try await library.setPersonalVerseNote(
            reference: reference,
            title: title,
            content: content,
            verseReferences: verseReferences,
            footnotes: footnotes,
            mediaJSON: mediaJSON
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
        // The translation's ORIGINAL id. A highlight set is a synced
        // identity: every device, on any build, must name it the same, so it
        // is "personal-highlights:ESVs" even where the module is now "ESV".
        // Built from the installed id instead, reading ESV deleted from one
        // set and saved into another, and a colour change left the old
        // highlight on the page beneath the new one.
        let setID = "personal-highlights:\(LampTranslationID.original(translationID))"

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
        setID: String,
        translationID asked: String? = nil
    ) async throws {
        // The translation the words were chosen in, where the caller knows it:
        // the reader may have moved on by the time this runs.
        guard let translationID = asked ?? selectedTranslationID else { return }
        let highlight = try await library.saveVerseHighlight(
            translationID: translationID,
            reference: reference,
            startOffset: startOffset,
            endOffset: endOffset,
            style: style,
            color: color,
            setID: setID
        )
        // A highlight records the translation by its first id; the one read
        // may be named by its new one.
        guard let selected = selectedTranslationID,
              LampTranslationID.sameTranslation(selected, translationID) else { return }
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

    /// Adds a plan made in Lamp, includes it in Today, and reads the library
    /// again so it appears in the list.
    ///
    /// Core installs a made plan as an ordinary plan module — it syncs, and is
    /// ticked off, like any other — and does not select it. Selecting is this
    /// app's decision: someone who has just made a plan means to read it.
    @discardableResult
    func addReadingPlan(_ draft: LampReadingPlanDraft) async throws -> String {
        let module = try await library.installReadingPlan(draft)
        try await library.setPlanSelected(moduleID: module.id, selected: true)
        await refreshLibrary()
        return module.id
    }

    /// Adds the reading plans other apps have asked for.
    ///
    /// `add_reading_plan` runs in the MCP helper, a process of its own that
    /// must not install into the library Lamp has open, so it writes down what
    /// was asked for and this installs it. Called when the library is first
    /// read and whenever a plans view appears, which is where someone who
    /// asked for a plan will go looking for it.
    ///
    /// A request core refuses is forgotten rather than kept: words that could
    /// not be laid out today will not lay out tomorrow, and a plan nobody can
    /// use should not greet every launch with the same complaint. Any other
    /// failure — the install itself — is left to be tried again.
    func takeInRequestedReadingPlans(
        applicationSupportURL: URL? = LampAgentDescriptorStore.defaultApplicationSupportURL()
    ) async {
        // Plans asked for by an agent in another app wait while AI features
        // are off, and arrive once they are on again.
        guard settleAIFeatures(), let applicationSupportURL else { return }
        let waiting = LampReadingPlanAdditions.pending(
            inApplicationSupport: applicationSupportURL
        )
        guard !waiting.isEmpty else { return }
        var added: [String] = []
        var refused: [String] = []
        for addition in waiting {
            do {
                let draft = try addition.request.request().draft(id: addition.id)
                try await library.installReadingPlan(draft)
                try await library.setPlanSelected(moduleID: addition.id, selected: true)
                LampReadingPlanAdditions.forget(
                    id: addition.id, inApplicationSupport: applicationSupportURL
                )
                added.append(draft.plan.name)
            } catch let error as LampReadingPlanError {
                LampReadingPlanAdditions.forget(
                    id: addition.id, inApplicationSupport: applicationSupportURL
                )
                refused.append(error.localizedDescription)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if !added.isEmpty { await refreshLibrary() }
        if let message = LampReadingPlanAdditions.summary(added: added, refused: refused) {
            addedPlanMessage = message
        }
    }

    /// Starts a writing, carrying a reader chat's conversation into it where
    /// one is named.
    ///
    /// The conversation is copied first and the writing saved after, so a
    /// copy that fails leaves no writing behind that is missing what it was
    /// started for. Only a save that did not happen takes the copy away
    /// again: once the writing is in the library, the copy is its
    /// conversation, whatever goes wrong after.
    ///
    /// `providerID` is whose conversation in the chat comes across; nil
    /// means the one the chat is on now.
    @discardableResult
    func startWriting(
        id: String = UUID().uuidString,
        title: String,
        category: String? = nil,
        draft: String? = nil,
        fromReaderChat chatID: UUID? = nil,
        upTo turn: UUID? = nil,
        providerID: String? = nil
    ) async throws -> LampDevotional {
        let workspace = LampWritingWorkspace.url(libraryRootURL: library.rootURL, writingID: id)
        let hadWorkspace = FileManager.default.fileExists(atPath: workspace.path)
        func takeBackCopy() {
            if chatID != nil, !hadWorkspace { try? FileManager.default.removeItem(at: workspace) }
        }
        if let chatID {
            // Checked here, with nothing between it and the copy that could
            // let a reply begin: a message being prepared when the reader
            // confirmed can start sending at any suspension, and copied then
            // the conversation would end at its unanswered question.
            guard !KeptAgentChats.isRunning(in: ReaderChatWorkspaceStore.workspaceURL(
                libraryRootURL: library.rootURL, chatID: chatID
            )) else {
                throw ReaderChatWritingCopy.CopyError.replyArriving
            }
            do {
                try ReaderChatWritingCopy.copy(
                    chat: chatID, upTo: turn,
                    providerID: providerID ?? currentProvider(ofReaderChat: chatID),
                    libraryRootURL: library.rootURL, writingID: id
                )
            } catch {
                takeBackCopy()
                throw error
            }
        }
        let now = Date()
        let saved: LampDevotional
        do {
            saved = try await library.savePersonalDevotional(LampDevotional(
                id: id,
                moduleID: "personal-devotionals",
                moduleName: "My Writing",
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                category: LampWritingCategory.kindToStore(
                    shown: category ?? LampWritingCategory.suggestions.first, held: nil
                ),
                content: draft ?? "",
                created: now,
                lastModified: now,
                isEditable: true
            ))
        } catch {
            takeBackCopy()
            throw error
        }
        // Saved, and put in its place in the list: a new writing is one row,
        // not a reason to read every writing there is.
        await absorbDevotional(id: saved.id, orElse: saved)
        await refreshManuscriptNotes(for: saved)
        if let chatID {
            // What the chat shows of it. A failure costs the chat its line
            // pointing to the writing, not the writing.
            try? ReaderChatWritingCopy.recordStarted(
                .init(writingID: saved.id, title: saved.title, startedAt: now),
                chat: chatID, libraryRootURL: library.rootURL
            )
            startedWritingsRevision += 1
        }
        return saved
    }

    /// The provider a reader chat is on now, as its pane would open it.
    private func currentProvider(ofReaderChat chatID: UUID) -> String {
        AgentChatChoicesStore.load(
            in: ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: library.rootURL, chatID: chatID)
        ).value(
            for: AgentChatChoices.providerKey,
            orAppDefault: defaults.string(forKey: "reader.chat.provider")
        ) ?? AIProviderCLI.codex.rawValue
    }

    /// Starts the writings agents have asked for.
    ///
    /// `start_writing` runs in the MCP helper, which must not write into the
    /// library Lamp has open, so it writes down what was asked for and this
    /// starts it. Called when the library is first read, when Today, the
    /// Writing section or a reader chat appears, and whenever a reader chat's
    /// reply finishes — that last because the request came from inside the
    /// reply, and the conversation it carries should hold the whole of it.
    ///
    /// A request from a reader chat waits until the reply that made it is on
    /// disk; see `ReaderChatWritingCopy.isReady`. One take-in runs at a time,
    /// and one asked for while another runs is run after it.
    func takeInRequestedWritings(
        applicationSupportURL: URL? = LampAgentDescriptorStore.defaultApplicationSupportURL()
    ) async {
        guard !isTakingInWritings else {
            takeInWritingsAgain = true
            return
        }
        isTakingInWritings = true
        defer { isTakingInWritings = false }
        repeat {
            takeInWritingsAgain = false
            await takeInRequestedWritingsOnce(applicationSupportURL: applicationSupportURL)
        } while takeInWritingsAgain
    }

    private func takeInRequestedWritingsOnce(applicationSupportURL: URL?) async {
        guard settleAIFeatures(), let applicationSupportURL else { return }
        await takeInRequestedWritingImport(applicationSupportURL: applicationSupportURL)
        let waiting = LampWritingStarts.pending(inApplicationSupport: applicationSupportURL)
        guard !waiting.isEmpty else { return }
        var started: [String] = []
        for request in waiting {
            var providerID: String?
            var upTo: UUID?
            var copiesConversation = request.readerChatID != nil
            if let chatID = request.readerChatID {
                let provider = request.readerChatProviderID ?? currentProvider(ofReaderChat: chatID)
                guard ReaderChatWritingCopy.isReady(
                    askedAt: request.askedAt,
                    chat: chatID,
                    providerID: provider,
                    libraryRootURL: library.rootURL,
                    isRunning: KeptAgentChats.isRunning(in: ReaderChatWorkspaceStore.workspaceURL(
                        libraryRootURL: library.rootURL, chatID: chatID
                    )),
                    launchedAt: launchedAt
                ) else { continue }
                providerID = provider
                let asking = ReaderChatWritingCopy.requestingTurn(
                    askedAt: request.askedAt, chat: chatID,
                    providerID: provider, libraryRootURL: library.rootURL
                )
                // Cleared since it asked: what the chat holds now is not the
                // conversation the request was made in, so none is copied.
                copiesConversation = !asking.replaced
                upTo = asking.turn
            }
            // Made already, by a take-in that stopped before forgetting it.
            //
            // Asked of the library, not of the list in memory. The list is
            // filled after launch rather than during it, so at the moment
            // this runs it can be empty — and a request naming a writing that
            // already exists would then be started again, overwriting the
            // title and body with the ones the request was made with. Found
            // by a Codex review of the launch change, with a reproduction.
            let held = (try? await library.personalDevotional(id: request.id)) ?? nil
            guard held == nil else {
                LampWritingStarts.forget(id: request.id, inApplicationSupport: applicationSupportURL)
                continue
            }
            do {
                let saved = try await startWriting(
                    id: request.id,
                    title: request.title,
                    category: request.category,
                    draft: request.draft,
                    fromReaderChat: copiesConversation ? request.readerChatID : nil,
                    upTo: upTo,
                    providerID: providerID
                )
                if !copiesConversation, let chatID = request.readerChatID {
                    try? ReaderChatWritingCopy.recordStarted(
                        .init(writingID: saved.id, title: saved.title),
                        chat: chatID, libraryRootURL: library.rootURL
                    )
                    startedWritingsRevision += 1
                }
                LampWritingStarts.forget(id: request.id, inApplicationSupport: applicationSupportURL)
                if request.readerChatID == nil { started.append(saved.title) }
            } catch {
                errorMessage = "Could not start the writing \u{201C}\(request.title)\u{201D}: \(error.localizedDescription)"
            }
        }
        if started.count == 1 {
            startedWritingMessage = "Started the writing \u{201C}\(started[0])\u{201D}, asked for in another app."
        } else if started.count > 1 {
            startedWritingMessage = "Started \(started.count) writings asked for in another app."
        }
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

    /// `reviewTexts` are the texts the saver held of the writing (an
    /// editor's, an assistant's draft), which its review marks are carried
    /// from along with the body this replaces. Nobody else's: see
    /// `WritingReviewTexts`.
    @discardableResult
    func savePersonalDevotional(_ devotional: LampDevotional, reviewTexts: [String] = []) async throws -> LampDevotional {
        try await savingPersonalDevotional(devotional, reviewTexts: reviewTexts) {
            try await self.library.savePersonalDevotional(devotional)
        }!
    }

    /// The same, unless the stored copy was saved after `revision`, the one
    /// the editor began from: a copy from another device, brought in by sync
    /// while the editor was open. Nil then, having written nothing, and the
    /// writings read again so the editor can see the newer one.
    func savePersonalDevotional(
        _ devotional: LampDevotional, reviewTexts: [String] = [], ifNotNewerThan revision: Date
    ) async throws -> LampDevotional? {
        try await savingPersonalDevotional(devotional, reviewTexts: reviewTexts) {
            try await self.library.savePersonalDevotional(devotional, ifNotNewerThan: revision)
        }
    }

    private func savingPersonalDevotional(
        _ devotional: LampDevotional, reviewTexts: [String], write: () async throws -> LampDevotional?
    ) async throws -> LampDevotional? {
        // The carry's place in line, and its generation, taken before the
        // save waits on the database: a turn's draft taken in meanwhile is
        // then marked after this carry, which cannot take its marks back.
        let carry = reviewCarry(for: devotional.id)
        let slot = carry.map { _ in reserveReviewCarry(for: devotional.id) }
        let written: LampDevotional?
        do {
            written = try await write()
        } catch {
            slot?.reservation.giveUp()
            throw error
        }
        guard let saved = written else {
            // Refused: nothing was written, so nothing is carried, and the
            // place in line is given up rather than left to time out.
            slot?.reservation.giveUp()
            publishDevotionals(try await library.devotionals())
            return nil
        }
        if let carry, let slot { carryReviewMarks(carry, to: saved, from: reviewTexts, in: slot) }
        // The writing is written, and the copy read back is what the list
        // should show, so it is put in its place rather than the whole list
        // being read again. Autosave fires a second and a half after a
        // keystroke, and reading every writing then — 125 ms at four
        // thousand of them, measured, and the list's own filter run again
        // after it — was work the typist paid for a row they could already
        // see (`Documentation/decisions/0004`).
        //
        // What is *not* skipped: a copy that arrived from another device
        // while the editor was open is caught by the save itself refusing
        // (`ifNotNewerThan`), which reads the list again below, and a pass
        // that brings writings in calls `refresh()` when it finishes.
        await absorbDevotional(id: saved.id, orElse: saved)
        await refreshManuscriptNotes(for: saved)
        return saved
    }

    /// Puts one writing in its place in the list, as the library now holds
    /// it — or takes it out, if the library no longer holds it at all.
    ///
    /// The row is read back rather than taken from the caller. A save hands
    /// back the copy it wrote, and two saves of one writing can finish in
    /// either order, so the question "which of these is the current body?"
    /// has one honest answer and it is the database's. The first version
    /// compared the two `lastModified` dates to the second, which a writing
    /// synced from a device whose clock runs ahead defeats: the save
    /// succeeds, its stamp is *behind* the copy already in the list, and the
    /// list would have kept the old body while the file held the new one —
    /// and the editor's own check for a newer copy would then have restored
    /// that stale body over what was typed. Found by a Codex review. A read
    /// is 0.2 ms against 125 ms for the list, so there is nothing to defend.
    ///
    /// In the order the library gives writings out in
    /// (`LampDevotional.libraryOrder`), not an order of this app's own, or
    /// the list would re-order itself the first time anything read it again.
    ///
    /// `orElse` is used only where the library cannot be read at all: a list
    /// that will not read is not a writing that was not saved.
    private func absorbDevotional(id: String, orElse fallback: LampDevotional?) async {
        let current: LampDevotional?
        do {
            current = try await library.personalDevotional(id: id)
        } catch {
            current = fallback
        }
        var updated = devotionals
        guard let current else {
            publishDevotionals(updated.filter { $0.id != id })
            return
        }
        if let at = updated.firstIndex(where: { $0.id == id }) {
            updated[at] = current
            // Its place can move: a title, a date or a series changes where
            // the library would have put it.
            if !updated.isSorted(by: LampDevotional.libraryOrder) {
                updated.sort(by: LampDevotional.libraryOrder)
            }
        } else {
            let at = updated.firstIndex { LampDevotional.libraryOrder(current, $0) }
            updated.insert(current, at: at ?? updated.endIndex)
        }
        publishDevotionals(updated)
    }

    /// The one place the list of writings is set, so the revision beside it
    /// cannot be forgotten.
    private func publishDevotionals(_ updated: [LampDevotional]) {
        devotionals = updated
        devotionalsRevision += 1
    }

    /// What a save needs to carry the writing's review marks across its
    /// edit, or nil where there is nothing to carry: marks are off, or this
    /// writing has none. Asked before anything is rendered, so a save with
    /// no marks does no more work than it did before marks existed.
    private func reviewCarry(for writingID: String) -> (store: LampWritingReviewStore, previous: LampDevotional)? {
        // Whether the writing has marks is asked when the carry runs, not
        // now: a turn's first marks may still be in line, and a save that
        // looked now would carry nothing and leave them behind.
        guard let store = WritingReviewMarks.store(libraryRootURL: library.rootURL),
              let previous = devotionals.first(where: { $0.id == writingID })
        else { return nil }
        return (store, previous)
    }

    private func reserveReviewCarry(for writingID: String) -> (reservation: WritingReviewWork.Reservation, generation: Int) {
        let generation = (reviewSaveGeneration[writingID] ?? 0) + 1
        reviewSaveGeneration[writingID] = generation
        return (WritingReviewWork.shared.reserve(), generation)
    }

    /// How many saves of each writing have asked for a carry, counted as
    /// each takes its place in line: dates cannot order them, since a save
    /// is stamped to the fraction of a second and stored to the second.
    private var reviewSaveGeneration: [String: Int] = [:]
    /// The latest of those saves that went through. A carry runs only while
    /// no later save did: one that failed or was refused carries nothing,
    /// and supersedes nothing.
    private var reviewSavedGeneration: [String: Int] = [:]

    /// Carries the writing's review marks across an edit, so the rest of a
    /// marked passage the writer typed into stays marked and their own words
    /// do not. Off the main actor — both bodies are rendered and the whole
    /// manuscript compared — and in the order the saves were made. Most
    /// saves touch no mark, and then nothing is written.
    ///
    /// Every save comes through here, an assistant's draft taken in among
    /// them; its marks were made as it was taken in, and the carry leaves a
    /// mark already standing where it was made.
    private func carryReviewMarks(
        _ carry: (store: LampWritingReviewStore, previous: LampDevotional), to saved: LampDevotional,
        from known: [String], in slot: (reservation: WritingReviewWork.Reservation, generation: Int)
    ) {
        // The versions the saver held, a clear's among them: each mark is
        // carried from the text it is anchored in. A mark anchored in a text
        // the saver never held (another window's draft not yet saved, the
        // phone's body) is left for that text's own save, unless its words
        // stand once in one of these.
        let generation = slot.generation
        let library = library
        reviewSavedGeneration[saved.id] = max(reviewSavedGeneration[saved.id] ?? 0, generation)
        slot.reservation.fill { [weak self] in
            // Overtaken: a newer save of this writing went through, and its
            // carry takes each mark from its own text.
            let overtaken = await MainActor.run { (self?.reviewSavedGeneration[saved.id] ?? 0) > generation }
            guard !overtaken,
                  let url = try? carry.store.url(writingID: saved.id),
                  FileManager.default.fileExists(atPath: url.path)
            else { return }
            let current = saved.displayMarkdown
            // A body sync brought since is newer than this save's, and its
            // marks are not this save's to carry to the older text.
            guard let stored = try? await library.personalDevotional(id: saved.id),
                  stored.displayMarkdown == current
            else { return }
            // Carried even when this save's body did not move (its details
            // did): it may have overtaken a carry still in line for a text
            // save, whose marks then come from the texts known. A carry that
            // moves nothing writes nothing.
            let previous = carry.previous.displayMarkdown
            _ = try? carry.store.update(writingID: saved.id) { $0.carryingToText(current, from: known + [previous]) }
            await MainActor.run { WritingReviewTexts.shared.remember(current, for: saved.id) }
        }
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
        // Its decks go with it, now rather than at the next sync pass: the
        // pass would catch them anyway, from the same ledger by the same
        // sweep, but until it ran they would sit in Slide Studio pointing at
        // a writing that is gone.
        try? LampPresentationDeckSync.removeDecksOfDeletedWritings(
            heldWritingIDs: try await library.personalDevotionalIDs(),
            deletedWritings: try await library.personalDeletionLedger(),
            in: library.rootURL
        )
        // Gone from the library, so gone from the list: one row again rather
        // than a read of all of them. Asked of the library rather than
        // assumed, because an autosave or an agent can commit a save of this
        // writing while the deck sweep above is awaited, and a row put back
        // after the deletion is a row the list has to show. Found by a Codex
        // review.
        await absorbDevotional(id: id, orElse: nil)
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
            resolveHiddenModules()
            // The reader's own translation first, and the rest after the
            // reader is up (`loadTheRestOfTheLibrary`). Book names for every
            // installed translation means opening every translation's
            // database, and the reader's first chapter waited behind all of
            // them: a library of a few hundred modules spends that on every
            // launch. The reader needs the one it is opening.
            let reading = rememberedTranslationID(among: modules)
            var bookNames: [String: [Int: String]] = [:]
            if let reading, let books = try? await library.translationBooks(moduleID: reading) {
                bookNames[reading] = Dictionary(
                    books.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            }
            if translationBookNames != bookNames.merging(
                translationBookNames, uniquingKeysWith: { first, _ in first }
            ) {
                translationBookNames = bookNames.merging(
                    translationBookNames, uniquingKeysWith: { first, _ in first }
                )
            }
            highlightSets = (try? await library.highlightSets()) ?? []
            plans = try await library.readingPlans()
            selectedPlanIDs = try await library.selectedPlanIDs()
            let completed = try await library.completedReadings(year: planProgressYear)
            completedReadingIDs = Set(completed.map(\.id))
            let availableTranslations = translations
            // Where the reader's remembered translation enters the app, and
            // so where a renamed ID is resolved — once, here, rather than at
            // the dozen places that later compare one. `held` returns the ID
            // itself where it is installed, and its new spelling only where
            // the old one is gone, so a library holding both keeps them
            // apart. Without this a remembered "ESVs" failed an exact test
            // and the reader opened whatever translation happened to be
            // first.
            let installedIDs = installedTranslationIDs
            if let remembered = selectedTranslationID,
               let held = LampTranslationID.held(remembered, among: installedIDs) {
                if held != remembered { selectedTranslationID = held }
            } else if let preferred = defaults.string(forKey: "reader.defaultTranslationID"),
                      let held = LampTranslationID.held(preferred, among: installedIDs) {
                selectedTranslationID = held
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
        // What nothing on screen is waiting for: the writings, the quizzes,
        // and the other translations' book names. Each is published as it
        // arrives, so a section that opens before they land fills in rather
        // than staying empty.
        restOfTheLibrary?.cancel()
        restOfTheLibrary = Task { [weak self] in await self?.loadTheRestOfTheLibrary() }
        // Only once the reader is already up. On the launch pass this would
        // start in the same turn that sets `hasReadLibrary`, which is what
        // triggers the reader's restore — see `buildStrongsIndexes`.
        if hasLoadedInitialContent { buildStrongsIndexes() }
    }

    private var restOfTheLibrary: Task<Void, Never>?

    /// The translation the reader will open, as `refreshLibrary` resolves it
    /// a few lines later — asked early so its book names can be read before
    /// anything else's.
    private func rememberedTranslationID(among modules: [LampInstalledModule]) -> String? {
        let installed = modules.filter { $0.kind == .translation }.map(\.id)
        if let remembered = selectedTranslationID,
           let held = LampTranslationID.held(remembered, among: installed) {
            return held
        }
        if let preferred = defaults.string(forKey: "reader.defaultTranslationID"),
           let held = LampTranslationID.held(preferred, among: installed) {
            return held
        }
        return installed.first
    }

    /// Everything the first chapter does not wait for.
    ///
    /// Writings and quizzes are read here rather than in `refreshLibrary`
    /// because both open their own database — every devotional collection,
    /// every quiz module — and nothing the reader draws needs either. The
    /// book names of the translations not being read follow for the same
    /// reason: a Spanish translation's Génesis matters when something shows
    /// that translation.
    private func loadTheRestOfTheLibrary() async {
        if let listed = try? await library.devotionals() { publishDevotionals(listed) }
        if Task.isCancelled { return }
        quizModules = (try? await library.quizModules()) ?? quizModules
        if Task.isCancelled { return }
        // Every translation, not only the ones with no names yet: sync
        // replaces a translation under the same ID, and skipping those would
        // keep its old book names for as long as the app ran — found by a
        // Codex review. The reader's own was read on the critical path and is
        // read again here, which is one open.
        var names = translationBookNames
        for translation in modules where translation.kind == .translation {
            if Task.isCancelled { return }
            guard let books = try? await library.translationBooks(moduleID: translation.id)
            else { continue }
            names[translation.id] = Dictionary(
                books.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }
            )
            // Published per translation: a picker opened while these arrive
            // fills in rather than waiting for the last of them.
            if translationBookNames != names { translationBookNames = names }
        }
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
        // One crossing onto the library's actor for all of them, rather than
        // one per installed module per page turn.
        let installedNotes = await library.moduleVerseNotes(
            moduleIDs: noteModules.map(\.id), bookNumber: book, chapterNumber: chapter
        )
        let installedHighlights = await library.moduleVerseHighlights(
            moduleIDs: highlightModules.map(\.id), bookNumber: book, chapterNumber: chapter
        )
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

    /// Keeps a place for the next reader window to open at: ⌥↩ in the ⌘K
    /// palette opens a passage in a new window this way.
    func holdForNextReader(_ location: ReaderLocation) {
        pendingReaderLocation = location
    }

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
        // Only a change is published, and only a change is written: every
        // reader in every kept tab watches the library, and a write to the
        // standard defaults wakes every view that reads a setting. A tab
        // shown again reports the place it was already known to be.
        let moved = selectedTranslationID != translationID
            || selectedBookNumber != book
            || selectedChapterNumber != chapter
        if selectedTranslationID != translationID { selectedTranslationID = translationID }
        if selectedBookNumber != book { selectedBookNumber = book }
        if selectedChapterNumber != chapter { selectedChapterNumber = chapter }
        if selectedVerseReference != verse { selectedVerseReference = verse }
        if self.books != books { self.books = books }
        if self.chapter != contents.chapter { self.chapter = contents.chapter }
        // A reader hands over the chapter as it read it, and goes on handing
        // over that same read at every verse clicked. Taken again, it put
        // back what a note or highlight saved since had changed here, and
        // the note fell out of the Notes pane and its mark out of the
        // verse. Only a read not yet taken is.
        if contents != lastAbsorbedContents { absorbChapterContents(contents) }
        if moved { persistLocation() }
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
        lastAbsorbedContents = contents
        let first = loaded.book.id * 1_000_000 + loaded.number * 1_000
        let references = first..<(first + 1_000)

        // Only a change is published: every reader watches these.
        let highlights = highlightsByReference
            .filter { !references.contains($0.key) }
            .merging(contents.highlightsByReference) { _, read in read }
        if highlights != highlightsByReference { highlightsByReference = highlights }
        let installedHighlights = installedHighlightsByReference
            .filter { !references.contains($0.key) }
            .merging(contents.installedHighlightsByReference) { _, read in read }
        if installedHighlights != installedHighlightsByReference {
            installedHighlightsByReference = installedHighlights
        }
        let installedNotes = installedNotesByReference
            .filter { !references.contains($0.key) }
            .merging(contents.installedNotesByReference) { _, read in read }
        if installedNotes != installedNotesByReference { installedNotesByReference = installedNotes }
        let notes = noteReferences
            .filter { !references.contains($0) }
            .union(contents.noteReferences)
        if notes != noteReferences { noteReferences = notes }
    }

    private func persistLocation() {
        locationDefaults.set(selectedTranslationID, forKey: "reader.translationID")
        locationDefaults.set(selectedBookNumber ?? 0, forKey: "reader.bookNumber")
        locationDefaults.set(selectedChapterNumber, forKey: "reader.chapterNumber")
    }

    static let locationKeys = ["reader.translationID", "reader.bookNumber", "reader.chapterNumber"]

    /// The reader's own defaults, holding the place an earlier Lamp kept in
    /// `old` until it saves one of its own.
    static func locationStore(adoptingFrom old: UserDefaults) -> UserDefaults {
        let suiteName = (Bundle.main.bundleIdentifier ?? "Lamp") + ".reader-location"
        guard let suite = UserDefaults(suiteName: suiteName) else { return old }
        adoptEarlierLocation(from: old, into: suite)
        return suite
    }

    /// Copies the place kept in `old` into `new` where `new` has none yet.
    static func adoptEarlierLocation(from old: UserDefaults, into new: UserDefaults) {
        guard locationKeys.allSatisfy({ new.object(forKey: $0) == nil }) else { return }
        for key in locationKeys {
            if let value = old.object(forKey: key) { new.set(value, forKey: key) }
        }
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

/// Where a search across every kind took Scripture from.
struct ModuleSearchScripture: Equatable {
    /// The translation the verses shown came from.
    let translationID: String
    /// The translation being read when the search ran. Differs from
    /// `translationID` when the reading translation had no match.
    let readingTranslationID: String?
    /// The other translations that matched, for "also in …".
    let alsoIn: [String]
}

/// Everything a module search was asked, to know it when asked again.
struct ModuleSearchRequest: Equatable {
    let query: String
    let kind: LampModuleKind?
    let moduleID: String?
    let bookRange: ClosedRange<Int>?
    let strongsKey: String?
    let highlightColors: Set<String>?
    let highlightStyles: Set<LampHighlightStyle>?
    let highlightThemes: Set<LampHighlightMark>?
    let listsHighlights: Bool
    let devotionalCriteria: LampDevotionalSearchCriteria
    let readingTranslationID: String?
}

/// What a module search found, as Search shows it.
struct ModuleSearchAnswer: Equatable {
    let results: [LampModuleSearchResult]
    let kindsWithMore: Set<LampModuleKind>
    let cutKinds: Set<LampModuleKind>
    let scripture: ModuleSearchScripture?
}

private extension Array {
    /// Whether this is already in the order `precedes` describes, so a list
    /// that a change did not move is not sorted again. One pass, no
    /// allocation; `sort` on an almost-sorted array is cheap, but a sort of
    /// four thousand writings on every autosave is not nothing.
    func isSorted(by precedes: (Element, Element) -> Bool) -> Bool {
        guard count > 1 else { return true }
        return !(1..<count).contains { precedes(self[$0], self[$0 - 1]) }
    }
}
