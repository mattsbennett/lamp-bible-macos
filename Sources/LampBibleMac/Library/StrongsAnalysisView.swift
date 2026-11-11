import AppKit
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampModuleKit
import SwiftUI

/// Works out a key's analyses, the translation being read first.
///
/// One translation at a time, published as each arrives, because a whole Bible
/// takes about a tenth of a second per translation and a reader with six
/// installed should not wait on all six to see the first. Compare fills in
/// behind them.
@MainActor @Observable
final class StrongsAnalysisLoader {
    struct Request: Equatable {
        var key: String
        var activeTranslationID: String?
        var bookRange: ClosedRange<Int>?
        var translationIDs: [String]
    }

    private(set) var analyses: [LampStrongsAnalysis] = []
    /// Each key's lemma and gloss, by core's rule, which the agent tool
    /// reads by too: the pane and an outside agent looking at the same key
    /// should not disagree about what the word is.
    private(set) var entries: [String: LampStrongsHeadword] = [:]
    /// Nothing has been worked out yet, so the pane has nothing to show.
    private(set) var isLoadingFirst = false
    /// The first analysis is on screen and the rest are still coming.
    private(set) var isFillingRest = false
    private(set) var errorMessage: String?

    private var task: Task<Void, Never>?
    private var requested: Request?

    /// True only once every translation has been asked and none answered. Kept
    /// apart from `analyses.isEmpty` because the translation being read may
    /// tag nothing for this key while another one does — reporting "not here"
    /// at that point would be wrong a tenth of a second before it was right.
    var foundNothing: Bool {
        analyses.isEmpty && !isLoadingFirst && !isFillingRest && errorMessage == nil
            && requested != nil
    }

    func load(_ request: Request, library: LampLibrary) {
        guard request != requested else { return }
        task?.cancel()
        requested = request
        analyses = []
        entries = [:]
        errorMessage = nil
        guard !request.key.isEmpty, !request.translationIDs.isEmpty else {
            isLoadingFirst = false
            isFillingRest = false
            return
        }
        isLoadingFirst = true
        isFillingRest = false
        task = Task { [weak self] in
            await self?.run(request, library: library)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func run(_ request: Request, library: LampLibrary) async {
        let order = asked(request)
        for (index, translationID) in order.enumerated() {
            if Task.isCancelled || requested != request { return }
            do {
                let found = try await library.strongsAnalyses(
                    key: request.key,
                    moduleIDs: [translationID],
                    bookRange: request.bookRange,
                    // Only the translation being read, which is the only one
                    // whose occurrences are listed. A common key's verses run
                    // to about a megabyte, and Compare shows counts and
                    // renderings — never a verse — so asking for the rest
                    // would hold five copies nothing reads.
                    includingVerseText: index == 0
                )
                if Task.isCancelled || requested != request { return }
                analyses = LampStrongsAnalysisOrder.ordered(
                    analyses + found,
                    activeTranslationID: request.activeTranslationID
                )
                await readEntries(for: found, library: library, request: request)
            } catch {
                if Task.isCancelled || requested != request { return }
                // Only the first failure is worth saying out loud. One
                // translation with an unreadable database should not replace
                // an analysis the others produced perfectly well.
                if analyses.isEmpty, index == order.count - 1 {
                    errorMessage = error.localizedDescription
                }
            }
            if index == 0 {
                isLoadingFirst = false
                isFillingRest = order.count > 1
            }
        }
        if requested == request {
            isLoadingFirst = false
            isFillingRest = false
        }
    }

    /// The translation being read, then the rest in installed order.
    private func asked(_ request: Request) -> [String] {
        guard
            let active = request.activeTranslationID,
            request.translationIDs.contains(active)
        else { return request.translationIDs }
        return [active] + request.translationIDs.filter { $0 != active }
    }

    /// Lemma and gloss for the key and for whatever companions have turned up,
    /// skipping any already read: a second translation usually shares most of
    /// its companions with the first.
    private func readEntries(
        for found: [LampStrongsAnalysis],
        library: LampLibrary,
        request: Request
    ) async {
        var wanted = [LampStrongsKey.normalized(request.key)]
        wanted += found.flatMap { $0.companions.prefix(15).map(\.key) }
        let missing = wanted.filter { entries[$0] == nil }
        guard !missing.isEmpty else { return }
        guard let results = try? await library.dictionaryEntries(keys: Array(Set(missing)))
        else { return }
        if Task.isCancelled || requested != request { return }
        entries = LampStrongsHeadword.merging(results, into: entries)
        // Asking for a key no lexicon holds must not ask again on every
        // translation, so record the absence as well as the answer.
        for key in missing where entries[key] == nil {
            entries[key] = LampStrongsHeadword()
        }
    }
}

/// What a Strong's key does across the translations that tag it.
/// The Septuagint section's data for a Greek word: the Hebrew it renders there,
/// and for each of those words with a number, where that Hebrew stands in the
/// Old Testament and how the Septuagint reads in those places.
///
/// Three loads, each paid for only when something asks for it. The words come
/// from the lexicon and cost one entry lookup, so they load with the pane —
/// without them there is nothing to show and the section must not appear.
/// The counts are a search per word, paid when the section is opened, with the
/// English translation's analysis of each word for what it is most often
/// rendered by. The English of a word's verses is that translation's analysis
/// read with its verse text, and the Greek beside a verse a chapter read per
/// chapter those verses fall in, both paid when a word is opened.
///
/// Nothing here belongs to the Greek word's own counts. These are the Hebrew
/// word's verses: the Septuagint does not always use this Greek word where that
/// Hebrew stands, and until STEPBible publishes its tagged Septuagint there is
/// no way to say which verses it does.
@MainActor @Observable
final class SeptuagintLoader {
    struct Word: Identifiable {
        let hebrew: LampSeptuagintHebrew
        /// The verses of the Old Testament this Hebrew word stands in. Nil
        /// until counted, and empty for a word with no number to count by.
        var references: [Int]?

        var id: String { "\(hebrew.text)|\(hebrew.strongs ?? "")" }
    }

    struct Verse: Identifiable, Equatable {
        /// The Greek beside one verse.
        ///
        /// Three states rather than an optional string, because "not read yet"
        /// and "read, and this text hasn't got it" are different things to
        /// say, and an optional said both. It said them in the same words: the
        /// rows go up the moment a word is opened so the references are there
        /// to read, and every one of them claimed the verse was missing from
        /// the Greek until the chapters came back.
        enum Greek: Equatable {
            case pending
            case absent
            case text(String)
        }

        /// The verse in English, with the Hebrew word's rendering marked.
        ///
        /// Its own three states, on the rule `Greek` keeps: "not read yet" and
        /// "the translation doesn't tag this word here" are different, and
        /// only the second may be settled.
        enum English: Equatable {
            case pending
            /// The English translation has no counterpart for this verse, so
            /// the Hebrew number is all there is to show.
            case none
            /// Its English number, and the verse with the word marked where
            /// the translation tags it there. Untagged, no English is shown:
            /// marking a likely word would be a guess.
            case read(LampSeptuagintSection.English)
        }

        /// In the Hebrew text's numbering.
        let reference: Int
        var english: English = .pending
        /// The Septuagint's Greek for the verse, where it has that verse: the
        /// numbering does not always line up, and some books it does not carry.
        var greek: Greek

        var id: Int { reference }
    }

    /// What a word's verses have to show: the rows, or why there are none.
    ///
    /// The two bare cases are facts about the library, not about any verse,
    /// and each is said once in place of the rows rather than against all
    /// twenty-five of them.
    enum Verses: Equatable {
        case rows([Verse])
        /// Nothing installed numbers its verses the Septuagint's way.
        case withoutSeptuagint
        /// The texts are installed, and one could not be read: the one named,
        /// where it is known.
        case unreadable(String?)
    }

    /// The most verses listed for one Hebrew word. דָּבָר stands in some 1,400
    /// of them, which is not a list anyone reads inside a collapsed section;
    /// the rest are one click away in that word's own analysis.
    static let shownVerses = 25

    private(set) var words: [Word] = []
    /// What each word's verses have to show, by its id. A present value means
    /// asked, and must never read as "not asked yet".
    private(set) var verses: [String: Verses] = [:]
    private(set) var errorMessage: String?
    /// The name of the Greek text the verses were read from, for saying which
    /// text is missing a verse rather than blaming the whole tradition.
    private(set) var septuagintName: String?
    /// Each Hebrew word's lemma and transliteration, by normalized key.
    private(set) var headwords: [String: LampStrongsHeadword] = [:]
    /// What each Hebrew word means, by normalized key, for where no English
    /// renders it: a lexicon's own gloss, else Strong's definition. Never
    /// Strong's short definition, which is the King James renderings
    /// ("[idiom] do, familiar, [idiom] fare" for שָׁלוֹם).
    private(set) var meanings: [String: String] = [:]
    /// What each word is most often rendered by in the English translation,
    /// by word id: the gloss a reader with no Hebrew goes by.
    private(set) var renderings: [String: String] = [:]

    private var loadedKey: String?
    private var countedKey: String?

    /// The Hebrew the lexicon names, from whichever dictionary carries the
    /// note. No dictionary is named here: the note is a property of an entry,
    /// not of a particular lexicon, and TBESG is simply the one that has it.
    func loadWords(key: String, model: LibraryModel) async {
        guard loadedKey != key else { return }
        loadedKey = key
        words = []
        verses = [:]
        headwords = [:]
        meanings = [:]
        renderings = [:]
        countedKey = nil
        errorMessage = nil
        guard BiblicalOriginalLanguage.inferred(from: key) == .greek else { return }
        do {
            let found = try await model.library.dictionaryEntries(
                keys: [key, LampStrongsKey.normalized(key)]
            )
            guard loadedKey == key else { return }
            words = LampSeptuagintSection.words(in: found.flatMap(\.senses))
                .map { Word(hebrew: $0) }
            // Their transliterations, so a reader with no Hebrew has
            // something to say them by. Without them the Hebrew is still
            // shown, so a failed read costs only the transliteration.
            let hebrewKeys = words.compactMap(\.hebrew.strongs)
            if !hebrewKeys.isEmpty,
               let entries = try? await model.library.dictionaryEntries(keys: hebrewKeys),
               loadedKey == key {
                headwords = LampStrongsHeadword.merging(entries)
                let ordered = LampModuleSelection.ordered(
                    entries, preferredIDs: LampStrongsHeadword.preferredDictionaryIDs, id: \.moduleID
                )
                for entry in ordered {
                    let key = LampStrongsKey.normalized(entry.key)
                    guard meanings[key] == nil else { continue }
                    let meaning = headwords[key]?.shortGloss
                        ?? entry.senses.lazy.compactMap(\.definition).first {
                            !$0.trimmingCharacters(in: .whitespaces).isEmpty
                        }
                    if let meaning { meanings[key] = meaning }
                }
            }
        } catch is CancellationError {
            loadedKey = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// How often each Hebrew word stands in the Old Testament, counted in the
    /// Hebrew text itself rather than in an English translation that tags it.
    func loadCounts(key: String, englishID: String?, model: LibraryModel) async {
        guard countedKey != key, !words.isEmpty else { return }
        countedKey = key
        guard let hebrewText = hebrewText(model) else {
            for index in words.indices { words[index].references = [] }
            return
        }
        for index in words.indices {
            guard let strongs = words[index].hebrew.strongs else {
                words[index].references = []
                continue
            }
            do {
                let analyses = try await model.library.strongsAnalyses(
                    key: strongs, moduleIDs: [hebrewText.id]
                )
                guard countedKey == key else { return }
                words[index].references = analyses.first?.references ?? []
            } catch is CancellationError {
                return
            } catch {
                words[index].references = []
            }
            // What the English most often renders it by. A rendering missed
            // only leaves the heading in Hebrew, so a failed read is not
            // retried.
            if let englishID, englishID != hebrewText.id,
               let english = try? await model.library.strongsAnalyses(
                   key: strongs, moduleIDs: [englishID]
               ).first {
                guard countedKey == key else { return }
                renderings[words[index].id] = LampSeptuagintSection.rendering(in: english)
            }
        }
    }

    /// The first `shownVerses` of a word's verses, each in English with the
    /// word marked where the English translation tags it, and with the
    /// Septuagint's Greek where the two numberings meet.
    func loadVerses(for word: Word, englishID: String?, model: LibraryModel) async {
        // A read that failed is worth trying again when the word is opened
        // again. The other outcomes are settled: the verses are read, or the
        // library hasn't got a Septuagint to read them from.
        if case .unreadable = verses[word.id] { verses[word.id] = nil }
        guard verses[word.id] == nil, let references = word.references,
              !references.isEmpty, let hebrewText = hebrewText(model)
        else { return }
        let shown = Array(references.prefix(Self.shownVerses))
        // The references first, each still waiting for its English and Greek,
        // so they are there to read while the rest is read.
        verses[word.id] = .rows(shown.map { Verse(reference: $0, greek: .pending) })
        let library = model.library
        guard let hebrewNumbering = try? await library.versification(moduleID: hebrewText.id)
        else {
            verses[word.id] = .unreadable(hebrewText.name)
            return
        }

        // The English, from the translation the analysis is of. A read cut
        // short forgets the word's verses, as the Greek's does below, rather
        // than settle every verse as untagged.
        //
        // The numbers need only the two numberings, so every verse is numbered
        // the English way even for a word with no Strong's number to mark it
        // by; only the mark needs the analysis. Without this a key-less word's
        // verses kept the Hebrew numbers, and opened at them.
        var english: [Int: LampSeptuagintSection.English] = [:]
        if let englishID, englishID != hebrewText.id {
            do {
                var analysis: LampStrongsAnalysis?
                if let strongs = word.hebrew.strongs {
                    analysis = try await library.strongsAnalyses(
                        key: strongs, moduleIDs: [englishID], includingVerseText: true
                    ).first
                }
                let numbering = try await library.versification(moduleID: englishID)
                if Task.isCancelled {
                    verses[word.id] = nil
                    return
                }
                english = LampSeptuagintSection.english(
                    for: shown,
                    hebrewNumbering: hebrewNumbering,
                    englishNumbering: numbering,
                    analysis: analysis
                )
            } catch {
                if Task.isCancelled {
                    verses[word.id] = nil
                } else {
                    verses[word.id] = .unreadable(
                        model.translations.first { $0.id == englishID }?.name
                    )
                }
                return
            }
        }
        guard case .rows(let waiting) = verses[word.id], waiting.count == shown.count
        else { return }
        verses[word.id] = .rows(shown.map {
            Verse(
                reference: $0,
                english: english[$0].map(Verse.English.read) ?? .none,
                greek: .pending
            )
        })

        guard let septuagint = await septuagintText(model) else {
            verses[word.id] = .withoutSeptuagint
            return
        }
        septuagintName = septuagint.name
        guard let greekNumbering = try? await library.versification(moduleID: septuagint.id)
        else {
            verses[word.id] = .unreadable(septuagint.name)
            return
        }
        let greek: [Int: String]
        do {
            greek = try await LampSeptuagintSection.greek(
                for: shown,
                hebrewNumbering: hebrewNumbering,
                septuagintNumbering: greekNumbering
            ) { book, chapter in
                let read = try await library.chapter(
                    moduleID: septuagint.id,
                    bookNumber: book,
                    chapterNumber: chapter
                )
                return Dictionary(
                    read.verses.map { ($0.number, $0.text) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
        } catch {
            // Cut short — the group folded, or the pane moved on. Forget the
            // word's verses rather than keep them: a verse not reached would
            // otherwise say the Greek text lacks it, and the empty rows would
            // stay, since a word with verses is never read again.
            verses[word.id] = nil
            return
        }
        guard case .rows(let pending) = verses[word.id], pending.count == shown.count
        else { return }
        verses[word.id] = .rows(pending.map {
            var verse = $0
            verse.greek = greek[$0.reference].map(Verse.Greek.text) ?? .absent
            return verse
        })
    }

    /// The Hebrew Old Testament, by its language rather than by its name.
    private func hebrewText(_ model: LibraryModel) -> LampInstalledModule? {
        model.translations.first { $0.biblicalOriginalLanguage == .hebrew }
    }

    /// The Septuagint among the installed translations: a Greek text that
    /// numbers its verses the Septuagint's way. Its own versification says so,
    /// which an id or a name cannot be trusted to.
    private func septuagintText(_ model: LibraryModel) async -> LampInstalledModule? {
        for module in model.translations where module.biblicalOriginalLanguage == .greek {
            if let numbering = try? await model.library.versification(moduleID: module.id),
               numbering.scheme == .septuagint {
                return module
            }
        }
        return nil
    }
}

struct StrongsAnalysisPane: View {
    enum Section: String, CaseIterable, Identifiable {
        case definition = "Definition"
        case overview = "Overview"
        case spread = "Spread"
        case companions = "Companions"
        case compare = "Compare"
        /// The occurrences themselves, where nothing beside the pane lists
        /// them: the reader's sidebar, which has no room for a second column.
        case verses = "Verses"

        var id: String { rawValue }

        /// Search's sections. Its occurrences have a column of their own.
        static let besideOccurrences: [Section] = [.definition, .overview, .spread, .companions, .compare]
    }

    let key: String
    let loader: StrongsAnalysisLoader
    /// Narrows the verse list only. The figures above it count every
    /// occurrence, and Add to Deck charts them so, unless "Only occurrences…"
    /// is ticked: a figure made to follow this filter would no longer match
    /// the chart its menu adds, and that chart outlives the pane in a deck.
    @Binding var filter: LampStrongsFilter?
    /// Analyses another key, for a companion the reader chooses.
    let analyse: (String) -> Void
    /// Puts another translation's analysis first, for a section that needs a
    /// text whose tags carry what this one's do not: TAGNT's forms and
    /// grammar for a translation that tags only the number. Nil where the
    /// pane cannot change what it analyses first.
    var openIn: ((String) -> Void)? = nil
    /// The books being searched, so the shape can put back the ones the key
    /// never reaches.
    let bookRange: ClosedRange<Int>?
    /// The reader's text size, carried in so the pane's words move with it
    /// rather than sitting at a fixed caption size.
    let fontSize: Double
    /// The sections offered, the first showing to begin with.
    var sections: [Section] = Section.besideOccurrences
    /// One occurrence's row, for a pane that has `.verses` among its
    /// sections. The pane lists them under their heading itself, so the rows
    /// scroll with the card and stay lazy however many a key has.
    var verseRow: ((LampStrongsAnalysis.Occurrence, LampStrongsAnalysis) -> AnyView)? = nil
    /// Behind the section tabs while they hold at the top of the scroll: the
    /// ground of whatever the pane sits on, so content passes under cleanly.
    var pinnedFill: Color = Color(nsColor: .windowBackgroundColor)
    /// The way back to the key a companion was followed from, shown before
    /// the key. Nil where there is none, or where the host draws its own.
    var back: Back? = nil

    struct Back {
        let title: String
        let go: () -> Void
    }

    /// The definition first: it is what someone looking a word up came for,
    /// and the figures are one click away.
    @State private var section: Section?
    /// The dictionary chosen from the Definition's menu, held here rather
    /// than in the tab, which is rebuilt each time it is shown. Kept across
    /// keys, so someone reading one lexicon keeps reading it as they follow
    /// a companion.
    @State private var definitionDictionaryID: String?
    /// The standout book's name as drawn, so the canon strip can place it
    /// by its real width rather than a guess at one.
    @State private var standoutLabelSize: CGSize = .zero
    @State private var spreadGrouping: LampStrongsSpreadGrouping = .books
    @State private var measure: LampStrongsSpreadMeasure = .occurrences
    @State private var openBook: Int?
    /// The slice the pointer is over, named in the ring's hole. Every slice
    /// is a shade of one colour, so matching one to its row by eye is hard.
    /// Set once rather than per search, so it is remembered.
    @AppStorage("strongs.renderingsAsRing") private var renderingsAsRing = true
    @AppStorage("strongs.formsAsRing") private var formsAsRing = true
    /// List or ring, chosen for one word's figure that opened as a list
    /// because one share was nearly all of it. Not stored: the reader's
    /// setting above still decides every other word.
    @State private var ringChoices: [String: Bool] = [:]
    /// Which figures the card prints and what it draws under them, by name.
    /// Per device, as the ring settings above are: which figures a reader
    /// wants at a glance is how one person reads, not something the library
    /// holds about the word.
    @AppStorage("strongs.cardFigures")
    private var storedCardFigures = LampStrongsCardChoice.standard.storedFigures
    @AppStorage("strongs.cardChart")
    private var storedCardChart = LampStrongsCardChoice.standard.storedChart
    @State private var isChoosingCardSlots = false
    /// Each form read for someone without the language, by form ID, with the
    /// analysis it was read from so a new word never shows the last one's.
    @State private var formReadings: (source: String, byID: [String: LampStrongsFormReading])?
    /// What the analysed translation declares was matched to it when its
    /// module was built, by translation ID.
    @State private var translationSources: (id: String, sources: [LampTranslationSource])?
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var septuagint = SeptuagintLoader()
    /// Collapsed to begin with: the Septuagint is a second subject, and what
    /// it holds costs a search a word to work out.
    @State private var isShowingSeptuagint = false
    /// Closed to begin with: where the forms' spellings come from, and what
    /// the tags leave out, read once rather than every time.
    @State private var isShowingFormNotes = false

    /// The analysis the pane describes: the translation being read, which
    /// `LampStrongsAnalysisOrder` keeps at the front.
    private var analysis: LampStrongsAnalysis? { loader.analyses.first }

    private var entry: LampStrongsHeadword? { loader.entries[LampStrongsKey.normalized(key)] }

    /// The card's slots as they are stored, read forgivingly in core so a
    /// name this app does not know leaves the standard three.
    private var cardChoice: LampStrongsCardChoice {
        LampStrongsCardChoice(storedFigures: storedCardFigures, storedChart: storedCardChart)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if loader.isLoadingFirst {
                ProgressView("Analysing \(key)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = loader.errorMessage {
                ContentUnavailableView {
                    Label("Could Not Analyse \(key)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            } else if loader.foundNothing {
                ContentUnavailableView {
                    Label("No Tags for \(key)", systemImage: "tag.slash")
                } description: {
                    Text("No installed translation tags this key in the chosen books.")
                }
            } else if let analysis {
                // The card scrolls away with the content, and the section tabs
                // hold at the top once it has: a card that stayed would take
                // a third of a narrow column from whatever is read under it.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        card(analysis)
                            .task(id: analysis.translationID) {
                                let id = analysis.translationID
                                guard translationSources?.id != id else { return }
                                let sources = (try? await model.library.translationSources(moduleID: id)) ?? []
                                translationSources = (id, sources)
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                        SwiftUI.Section {
                            sectionContent(analysis)
                        } header: {
                            VStack(spacing: 0) {
                                sectionPicker
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                Divider()
                            }
                            .background(pinnedFill)
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 320, idealWidth: 400)
        .onChange(of: filter) { _, chosen in
            // Where the occurrences are a section, choosing a figure has to
            // show them: otherwise the click narrows a list out of sight.
            if chosen != nil, sections.contains(.verses) { section = .verses }
        }
    }

    /// The pane's own tabs, wherever it sits, as the study column's are.
    /// Search used a segmented control here, filled with the accent, and so
    /// drew the same pane two ways and outshouted the figures under it.
    private var sectionPicker: some View {
        UnderlinedTabs(
            label: "Section",
            items: sections.map { ($0, $0.rawValue) },
            selection: Binding(get: { shownSection }, set: { section = $0 }),
            spacing: 14
        )
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The section chosen, or the first offered: a pane that offers no
    /// Definition opens on what it does offer.
    private var shownSection: Section {
        section.flatMap { sections.contains($0) ? $0 : nil } ?? sections.first ?? .overview
    }

    @ViewBuilder
    private func sectionContent(_ analysis: LampStrongsAnalysis) -> some View {
        switch shownSection {
        case .definition:
            StrongsDefinitionView(key: analysis.key, chosenID: $definitionDictionaryID)
        case .overview: overview(analysis)
        case .spread: spread(analysis)
        case .companions: companions(analysis)
        case .compare: compare
        case .verses:
            if let verseRow {
                let shown = analysis.occurrences(matching: filter)
                StrongsOccurrenceHeading(analysis: analysis, shown: shown.count, filter: $filter)
                    .padding(.horizontal, 4)
                Divider()
                // By position: one verse can carry the key twice, and a
                // reference would not tell those two rows apart.
                ForEach(Array(shown.enumerated()), id: \.offset) { _, occurrence in
                    verseRow(occurrence, analysis)
                        .padding(.horizontal, 14)
                    Divider().padding(.leading, 14)
                }
            } else {
                compare
            }
        }
    }

    // MARK: - Card

    /// The analysis opens on a card, as the phone's does: the word large,
    /// what it is called, the three counts that answer "how common is it",
    /// and where in the canon it gathers — taken in at a glance before any
    /// section is read.
    ///
    /// The meaning beside the word is only ever a lexicon's own gloss. A
    /// short definition cut to fit was what this header used to show, and it
    /// read as a sentence broken off.
    private func card(_ analysis: LampStrongsAnalysis) -> some View {
        // A little shorter than it was: in the study column the card took
        // most of the first screen, and the figures under it began below it.
        VStack(alignment: .leading, spacing: 12) {
            if let back {
                // "Back to", as every back row in the app says: a bare key
                // above another key's card read as that card's own name.
                Button(action: back.go) {
                    Label("Back to \(back.title)", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(entry?.lemma.flatMap { $0.isEmpty ? nil : $0 } ?? analysis.key)
                        .font(.system(size: fontSize + 18, weight: .semibold, design: .serif))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .textSelection(.enabled)
                    Text(analysis.key)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.lampTileFill, in: Capsule())
                    PronounceButton(key: analysis.key)
                    Spacer(minLength: 0)
                    cardSlotsButton(analysis)
                    addToDeck(analysis, cardCharts(analysis))
                    if loader.isFillingRest {
                        ProgressView()
                            .controlSize(.small)
                            .help("Analysing the other translations")
                    }
                }
                let transliteration = entry?.transliteration.flatMap { $0.isEmpty ? nil : $0 }
                let gloss = entry?.shortGloss.flatMap { $0.isEmpty ? nil : $0 }
                if transliteration != nil || gloss != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let transliteration {
                            Text(transliteration)
                                .font(.system(size: fontSize + 1, design: .serif).italic())
                                .foregroundStyle(Color.lampSecondaryText)
                        }
                        if let gloss {
                            Text(gloss)
                                .font(.system(size: fontSize + 1, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .textSelection(.enabled)
                }
            }
            let figures = cardChoice.readings(of: analysis)
            if !figures.isEmpty {
                // Spaced, because a tile's value can be a word rather than a
                // number: "97% “lovingkind…” sat against the next tile's
                // figure and the two read as one. ios-56 saw it first at
                // phone width, and the Mac card is no wider than three of
                // these.
                HStack(alignment: .top, spacing: 12) {
                    ForEach(figures) { statTile($0.figure, reading: $0.reading) }
                }
                .accessibilityElement(children: .ignore)
                // The row read as a row. One tile at a time is three numbers
                // where the card says a sentence.
                .accessibilityLabel(cardChoice.spoken(of: analysis))
            }
            if let chart = cardChoice.chart(for: analysis) {
                cardChart(chart, of: analysis)
                    // Only for a card drawing forms: reading every
                    // occurrence is what the Overview defers until it is
                    // opened, and a card showing books should not pay it.
                    .task(id: cardFormsSource(of: analysis)) {
                        guard !cardFormsSource(of: analysis).isEmpty else { return }
                        await loadFormReadings(of: analysis)
                    }
            }
            Text(cardFootnote(analysis))
                .font(.subheadline)
                .foregroundStyle(Color.lampSecondaryText)
            // The whole analysis counts these numbers, so where they were
            // matched to the text is said under the figures they make.
            ForEach(declaredSources(.strongs, for: analysis), id: \.source) { source in
                Text(source.disclosure(
                    translationName: analysis.translationAbbreviation ?? analysis.translationName,
                    strongsKey: analysis.key
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.lampCardFill)
                .overlay {
                    // Lit at one corner by the accent, the one place the
                    // analysis is warmed rather than laid out.
                    RadialGradient(
                        colors: [
                            Color.accentColor.opacity(colorScheme == .dark ? 0.13 : 0.15),
                            Color.accentColor.opacity(0),
                        ],
                        center: .topTrailing,
                        startRadius: 0,
                        endRadius: 300
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.lampCardStroke, lineWidth: 1)
        }
    }

    /// A label over a large figure, the unit small beside it, with what the
    /// figure counts in its tooltip: a number this size is read at a glance,
    /// and a reader who chose it still has to be told what its denominator
    /// is.
    private func statTile(
        _ figure: LampStrongsCardFigure,
        reading: LampStrongsCardFigure.Reading
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(figure.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(reading.value)
                    .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let of = reading.of {
                    Text(of)
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The reading as well as the note, because a long word is truncated
        // on the tile and this is then the only place it can be read whole.
        .help("\(reading.spoken) — \(figure.note)")
    }

    /// The button that opens the card's slots.
    ///
    /// Beside Add to Deck rather than on a tile: a menu that only appears on
    /// the tile it changes is a setting nobody finds, and the chart under the
    /// figures is chosen here too, which no tile owns.
    private func cardSlotsButton(_ analysis: LampStrongsAnalysis) -> some View {
        Button {
            isChoosingCardSlots = true
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .buttonStyle(.borderless)
        .help("Choose this card's figures and chart")
        .accessibilityLabel("Choose this card's figures and chart")
        .popover(isPresented: $isChoosingCardSlots, arrowEdge: .bottom) {
            // Handed its data rather than reading the pane's state: a
            // popover's content can be built from a detached copy of the
            // view, which then never sees a later change.
            CardSlotsChooser(
                available: LampStrongsCardChoice.available(for: analysis),
                charts: LampStrongsGrouping.allCases.filter { $0.canDraw(analysis) },
                standIn: cardChoice.standIn(for: analysis),
                figures: $storedCardFigures,
                chart: $storedCardChart
            )
        }
    }

    /// What the card draws under its figures: the canon strip for books,
    /// which is the one chart whose shape *is* canonical order, and a band of
    /// shares for the rest.
    @ViewBuilder
    private func cardChart(
        _ grouping: LampStrongsGrouping,
        of analysis: LampStrongsAnalysis
    ) -> some View {
        if grouping == .books {
            canonStrip(analysis.books)
        } else {
            let readings = grouping == .forms ? formReadings(of: analysis) : [:]
            CardShareBar(
                divisions: grouping.divisions(of: analysis),
                // By division id, which is the form's place in the list the
                // divisions were made from.
                letters: Dictionary(
                    uniqueKeysWithValues: analysis.forms.enumerated().compactMap { index, form in
                        readings[form.id]?.transliteration.flatMap {
                            $0.isEmpty ? nil : (index, $0)
                        }
                    }
                ),
                choose: choose
            )
        }
    }

    /// The charts the card's Add to Deck offers: the card slide itself,
    /// printing the figures the reader chose, and — where the card is drawing
    /// something a card slide cannot — that chart as a slide of its own.
    ///
    /// A card slide charts books, so without the second chart a reader who
    /// put shares on the card would press Add to Deck and be given a slide
    /// they were not looking at.
    private func cardCharts(_ analysis: LampStrongsAnalysis) -> [AnalysisDeckChart] {
        var charts = [deckChart(
            analysis,
            name: "Headword Card",
            by: .book,
            style: .card,
            figures: cardChoice.figures.map(\.rawValue),
            title: nil
        )]
        guard let grouping = cardChoice.chart(for: analysis), grouping != .books else {
            return charts
        }
        let by: LampPresentationChart.Grouping = switch grouping {
        case .books: .book
        case .sections: .section
        case .renderings: .rendering
        case .forms: .form
        }
        charts.append(deckChart(
            analysis,
            name: grouping.title,
            by: by,
            style: .share,
            title: "\(headword(analysis)) by \(grouping.title.lowercased())"
        ))
        return charts
    }

    /// The rate and the translation counted, under the figures they qualify.
    /// The rate is per tagged *word*, which "per 1,000 tagged words" says,
    /// so it is not read against the verses beside it.
    ///
    /// The rate drops out of the fine print when a figure above prints it:
    /// twice on one card, the second reads as a second measurement.
    private func cardFootnote(_ analysis: LampStrongsAnalysis) -> String {
        let rate = (analysis.ratePerThousandWords * 100).rounded() / 100
        return ([
            cardChoice.showsRate ? nil : "\(rate) per 1,000 tagged words",
            analysis.translationAbbreviation ?? analysis.translationName,
        ] as [String?]).compactMap { $0 }.joined(separator: "\u{00A0}· ")
    }

    private static let stripHeight: Double = 54
    private static let stripLabelBand: Double = 16

    /// One column's drawn height. Used by the bars and by the standout
    /// name's placement, so the name clears the bar that is actually there:
    /// the phone's two disagreed (6 against 4) until they were shared.
    private static func columnHeight(_ occurrences: Int, of most: Int) -> Double {
        occurrences == 0 ? 2 : max(5, stripHeight * Double(occurrences) / Double(most))
    }

    /// The key's spread through the canon at a glance: a column for each book
    /// in order, shaded as the Spread's bars are, over the canon's divisions,
    /// with the tallest column's count as the scale and the book that stands
    /// out most named over its column. A column lists that book's verses.
    private func canonStrip(_ books: [LampStrongsAnalysis.Division]) -> some View {
        let most = max(books.map(\.occurrenceCount).max() ?? 1, 1)
        let gap: Double = books.count > 40 ? 1.5 : 3
        let standout = books.enumerated()
            .filter { $0.element.expectation == .more }
            .max { $0.element.keyness < $1.element.keyness }
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let column = (proxy.size.width - gap * Double(books.count - 1)) / Double(books.count)
                // The scale moves right when the standout book is on the left,
                // so its name never runs into "40 times".
                let scaleOnRight = standout.map {
                    (column + gap) * Double($0.offset) + column / 2 < proxy.size.width / 2
                } ?? false
                ZStack(alignment: .topLeading) {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: Self.stripLabelBand))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: Self.stripLabelBand))
                    }
                    .stroke(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    Text("\(most) \(most == 1 ? "time" : "times")")
                        .font(.system(size: Self.chartFinePrintSize, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: scaleOnRight ? .trailing : .leading)
                    Rectangle()
                        .fill(Color.primary.opacity(0.25))
                        .frame(height: 1)
                        .offset(y: Self.stripLabelBand + Self.stripHeight)
                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(books) { book in
                            let isEmpty = book.occurrenceCount == 0
                            Button {
                                choose(.book(number: book.id))
                            } label: {
                                VStack(spacing: 0) {
                                    Spacer(minLength: 0)
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .fill(isEmpty
                                            ? AnyShapeStyle(Color.primary.opacity(0.12))
                                            : fill(for: book.expectation))
                                        .frame(height: Self.columnHeight(
                                            book.occurrenceCount, of: most
                                        ))
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: Self.stripHeight)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .chartClickable()
                            .disabled(isEmpty)
                            .help("\(book.name): \(book.occurrenceCount)." + Self.listsThese(book.occurrenceCount))
                        }
                    }
                    .frame(height: Self.stripHeight + Self.stripLabelBand, alignment: .bottom)
                    if let standout {
                        // Placed clear of every column it stands over, not
                        // just its own. The name is usually wider than one
                        // column, so centring it over the standout ran it
                        // through a taller neighbour — ἔθνος G1484 in the
                        // ESV, where "Romans" crossed Acts' bar. The rule is
                        // core's, shared with the phone, which found it.
                        let placed = LampStrongsCanonStripLabel.place(
                            labelWidth: standoutLabelSize.width,
                            over: standout.offset,
                            heights: books.map { Self.columnHeight($0.occurrenceCount, of: most) },
                            column: column,
                            spacing: gap,
                            in: proxy.size.width
                        )
                        let columnTop = Self.stripLabelBand + Self.stripHeight - placed.clearing
                        Text(standout.element.name)
                            .font(.system(size: Self.chartFinePrintSize, weight: .bold))
                            .foregroundStyle(.tint)
                            .fixedSize()
                            // Measured rather than guessed: the old clamp
                            // held the centre 40pt from each edge, which
                            // assumed no name wider than 80pt and pushed
                            // "1 Thessalonians" off the chart.
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                                standoutLabelSize = size
                            }
                            .position(
                                x: placed.x,
                                y: max(columnTop - 2 - standoutLabelSize.height / 2,
                                       standoutLabelSize.height / 2)
                            )
                            // Shown once it has been measured. The first
                            // layout pass has no size yet, so the name would
                            // otherwise be drawn at a guess and jump when the
                            // measurement arrived.
                            .opacity(standoutLabelSize == .zero ? 0 : 1)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: Self.stripHeight + Self.stripLabelBand + 2)
            canonDivisions(books, gap: gap)
        }
    }

    /// The canon's divisions under the columns they span, named where three
    /// or more books give the name room.
    private func canonDivisions(_ books: [LampStrongsAnalysis.Division], gap: Double) -> some View {
        var runs: [(name: String, count: Int)] = []
        for book in books {
            let name = LampStrongsAnalysis.canonSections.first { $0.books.contains(book.id) }?.name ?? ""
            if let last = runs.last, last.name == name {
                runs[runs.count - 1].count += 1
            } else {
                runs.append((name, 1))
            }
        }
        return GeometryReader { proxy in
            let column = (proxy.size.width - gap * Double(books.count - 1)) / Double(books.count)
            HStack(alignment: .top, spacing: gap) {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    VStack(spacing: 3) {
                        Capsule()
                            .fill(Color.primary.opacity(0.15))
                            .frame(height: 2)
                        Text(run.count >= 3 ? run.name : "")
                            .font(.system(size: Self.chartFinePrintSize - 1, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(width: max(0, column * Double(run.count) + gap * Double(run.count - 1)))
                }
            }
        }
        .frame(height: 18)
    }

    // MARK: - Overview

    /// The reader's list-or-ring setting, except where one share is nearly
    /// all of the figure: that opens as a list, as on the phone, because the
    /// ring would say only that one thing (core decides when). Switching it
    /// there is remembered for that word, not stored as the setting.
    private func ringBinding(
        _ part: String,
        stored: Binding<Bool>,
        counts: [Int],
        of analysis: LampStrongsAnalysis
    ) -> Binding<Bool> {
        let id = "\(part)|\(analysis.key)|\(analysis.translationID)"
        let isDominated = LampStrongsShare.isDominated(counts)
        return Binding(
            get: { ringChoices[id] ?? (isDominated ? false : stored.wrappedValue) },
            set: { chosen in
                if isDominated { ringChoices[id] = chosen } else { stored.wrappedValue = chosen }
            }
        )
    }

    private func overview(_ analysis: LampStrongsAnalysis) -> some View {
        let renderingsRing = ringBinding(
            "renderings", stored: $renderingsAsRing,
            counts: analysis.renderings.map(\.count), of: analysis
        )
        let formsRing = ringBinding(
            "forms", stored: $formsAsRing,
            counts: analysis.forms.map(\.count), of: analysis
        )
        return VStack(alignment: .leading, spacing: 24) {
            if analysis.isInKeysOwnLanguage {
                group("Translated As") {
                    ownLanguageNote(analysis)
                }
            } else if !analysis.renderings.isEmpty {
                group(
                    "Translated As",
                    note: "What translators reached for, not what the word means.",
                    asRing: renderingsRing,
                    deck: addToDeck(analysis, [deckChart(
                        analysis, name: "Translated As", by: .rendering,
                        style: renderingsRing.wrappedValue ? .share : .bars,
                        title: "How \(translationName(analysis)) translates \(headword(analysis))"
                    )])
                ) {
                    if renderingsRing.wrappedValue {
                        ShareRing(
                            divisions: LampStrongsGrouping.renderings.divisions(of: analysis),
                            // A Greek text translates as its own Greek, said
                            // in Latin letters beside it, as the forms are.
                            details: Dictionary(uniqueKeysWithValues: analysis.renderings.enumerated().map { index, rendering in
                                (index, ShareRing.Detail(aside: LampGreekTransliteration.latinIfGreek(rendering.text)))
                            }),
                            choose: choose
                        )
                    } else {
                        let most = analysis.renderings.map(\.count).max() ?? 0
                        ForEach(analysis.renderings) { rendering in
                            renderingRow(rendering, most: most)
                        }
                    }
                }
            }
            if !analysis.forms.isEmpty || isOriginalLanguageKey(analysis.key) {
                let readings = formReadings(of: analysis)
                group(
                    "Forms",
                    note: LampStrongsFormReading.note(for: analysis, readings: Array(readings.values)),
                    asRing: analysis.forms.isEmpty ? nil : formsRing,
                    // Nothing to chart without forms: a slide of none would be
                    // an empty placeholder.
                    deck: analysis.forms.isEmpty ? nil : addToDeck(analysis, [deckChart(
                        analysis, name: "Forms", by: .form,
                        style: formsRing.wrappedValue ? .share : .bars,
                        title: "The forms of \(headword(analysis))"
                    )])
                ) {
                    formGaps(analysis, readings: readings)
                    if analysis.forms.isEmpty {
                        EmptyView()
                    } else if formsRing.wrappedValue {
                        ShareRing(
                            divisions: LampStrongsGrouping.forms.divisions(of: analysis),
                            details: Dictionary(uniqueKeysWithValues: analysis.forms.enumerated().map { index, form in
                                (index, ShareRing.Detail(
                                    aside: readings[form.id]?.transliteration,
                                    line: formLine(readings[form.id]),
                                    help: readings[form.id]?.parsing
                                ))
                            }),
                            choose: choose
                        )
                    } else {
                        let most = analysis.forms.map(\.count).max() ?? 0
                        ForEach(analysis.forms) { form in
                            chooseRow(
                                title: form.text,
                                aside: readings[form.id]?.transliteration,
                                subtitle: formLine(readings[form.id]),
                                detailHelp: readings[form.id]?.parsing,
                                count: form.count,
                                most: most,
                                isChosen: filter == .form(form.text)
                            ) {
                                choose(.form(form.text))
                            }
                        }
                    }
                }
            }
            if !analysis.grammar.isEmpty {
                group("Grammar", deck: addToDeck(
                    analysis,
                    LampGrammarFeature.allCases
                        .filter { feature in analysis.grammar.contains { $0.feature == feature } }
                        .map { feature in
                            deckChart(
                                analysis, name: feature.title, by: .grammar, feature: feature,
                                title: "\(headword(analysis)) by \(feature.title.lowercased())"
                            )
                        }
                )) {
                    ForEach(LampGrammarFeature.allCases, id: \.self) { feature in
                        let values = analysis.grammar.filter { $0.feature == feature }
                        let most = values.map(\.count).max() ?? 0
                        if !values.isEmpty {
                            Text(feature.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                            ForEach(values, id: \.value) { count in
                                chooseRow(
                                    title: count.value,
                                    count: count.count,
                                    most: most,
                                    isChosen: filter
                                        == .grammar(feature: feature, value: count.value)
                                ) {
                                    choose(.grammar(feature: feature, value: count.value))
                                }
                            }
                        }
                    }
                }
            }
            septuagintGroup(analysis)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .task(id: analysis.key) {
            await septuagint.loadWords(key: analysis.key, model: model)
        }
        .task(id: formsSource(of: analysis)) { await loadFormReadings(of: analysis) }
    }

    /// Reads each form for someone without the language.
    ///
    /// Shared by the Overview, which lists the forms, and by the card when a
    /// reader has put the forms under it: the card is drawn above the
    /// Overview and before it, so a card that waited for the Overview's load
    /// would show its forms without their letters and then gain them when
    /// some other section happened to be opened.
    private func loadFormReadings(of analysis: LampStrongsAnalysis) async {
        let source = formsSource(of: analysis)
        guard formReadings?.source != source else { return }
        // Off the main thread: it reads every occurrence, which for an
        // article or a common verb runs to thousands.
        let readings = await Task.detached(priority: .userInitiated) {
            LampStrongsFormReading.readings(of: analysis)
        }.value
        guard !Task.isCancelled else { return }
        formReadings = (source, Dictionary(readings.map { ($0.form.id, $0) }) { first, _ in first })
    }

    // MARK: - Septuagint

    /// Only for a Greek word the lexicon gives Hebrew for, and collapsed.
    ///
    /// Every heading inside says "Hebrew" and names the Hebrew word, because
    /// these verses are that word's, not this Greek word's: the Septuagint
    /// does not always use this Greek word where that Hebrew stands. Nothing
    /// here is added to the counts above.
    @ViewBuilder
    private func septuagintGroup(_ analysis: LampStrongsAnalysis) -> some View {
        if !septuagint.words.isEmpty {
            DisclosureGroup(isExpanded: $isShowingSeptuagint) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(LampSeptuagintSection.note(greek: entry?.lemma))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    translatesRows
                    // Until the Hebrew text has been counted there are no
                    // verse lists to show, and an empty space reads as none.
                    if septuagint.words.allSatisfy({ $0.references == nil }) {
                        ProgressView().controlSize(.small)
                    }
                    ForEach(septuagint.words) { word in
                        if let references = word.references, !references.isEmpty {
                            SeptuagintWordGroup(
                                word: word,
                                references: references,
                                loader: septuagint,
                                englishID: analysis.translationID,
                                fontSize: fontSize,
                                analyse: analyse
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LampSeptuagintSection.title).lampSectionHeading()
                    // What is inside, before it is opened: the Hebrew words,
                    // and how to say them. Marks around each separator keep
                    // the words in the lexicon's order, left to right,
                    // rather than letting the Hebrew run them as one phrase.
                    Text("\u{200E}" + septuagint.words
                        .map { LampSeptuagintSection.word($0.hebrew) }
                        .joined(separator: "\u{200E}  ·  \u{200E}"))
                        .font(.system(size: fontSize + 1))
                        .lineLimit(1)
                    let said = septuagint.words.compactMap { word in
                        word.hebrew.strongs.flatMap {
                            septuagint.headwords[LampStrongsKey.normalized($0)]?.transliteration
                        }
                    }.filter { !$0.isEmpty }
                    if !said.isEmpty {
                        Text(said.joined(separator: "  ·  "))
                            .font(.system(size: max(10, fontSize - 1)).italic())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .task(id: isShowingSeptuagint) {
                guard isShowingSeptuagint else { return }
                await septuagint.loadCounts(
                    key: analysis.key, englishID: analysis.translationID, model: model
                )
            }
        }
    }

    /// The Hebrew this Greek word renders, each one followable to its own
    /// analysis where it has a number. A word the lexicon could not pin to a
    /// single number is shown plainly rather than left out — it is still what
    /// the Greek translates.
    private var translatesRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(septuagint.words) { word in
                if let strongs = word.hebrew.strongs {
                    Button {
                        analyse(strongs)
                    } label: {
                        hebrewWord(word, number: strongs)
                    }
                    .buttonStyle(.plain)
                    .chartClickable()
                    .help("Analyse \(strongs)")
                } else {
                    hebrewWord(word, number: nil)
                }
            }
        }
    }

    /// The word as someone with no Hebrew reads it — its transliteration and
    /// the English it is most often rendered by — with the Hebrew beside.
    /// Where the translation doesn't render it, the lexicons' meaning goes
    /// under it, unquoted: quoted, a definition would pass for a rendering.
    private func hebrewWord(_ word: SeptuagintLoader.Word, number: String?) -> some View {
        let transliteration = number.flatMap {
            septuagint.headwords[LampStrongsKey.normalized($0)]?.transliteration
        }
        let rendering = septuagint.renderings[word.id]
        let meaning = rendering == nil
            ? number.flatMap { septuagint.meanings[LampStrongsKey.normalized($0)] }
            : nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let transliteration, !transliteration.isEmpty {
                    Text(transliteration)
                        .font(.system(size: fontSize + 1).italic())
                }
                if let rendering {
                    Text("“\(rendering)”")
                        .font(.system(size: fontSize + 1))
                }
                Text(LampSeptuagintSection.word(word.hebrew))
                    .font(.system(size: fontSize + 1))
                    .foregroundStyle(transliteration == nil && rendering == nil ? .primary : .secondary)
                if let number {
                    Text(number)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let meaning {
                Text(meaning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func renderingRow(_ rendering: LampStrongsAnalysis.Rendering, most: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            chooseRow(
                title: rendering.text.isEmpty ? "(no English of its own)" : rendering.text,
                // A Greek text's own Greek, in Latin letters, as its forms.
                aside: LampGreekTransliteration.latinIfGreek(rendering.text),
                count: rendering.count,
                most: most,
                isChosen: filter == .rendering(id: rendering.id, text: rendering.text)
            ) {
                choose(.rendering(id: rendering.id, text: rendering.text))
            }
            if rendering.variants.count > 1 {
                DisclosureGroup("\(rendering.variants.count) variants") {
                    ForEach(rendering.variants, id: \.text) { variant in
                        HStack {
                            Text(variant.text).font(.system(size: max(10, fontSize - 2)))
                            Spacer()
                            Text("\(variant.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
                .padding(.top, 1)
            }
        }
    }

    // MARK: - Spread

    // A chart's own measurements. Deliberately not the reader's text size:
    // these label a drawing rather than being prose, and at reading size
    // they crowd the bars they name. They were the system's caption sizes,
    // which are built for dense UI and were too small to read a chart by.
    /// Book and section names, and the figures beside them.
    private static let chartLabelSize: Double = 13
    /// The finest print a chart has: axis ends, the shade key, the cautions.
    private static let chartFinePrintSize: Double = 12
    /// One row of the chapter grid: the cell plus room for its book's name.
    private static let gridRowHeight: Double = 19
    /// A chapter's cell. Twelve was a speck; these are meant to be aimed at.
    private static let gridCellHeight: Double = 16
    private static let gridCellMaxWidth: Double = 18
    /// A horizontal bar's thickness.
    private static let barHeight: Double = 16
    /// The chapter strip that opens under a bar. It was 7 points wide with
    /// 7-point numbers — the one chart that kept its original size when the
    /// others grew.
    private static let chapterBarWidth: Double = 12
    private static let chapterStripHeight: Double = 56

    /// The grouping the bars stand for. The chapter grid is drawn from books.
    private var activeGrouping: LampStrongsGrouping {
        spreadGrouping.bars ?? .books
    }

    private func divisions(of analysis: LampStrongsAnalysis) -> [LampStrongsChartDivision] {
        activeGrouping.divisions(of: analysis)
    }

    /// Occurrences unless a rate means something here.
    private var chartMeasure: LampStrongsSpreadMeasure {
        spreadGrouping.usesMeasure ? measure : .occurrences
    }

    /// Where the word occurs, by books, sections or chapters, in one light
    /// row of menus.
    ///
    /// How it is drawn follows from what it is grouped by — bars for books
    /// and sections, a grid for chapters — rather than being a third menu.
    /// Bars, columns and a ring were once all on offer here, three drawings
    /// of the same figures; the card's strip is the columns now, and each
    /// bar says its percentage, which was all the ring added.
    private func spread(_ analysis: LampStrongsAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Picker("By", selection: $spreadGrouping) {
                    ForEach(LampStrongsSpreadGrouping.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Where to count it")

                if spreadGrouping.usesMeasure {
                    Picker("Measure", selection: $measure) {
                        ForEach(LampStrongsSpreadMeasure.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("What to count")
                }
                Spacer(minLength: 0)
                addToDeck(analysis, [spreadDeckChart(analysis)])
            }

            if spreadGrouping == .chapters {
                gridChart(analysis)
            } else {
                expectationKey
                barsChart(analysis)
                Text("“More” and “fewer” mean beyond chance, not simply above or "
                    + "below average.")
                    .font(.system(size: Self.chartFinePrintSize))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Bars

    @ViewBuilder
    private func barsChart(_ analysis: LampStrongsAnalysis) -> some View {
        let entries = divisions(of: analysis)
        let bars = LampStrongsSpread.bars(entries.map(\.division), measure: chartMeasure)
        if bars.isEmpty {
            nothingToChart
        }
        // Paired by index rather than zipped: `Array(zip(…))` picks up a
        // GRDB overload here and fails to compile.
        ForEach(bars.indices, id: \.self) { index in
            let bar = bars[index]
            spreadBar(bar, choosing: entries[index].filter)
            if activeGrouping == .books, openBook == bar.id {
                chapterStrip(analysis, book: bar.id)
            }
        }
    }

    // MARK: - Chapters

    /// Every chapter of every book the key reaches, shaded by how often.
    @ViewBuilder
    private func gridChart(_ analysis: LampStrongsAnalysis) -> some View {
        let rows = LampStrongsGrid.rows(from: analysis.books)
        if rows.isEmpty {
            nothingToChart
        } else {
            let busiest = rows.flatMap(\.cells).map(\.occurrenceCount).max() ?? 0
            let longest = max(1, rows.map(\.cells.count).max() ?? 1)
            // One cell size for the whole grid, taken from the longest book.
            // Sizing each row to the full width instead made Philemon's single
            // chapter as wide as Matthew's twenty-eight, so a row's length
            // said nothing about the book — and cell width read as extent.
            VStack(alignment: .leading, spacing: 3) {
                GeometryReader { proxy in
                let cell = max(
                    2,
                    min(Self.gridCellMaxWidth, (proxy.size.width - 96) / Double(longest))
                )
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(rows) { row in
                        HStack(spacing: 5) {
                            Text(row.name)
                                .font(.system(size: Self.chartLabelSize))
                                .lineLimit(1)
                                .frame(width: 90, alignment: .trailing)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 1) {
                                ForEach(row.cells) { chapter in
                                    Button {
                                        choose(.chapter(book: row.id, number: chapter.number))
                                    } label: {
                                        RoundedRectangle(cornerRadius: 1)
                                            .fill(.tint)
                                            // A floor, so one occurrence is
                                            // still visible against the
                                            // background rather than a guess.
                                            .opacity(
                                                chapter.occurrenceCount == 0
                                                    ? 0.07
                                                    : 0.25 + 0.75 * chapter.intensity
                                            )
                                            .frame(width: cell - 1, height: Self.gridCellHeight)
                                    }
                                    .buttonStyle(.plain)
                                    .chartClickable()
                                    .help("\(row.name) \(chapter.number): "
                                        + "\(chapter.occurrenceCount)."
                                        + Self.listsThese(chapter.occurrenceCount))
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        // Pinned, so the height reserved below is the height
                        // actually used. Left to the label's own line height
                        // the rows grew past it and the key underneath was
                        // drawn over the last few books.
                        .frame(height: Self.gridRowHeight)
                    }
                }
            }
            .frame(height: Double(rows.count) * (Self.gridRowHeight + 3))
                // The grid cannot label every cell, so it says what the shade
                // means and at what value it tops out.
                HStack(spacing: 5) {
                    Text("0")
                        .font(.system(size: Self.chartFinePrintSize))
                        .foregroundStyle(.secondary)
                    ForEach([0.07, 0.4, 0.7, 1.0], id: \.self) { step in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(.tint)
                            .opacity(step)
                            .frame(width: 15, height: 12)
                    }
                    Text("\(busiest) in a chapter")
                        .font(.system(size: Self.chartFinePrintSize))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 3)
            }
        }
    }

    private var nothingToChart: some View {
        Text("Nothing to chart in these books.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func spreadBar(
        _ bar: LampStrongsSpreadBar,
        choosing filter: LampStrongsFilter?
    ) -> some View {
        Button {
            guard let filter else { return }
            if case .book(let number) = filter {
                openBook = openBook == number ? nil : number
            }
            choose(filter)
        } label: {
            HStack(spacing: 8) {
                Text(bar.name)
                    .font(.system(size: Self.chartLabelSize))
                    .lineLimit(1)
                    .frame(width: 112, alignment: .trailing)
                // Squared-off ends: a capsule only a few points long drew as a
                // dot, which read as a different kind of mark from the bars.
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(Self.barTrack)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(fill(for: bar.expectation))
                            .frame(width: bar.share > 0
                                ? max(4, proxy.size.width * bar.share)
                                : 0)
                    }
                }
                .frame(height: Self.barHeight)
                Text(measureLabel(bar))
                    .font(.system(size: Self.chartLabelSize, weight: .medium).monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
                if chartMeasure == .occurrences {
                    // Blank beside a zero, which needs no "0%" to say so.
                    Text(bar.occurrenceCount > 0 ? LampStrongsSpread.percent(bar.fractionOfOccurrences) : "")
                        .font(.system(size: Self.chartLabelSize).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                standing(bar.expectation)
                    .frame(width: 18)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chartClickable()
        .help(helpText(bar))
    }

    private func chapterStrip(_ analysis: LampStrongsAnalysis, book: Int) -> some View {
        let chapters = analysis.books.first { $0.id == book }?.chapters ?? []
        let most = chapters.map(\.occurrenceCount).max() ?? 0
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(chapters) { chapter in
                Button {
                    choose(.chapter(book: book, number: chapter.number))
                } label: {
                    VStack(spacing: 3) {
                        Capsule()
                            .fill(filter == .chapter(book: book, number: chapter.number)
                                ? AnyShapeStyle(.tint)
                                : AnyShapeStyle(.tint.opacity(0.5)))
                            .frame(
                                width: Self.chapterBarWidth,
                                height: most > 0
                                    ? max(3, Self.chapterStripHeight
                                        * Double(chapter.occurrenceCount) / Double(most))
                                    : 3
                            )
                        Text("\(chapter.number)")
                            .font(.system(size: Self.chartFinePrintSize))
                            .foregroundStyle(.secondary)
                    }
                    // So the whole column answers the pointer, not just the
                    // few points the bar happens to reach.
                    .frame(height: Self.chapterStripHeight + 18, alignment: .bottom)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .chartClickable()
                .help("Chapter \(chapter.number): \(chapter.occurrenceCount)."
            + Self.listsThese(chapter.occurrenceCount))
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 120)
        .padding(.bottom, 6)
    }

    private func measureLabel(_ bar: LampStrongsSpreadBar) -> String {
        switch chartMeasure {
        case .occurrences: "\(bar.occurrenceCount)"
        case .perThousandWords: String(format: "%.2f", bar.value)
        }
    }

    private func helpText(_ bar: LampStrongsSpreadBar) -> String {
        let standing: String
        switch bar.expectation {
        case .more: standing = " — more than chance would give"
        case .fewer: standing = " — fewer than chance would give"
        case .asExpected: standing = ""
        }
        return "\(bar.name): \(bar.occurrenceCount) in \(bar.wordCount) tagged words\(standing)."
            + Self.listsThese(bar.occurrenceCount)
    }

    /// The three shades are told apart by lightness. On a dark ground the
    /// accent at half strength sinks towards the full accent, so "as
    /// expected" is fainter there, and "fewer" lighter, to keep three steps.
    private func fill(for expectation: LampStrongsAnalysis.Expectation) -> AnyShapeStyle {
        let isDark = colorScheme == .dark
        switch expectation {
        case .more: return AnyShapeStyle(.tint)
        case .fewer: return AnyShapeStyle(Color.primary.opacity(isDark ? 0.5 : 0.32))
        case .asExpected:
            // Lightened on a dark ground, as a share's shades are: faded,
            // it was a maroon barely off its track.
            return isDark
                ? AnyShapeStyle(Color(nsColor: NSColor(Color.accentColor).blended(withFraction: 0.5, of: .white) ?? .systemPink))
                : AnyShapeStyle(.tint.opacity(0.55))
        }
    }

    /// What the three shades and the arrows mean, said once above the bars.
    /// The help on each bar said it, but only to a reader who hovered, and
    /// the grey bars and arrows otherwise had to be guessed at.
    private var expectationKey: some View {
        HStack(spacing: 14) {
            // Short, so the key keeps to one line in the study column; the
            // note under the bars says what "more" and "fewer" are measured
            // against.
            keyItem(.more, "More", arrow: "arrow.up")
            keyItem(.asExpected, "As expected", arrow: nil)
            keyItem(.fewer, "Fewer", arrow: "arrow.down")
            Spacer(minLength: 0)
        }
        .font(.system(size: Self.chartFinePrintSize))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func keyItem(
        _ expectation: LampStrongsAnalysis.Expectation,
        _ title: String,
        arrow: String?
    ) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(fill(for: expectation))
                .frame(width: 14, height: 9)
            Text(title)
            if let arrow {
                Image(systemName: arrow)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(expectation == .more ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        }
    }

    /// Marked in words as well as colour, so the chart does not depend on
    /// telling two shades of the accent colour apart.
    @ViewBuilder
    private func standing(_ expectation: LampStrongsAnalysis.Expectation) -> some View {
        switch expectation {
        case .more:
            Image(systemName: "arrow.up")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tint)
                .help("More than chance would give")
        case .fewer:
            Image(systemName: "arrow.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .help("Fewer than chance would give")
        case .asExpected:
            Color.clear
        }
    }

    // MARK: - Companions

    private func companions(_ analysis: LampStrongsAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !analysis.companions.isEmpty {
                HStack {
                    Spacer(minLength: 0)
                    addToDeck(analysis, [deckChart(
                        analysis, name: "Companions", by: .companion,
                        title: "Words found with \(headword(analysis))"
                    )])
                }
            }
            if analysis.companions.isEmpty {
                Text("No other key shares enough verses with this one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Says what the figure at each row's end is: a bare "7.9×
                // chance" in a corner read as a stray number.
                HStack {
                    Text("Found in its verses, strongest first")
                    Spacer()
                    Text("× as often as chance")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.lampSecondaryText)
                .textCase(.uppercase)
                Divider()
            }
            ForEach(analysis.companions) { companion in
                Button {
                    analyse(companion.key)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(companion.key)
                                .font(.system(size: fontSize, weight: .medium))
                            if let lemma = loader.entries[companion.key]?.lemma {
                                Text(lemma).font(.system(size: fontSize))
                            }
                            Spacer()
                            Text(String(format: "%.1f×", companion.lift))
                                .font(.system(size: fontSize, weight: .medium).monospacedDigit())
                                .foregroundStyle(Color.lampSecondaryText)
                                .help("Shares verses \(String(format: "%.1f", companion.lift)) times as often as chance would give")
                        }
                        if let gloss = loader.entries[companion.key]?.gloss {
                            Text(gloss)
                                .font(.system(size: max(10, fontSize - 2)))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        // The strength the list is ordered by, against the
                        // strongest here: without it the multipliers beside
                        // the rows read as a list sorted badly.
                        HStack(spacing: 8) {
                            CompanionStrength(
                                fraction: LampStrongsCompanionStrength.fraction(
                                    of: companion, among: analysis.companions
                                )
                            )
                            Text("\(companion.sharedVerseCount) shared verses of \(companion.verseCount)")
                                .font(.caption)
                                .foregroundStyle(Color.lampSecondaryText)
                        }
                        .padding(.top, 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .chartClickable()
                .help("Analyse \(companion.key)")
                Divider()
            }
            if !analysis.companions.isEmpty {
                // Without this the figures read as badly sorted. They are
                // ordered by how strongly the association shows, which is not
                // the multiple beside them: σπλάγχνα at 25× chance rests on
                // three shared verses, and πίστις at 9× on twenty-two.
                Text("The bar is each word's strength of association with this one, "
                    + "against the strongest here, and the list follows it. The multiple "
                    + "says how much more often than chance the two share a verse: a high "
                    + "multiple over few verses says less than a smaller one over many.")
                    .font(.subheadline)
                    .foregroundStyle(Color.lampSecondaryText)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Compare

    private var compare: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let analysis {
                HStack {
                    Spacer(minLength: 0)
                    addToDeck(analysis, [deckChart(
                        analysis, name: "Compare", by: .translation,
                        title: "\(headword(analysis)) across translations",
                        caption: "Counts depend on how each translation was tagged"
                    )])
                }
            }
            ForEach(loader.analyses, id: \.translationID) { other in
                // Each row opens the word in that translation, its own
                // Translated As, Forms and Spread with it: the way between
                // translations from any of them, not only from TAGNT.
                let isShown = other.translationID == analysis?.translationID
                let name = other.translationAbbreviation ?? other.translationName
                Group {
                    if !isShown, let openIn {
                        Button {
                            openIn(other.translationID)
                        } label: {
                            compareRow(other, isShown: false)
                        }
                        .buttonStyle(.plain)
                        .chartClickable()
                        .help("Analyse this word in \(name)")
                    } else {
                        compareRow(other, isShown: isShown)
                    }
                }
                Divider()
            }
            if loader.isFillingRest {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Analysing the other translations…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Counts depend on how each translation was tagged, so they are not all measuring the same thing.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func compareRow(_ other: LampStrongsAnalysis, isShown: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(other.translationAbbreviation ?? other.translationName)
                    .font(.system(size: fontSize, weight: .medium))
                if isShown {
                    Text("shown above")
                        .font(.caption)
                        .foregroundStyle(Color.lampSecondaryText)
                }
                Spacer()
                Text("\(other.occurrenceCount) in \(other.verseCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(LampStrongsRenderingSummary.line(of: other))
                .font(.system(size: max(10, fontSize - 2)))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .contentShape(Rectangle())
    }

    /// Where Translated As was, for a text in the word's own language: its
    /// "translations" are its own spellings, which the forms below list, so
    /// it says that and points to Compare, where every translation's
    /// English for the word is.
    private func ownLanguageNote(_ analysis: LampStrongsAnalysis) -> some View {
        let language = LampStrongsKey.normalized(analysis.key).first == "H" ? "Hebrew" : "Greek"
        let name = analysis.translationAbbreviation ?? analysis.translationName
        // Compare can only answer where another translation tags this
        // number. For an Old Testament word in the Septuagint, the English
        // Bibles tag the Hebrew instead, so there may be none, and then the
        // note says so rather than sending the reader to an empty tab.
        let othersTagIt = loader.isFillingRest || loader.analyses.contains {
            $0.translationID != analysis.translationID && $0.occurrenceCount > 0
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(name) is the \(language) text itself, so its words are the forms below. "
                + (othersTagIt
                    ? "How each translation renders it is under Compare."
                    : "No other installed translation tags this word."))
                .font(.subheadline)
                .foregroundStyle(Color.lampSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if othersTagIt {
                Button("Compare Translations") { section = .compare }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Forms

    /// What a form reading is read from: the word, the translation, and how
    /// many occurrences, which changes with the books chosen.
    /// The forms' source when the card is drawing them, and nothing when it
    /// is not, so the task that reads them does not run for every card.
    private func cardFormsSource(of analysis: LampStrongsAnalysis) -> String {
        cardChoice.chart(for: analysis) == .forms ? formsSource(of: analysis) : ""
    }

    private func formsSource(of analysis: LampStrongsAnalysis) -> String {
        "\(analysis.key)|\(analysis.translationID)|\(analysis.occurrenceCount)"
    }

    /// The sources the analysed translation declares for `part`, once they
    /// have been read for it.
    private func declaredSources(
        _ part: LampTranslationSource.Part,
        for analysis: LampStrongsAnalysis
    ) -> [LampTranslationSource] {
        guard let translationSources, translationSources.id == analysis.translationID else { return [] }
        return translationSources.sources.filter { $0.part == part }
    }

    private func isOriginalLanguageKey(_ key: String) -> Bool {
        let first = LampStrongsKey.normalized(key).first
        return first == "G" || first == "H"
    }

    /// The text written in the key's own language whose tags carry what
    /// this translation's lack, among those already analysed: TAGNT for a
    /// Greek key, TAHOT for a Hebrew one. Found by the language a module
    /// declares, not by its name.
    private func originalText(for analysis: LampStrongsAnalysis) -> LampStrongsAnalysis? {
        let languages = LampStrongsKey.normalized(analysis.key).first == "H" ? ["hbo", "he", "arc"] : ["grc"]
        let candidates = loader.analyses.filter { other in
            other.translationID != analysis.translationID
                && !other.forms.isEmpty
                && model.translations.first(where: { $0.id == other.translationID })?.language
                    .map { language in languages.contains { language.lowercased().hasPrefix($0) } } == true
        }
        // The one sharing most of this word's verses, so a Greek Old
        // Testament is not offered for a New Testament word.
        let verses = Set(analysis.references)
        return candidates.max { left, right in
            verses.intersection(left.references).count < verses.intersection(right.references).count
        }
    }

    /// What this translation's tags do not say about the word's forms, and
    /// the text that does, one click away.
    @ViewBuilder
    private func formGaps(_ analysis: LampStrongsAnalysis, readings: [String: LampStrongsFormReading]) -> some View {
        let gaps = LampStrongsFormReading.gaps(of: analysis, readings: Array(readings.values))
        let original = gaps.isEmpty ? nil : originalText(for: analysis)
        // Spellings matched to the text when its module was built are said
        // to be, so they are not read as the translation's own print.
        let matched = analysis.forms.isEmpty ? [] : declaredSources(.forms, for: analysis)
        let showsGaps = !gaps.isEmpty
            && (formReadings?.source == formsSource(of: analysis) || analysis.forms.isEmpty)
        let name = analysis.translationAbbreviation ?? analysis.translationName
        if !matched.isEmpty || showsGaps {
            // Where the spellings come from and what the tags leave out,
            // behind a disclosure as the Septuagint is: set out in full
            // above the figures they were several paragraphs of fine print
            // between the reader and the forms. The disclosure's label
            // stays, so it is still said that there is something to know.
            DisclosureGroup(isExpanded: $isShowingFormNotes) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(matched, id: \.source) { source in
                        Text(source.disclosure(translationName: name, strongsKey: analysis.key))
                    }
                    if showsGaps {
                        ForEach(gaps, id: \.self) { Text($0) }
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            } label: {
                Text(matched.isEmpty
                    ? "What \(name)\u{2019}s tags leave out"
                    : "Where \(name)\u{2019}s spellings come from")
                    .font(.callout)
            }
        }
        if showsGaps, let original, let openIn {
            let originalName = original.translationAbbreviation ?? original.translationName
            Button("Open in \(originalName)") { openIn(original.translationID) }
                .controlSize(.small)
                .help("Analyse \(analysis.key) in \(originalName), whose tags give each spelling and its grammar")
                .padding(.bottom, 6)
        }
    }

    private func formReadings(of analysis: LampStrongsAnalysis) -> [String: LampStrongsFormReading] {
        guard let formReadings, formReadings.source == formsSource(of: analysis) else { return [:] }
        return formReadings.byID
    }

    /// A form's line under its spelling: what it does, and the English it
    /// became, as "“of …” · here “of love”". Only this translation's own:
    /// a Greek or Hebrew text has no English, and none is borrowed.
    private func formLine(_ reading: LampStrongsFormReading?) -> String? {
        guard let reading else { return nil }
        let english = reading.renderedAs.isEmpty
            ? nil
            : "here " + reading.renderedAs.map { "“\($0)”" }.joined(separator: ", ")
        let parts = [reading.role, english].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Deck charts

    /// The word as a title names it.
    /// The word as a slide names it: the word with how to say it, "ἀγάπη
    /// (agapē)", since a slide is mostly read by people without Greek or
    /// Hebrew.
    private func headword(_ analysis: LampStrongsAnalysis) -> String {
        let word = entry?.lemma.flatMap { $0.isEmpty ? nil : $0 } ?? analysis.key
        guard let transliteration = entry?.transliteration.flatMap({ $0.isEmpty ? nil : $0 }) else { return word }
        return "\(word) (\(transliteration))"
    }

    private func translationName(_ analysis: LampStrongsAnalysis) -> String {
        analysis.translationAbbreviation ?? analysis.translationName
    }

    /// The pane's books as a deck chart's range: "Romans", "Matthew-John".
    private var deckRange: String? {
        guard let bookRange else { return nil }
        let first = LampBibleReferenceFormatter.bookName(bookRange.lowerBound)
        guard bookRange.count > 1 else { return first }
        return "\(first)-\(LampBibleReferenceFormatter.bookName(bookRange.upperBound))"
    }

    private func deckChart(
        _ analysis: LampStrongsAnalysis,
        name: String,
        by grouping: LampPresentationChart.Grouping,
        feature: LampGrammarFeature? = nil,
        measure: LampPresentationChart.Measure = .occurrences,
        style: LampPresentationChart.Style? = nil,
        figures: [String]? = nil,
        title: String?,
        caption: String? = nil
    ) -> AnalysisDeckChart {
        AnalysisDeckChart(
            name: name,
            chart: LampPresentationChart(
                source: .init(
                    strongs: analysis.key,
                    // The pane's translation even for a comparison, which
                    // reads `translations` instead: an empty ID would follow
                    // the chart into another grouping in Slide Studio.
                    translationID: analysis.translationID,
                    range: deckRange
                ),
                by: grouping,
                feature: feature,
                measure: measure,
                style: style,
                figures: figures
            ),
            title: title,
            caption: caption ?? ([translationName(analysis), deckRange] as [String?])
                .compactMap { $0 }.joined(separator: " · ")
        )
    }

    /// The Spread as it is drawn: books or sections as bars, measured as
    /// chosen, or chapters as a grid.
    private func spreadDeckChart(_ analysis: LampStrongsAnalysis) -> AnalysisDeckChart {
        let title = "Where \(headword(analysis)) is found"
        return switch spreadGrouping {
        case .books:
            deckChart(analysis, name: "Spread", by: .book, measure: deckMeasure, title: title)
        case .sections:
            deckChart(analysis, name: "Spread", by: .section, measure: deckMeasure, title: title)
        case .chapters:
            deckChart(analysis, name: "Spread", by: .book, style: .grid, title: title)
        }
    }

    private var deckMeasure: LampPresentationChart.Measure {
        measure == .perThousandWords ? .perThousandWords : .occurrences
    }

    private func addToDeck(_ analysis: LampStrongsAnalysis, _ charts: [AnalysisDeckChart]) -> AddToDeckMenu {
        AddToDeckMenu(
            charts: charts,
            filter: filter,
            deckTitle: headword(analysis),
            deckSubtitle: entry?.shortGloss.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: - Pieces

    /// A section of the overview: the shared section heading, with what the
    /// section means said beneath it rather than trailing after.
    /// A titled group, with a List / Ring switch at its heading where
    /// `asRing` is given.
    private func group<Content: View>(
        _ title: String,
        note: String? = nil,
        asRing: Binding<Bool>? = nil,
        deck: AddToDeckMenu? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .lampSectionHeading()
                Spacer(minLength: 8)
                if let deck { deck }
                if let asRing {
                    LampSegmentedPicker("Show \(title) as", selection: asRing, items: [
                        .init(id: false, title: "List"),
                        .init(id: true, title: "Ring"),
                    ])
                    .controlSize(.small)
                    .help("A list to compare, or a ring of each one's part of the whole")
                }
            }
            if let note {
                // A size up and a shade firmer than it was: these say how
                // to read the figure, and at caption size on a dark ground
                // they were the first thing nobody read.
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(Color.lampSecondaryText)
                    .padding(.bottom, 4)
            }
            content()
        }
    }

    /// A row that is also a bar: the figure sits beside its word, and the
    /// bar under the pair gives every count a length to compare by eye.
    /// Right-aligned at the pane's far edge, the figures were too far from
    /// the words they counted to be read across to.
    private func chooseRow(
        title: String,
        aside: String? = nil,
        subtitle: String? = nil,
        detailHelp: String? = nil,
        count: Int,
        most: Int,
        isChosen: Bool,
        choose: @escaping () -> Void
    ) -> some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.system(size: fontSize))
                        .lineLimit(1)
                    if let aside {
                        Text(aside)
                            .font(.system(size: max(10, fontSize - 1), design: .serif).italic())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: 150, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(Self.barTrack)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.tint.opacity(isChosen ? 1 : 0.6))
                            .frame(width: most > 0
                                ? max(3, proxy.size.width * Double(count) / Double(most))
                                : 0)
                    }
                }
                .frame(height: 8)
                Text("\(count)")
                    .font(.system(size: Self.chartLabelSize, weight: .medium).monospacedDigit())
                    .frame(minWidth: 30, alignment: .trailing)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                isChosen ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chartClickable()
        .help("\(title): \(count)." + (detailHelp.map { " \($0)." } ?? "") + Self.listsThese(count))
    }

    /// What a click on a figure does, said in its help, since nothing else on
    /// a chart says it can be clicked. A figure of nought has nothing to list.
    private static func listsThese(_ count: Int) -> String {
        count > 0 ? " Click to list only these." : ""
    }

    /// The empty length behind a bar, a step off the pane in either
    /// appearance: `.quaternary` all but vanished on dark.
    private static var barTrack: Color {
        // A shade firmer on a dark ground, where 8% left an empty track
        // and a short grey bar both near the pane's own colour.
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.12)
                : NSColor.black.withAlphaComponent(0.08)
        })
    }

    /// Choosing the filter already in force removes it, so the same click both
    /// narrows and widens and nobody has to find the chip to get back.
    private func choose(_ next: LampStrongsFilter) {
        guard filter == next else {
            filter = next
            return
        }
        // Choosing the same thing again widens by one step rather than
        // clearing everything. A chapter falls back to its own book, whose
        // strip is still open underneath it — dropping to no filter at all
        // left the reader looking at a book's chapters while the list showed
        // every occurrence in the Bible.
        filter = next.widened
    }
}

/// A key's whole entry, from one dictionary at a time.
///
/// Opens on the default dictionary for the key's language — the one Settings
/// names and the study pane opens on — so a word reads the same here as it
/// does beside the reader. The menu lists only dictionaries that hold an
/// entry for the key: one with nothing to say about it is not a choice.
/// One Hebrew word's Old Testament verses, with the Septuagint's Greek beside
/// each — the heart of the Septuagint section, and its own view for one
/// reason: it must load when *it* is opened, not when the section is, and a
/// DisclosureGroup can only tell its own expansion to a view that holds it.
private struct SeptuagintWordGroup: View {
    let word: SeptuagintLoader.Word
    /// Every verse the word stands in, which is the count in the heading even
    /// when only the first few are listed.
    let references: [Int]
    let loader: SeptuagintLoader
    /// The translation whose English the verses are shown in: the one the
    /// analysis is of.
    let englishID: String?
    let fontSize: Double
    let analyse: (String) -> Void

    @EnvironmentObject private var model: LibraryModel
    @Environment(\.readerReferenceActions) private var referenceActions
    @State private var isExpanded = false

    private var listed: SeptuagintLoader.Verses? { loader.verses[word.id] }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let listed {
                    switch listed {
                    case .rows(let rows):
                        ForEach(rows) { verse in
                            row(verse)
                        }
                        // One spinner for the list, not one per row: the Greek
                        // arrives for every verse at once, when the last
                        // chapter has been read.
                        if rows.contains(where: { $0.greek == .pending || $0.english == .pending }) {
                            ProgressView().controlSize(.small)
                        }
                        allVerses(beyond: rows.count)
                    case .withoutSeptuagint:
                        note(LampSeptuagintSection.withoutSeptuagint)
                        allVerses(beyond: 0)
                    case .unreadable(let name):
                        note(LampSeptuagintSection.unreadable(name))
                        allVerses(beyond: 0)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        } label: {
            Text(LampSeptuagintSection.heading(
                word.hebrew,
                transliteration: word.hebrew.strongs.flatMap {
                    loader.headwords[LampStrongsKey.normalized($0)]?.transliteration
                },
                rendering: loader.renderings[word.id],
                verses: references.count
            ))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .task(id: isExpanded) {
            guard isExpanded else { return }
            await loader.loadVerses(for: word, englishID: englishID, model: model)
        }
    }

    /// The way to the word's whole list, where more of it stands than is shown
    /// here. Shown for the bare outcomes too: there the verses are all
    /// elsewhere, and the Hebrew word's own analysis is where they are.
    @ViewBuilder
    private func allVerses(beyond shown: Int) -> some View {
        if references.count > shown, let strongs = word.hebrew.strongs {
            Button("All \(references.count) verses in \(strongs)") {
                analyse(strongs)
            }
            .buttonStyle(.link)
            .font(.caption)
            .chartClickable()
            .padding(.top, 2)
        }
    }

    /// Said once, in place of the verses.
    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The verse in English with the word marked, and the Greek under it,
    /// opening the verse in the reader as the analysis's own verses do.
    ///
    /// The reference is the English one once the English is read: that is
    /// the number a reader of the English looks it up by, and opens it at.
    private func row(_ verse: SeptuagintLoader.Verse) -> some View {
        let opens: Int
        if case .read(let english) = verse.english {
            opens = english.reference
        } else {
            opens = verse.reference
        }
        let name = reference(opens)
        // Not before its English is read: until then its number may be the
        // Hebrew one, and the reader would open on the wrong verse. Refused in
        // the action rather than disabled, which would dim every row while
        // the list loads.
        let isKnown = verse.english != .pending
        return Button {
            guard isKnown else { return }
            referenceActions.openInCurrent(opens)
        } label: {
            rowContent(verse)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chartClickable()
        // Silent until the click would work: before its English is read the
        // number may be the Hebrew one, and the click is refused.
        .help(isKnown ? "Open \(name) in the reader" : "")
        .contextMenu {
            if isKnown {
                Button("Open \(name)") { referenceActions.openInCurrent(opens) }
            }
            if isKnown, referenceActions.opensTabs {
                Button("Open in New Tab", systemImage: "plus.square.on.square") {
                    referenceActions.openInNewTab(opens)
                }
            }
        }
    }

    private func rowContent(_ verse: SeptuagintLoader.Verse) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            switch verse.english {
            case .read(let english):
                Text(reference(english.reference))
                    .font(.caption.weight(.semibold))
                if let snippet = english.snippet {
                    (Text(snippet.isTrimmedAtStart ? "…" : "")
                        + Text(snippet.before)
                        + Text.lampFindMatch(snippet.word)
                        + Text(snippet.after)
                        + Text(snippet.isTrimmedAtEnd ? "…" : ""))
                        .font(.system(size: fontSize))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .none, .pending:
                Text(reference(verse.reference))
                    .font(.caption.weight(.semibold))
            }
            switch verse.greek {
            case .text(let greek):
                Text(greek)
                    .font(.system(size: max(10, fontSize - 1), design: .serif))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .absent:
                Text(LampSeptuagintSection.missingVerse(in: loader.septuagintName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .pending:
                // Nothing yet. The reference is worth reading on its own, and
                // anything said about the Greek here would be a guess.
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reference(_ reference: Int) -> String {
        let parts = LampBibleReferenceFormatter.components(of: reference)
        return "\(LampBibleReferenceFormatter.bookName(parts.book)) "
            + "\(parts.chapter):\(parts.verse)"
    }
}

struct StrongsDefinitionView: View {
    let key: String
    @Binding var chosenID: String?

    @EnvironmentObject private var model: LibraryModel
    @AppStorage("commentary.fontSize") private var fontSize = LampTextScale.commentaryText.defaultValue
    @AppStorage("commentary.lineSpacing") private var lineSpacing = LampTextScale.commentaryLineSpacing.defaultValue
    @AppStorage("commentary.typeface") private var typeface = ProseTypeface.commentaryDefault
    @AppStorage("studyInspector.greekDictionaryModuleID") private var preferredGreekID = ""
    @AppStorage("studyInspector.hebrewDictionaryModuleID") private var preferredHebrewID = ""
    @State private var entries: [LampDictionaryResult] = []
    /// The key `entries` answers, so an empty list reads as "no entry" only
    /// once it has been asked, never while the lookup is still on its way.
    @State private var answeredKey: String?
    @State private var errorMessage: String?

    private var language: BiblicalOriginalLanguage? { .inferred(from: key) }

    /// The dictionaries for the key's language, or every one when it has
    /// none — the language's preferred ones first, then the library's order.
    ///
    /// The order decides the default, since `shownID` falls back to the first
    /// of these that has an entry. Leaving it to the alphabet made Dodson the
    /// default Greek dictionary for anyone who had not chosen one.
    private var candidates: [LampInstalledModule] {
        let matching = model.dictionaries.filter { $0.biblicalOriginalLanguage == language }
        guard let language, !matching.isEmpty else { return model.dictionaries }
        return LampModuleSelection.ordered(
            matching, preferredIDs: language.preferredDictionaryIDs, id: \.id
        )
    }

    private var withEntries: [LampInstalledModule] {
        candidates.filter { module in entries.contains { $0.moduleID == module.id } }
    }

    private var shownID: String? {
        let preferred = switch language {
        case .greek: preferredGreekID
        case .hebrew: preferredHebrewID
        case nil: ""
        }
        return LampStrongsDefinitionChoice.shown(
            among: withEntries.map(\.id),
            chosen: chosenID,
            preferred: preferred.isEmpty ? nil : preferred
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let errorMessage {
                ContentUnavailableView(
                    "Lookup Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if answeredKey != key {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 30)
            } else if let shownID {
                dictionaryMenu(shownID)
                let shown = entries.filter { $0.moduleID == shownID }
                ForEach(shown) { entry in
                    DictionaryResultView(
                        result: entry,
                        isExpanded: true,
                        // One entry is simply the word, which the menu and
                        // the pane's header already name. Several — a key
                        // mapped onto more than one headword — each need
                        // their own name to be told apart.
                        showsSummary: shown.count > 1,
                        fontSize: LampTextScale.commentaryText.clamped(fontSize),
                        lineSpacing: LampTextScale.commentaryLineSpacing.clamped(lineSpacing),
                        typeface: typeface
                    )
                }
            } else {
                ContentUnavailableView(
                    "Not in Any Dictionary",
                    systemImage: "character.book.closed",
                    description: Text(model.dictionaries.isEmpty
                        ? "Install a dictionary from Modules to read what \(key) means."
                        : "No installed dictionary has an entry for \(key).")
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: key) { await load() }
    }

    @ViewBuilder
    private func dictionaryMenu(_ shownID: String) -> some View {
        if withEntries.count > 1 {
            Picker("Dictionary", selection: Binding(
                get: { shownID },
                set: { chosenID = $0 }
            )) {
                ForEach(withEntries) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Read this word in another dictionary")
        } else if let name = withEntries.first?.name {
            Text(name)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    /// The key as given, as normalized, and as any bundled mapping names it
    /// in another lexicon (Strong's Hebrew to BDB), the way the study pane
    /// looks a word up.
    private func load() async {
        errorMessage = nil
        do {
            let mapped = try await model.lexiconMappings(sourceKey: key)
            let found = try await model.library.dictionaryEntries(
                keys: [key, StrongsKey.normalized(key)] + mapped,
                moduleIDs: Set(candidates.map(\.id))
            )
            try Task.checkCancellation()
            entries = found
            answeredKey = key
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            entries = []
            answeredKey = key
        }
    }
}

private extension View {
    /// Marks something in a chart as clickable.
    ///
    /// Without it the pointer stays an I-beam over a bar or a cell, which
    /// says "text to select" — the opposite of the truth, and the reason
    /// nobody would guess a bar can be clicked at all.
    func chartClickable() -> some View {
        pointerStyle(.link)
    }
}

/// One wedge of a donut, as a fraction of the whole turn.
///
/// Drawn from twelve o'clock clockwise, which is where a reader expects a
/// share to start.
/// A companion's strength of association, as a share of the strongest
/// listed: a short bar in the accent, named, as on the phone.
private struct CompanionStrength: View {
    let fraction: Double

    var body: some View {
        HStack(spacing: 5) {
            // Wide and thick enough to compare down the list: at 44 by 4
            // points the panel found it a hairline nobody could read.
            Capsule()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 64, height: 6)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.tint)
                        .frame(width: max(6, 64 * fraction), height: 6)
                }
            Text("strength")
                .font(.subheadline)
                .foregroundStyle(Color.lampSecondaryText)
        }
        .help("Strength of association, against the strongest here: the order of this list")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Strength of association")
        .accessibilityValue("\(Int((fraction * 100).rounded()))% of the strongest")
    }
}

/// A share's shade of the accent: the largest full, each smaller one
/// paler. In light mode the accent is faded towards the white ground. On a
/// dark ground fading darkens it, to maroons too alike to match a slice to
/// its key, so there it is lightened towards white instead, which keeps the
/// same order of steps from strong to pale that light mode shows.
private struct ShareShade: ViewModifier {
    let strength: Double
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if colorScheme == .dark {
            content.brightness((1 - strength) * 0.55)
        } else {
            content.opacity(strength)
        }
    }
}

private extension View {
    func shareShade(_ strength: Double) -> some View {
        modifier(ShareShade(strength: strength))
    }
}

private struct DonutSlice: Shape {
    /// Where this wedge begins, 0...1 of the turn.
    let start: Double
    /// How much of the turn it covers.
    let extent: Double
    var thickness: Double = 0.38

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * (1 - thickness)
        let from = Angle.degrees(start * 360 - 90)
        let to = Angle.degrees((start + extent) * 360 - 90)

        var path = Path()
        guard inner > 0.5 else {
            // A solid pie: a wedge from the centre, since an arc of radius
            // nothing draws nothing and would leave the slice open.
            path.move(to: centre)
            path.addArc(center: centre, radius: outer, startAngle: from, endAngle: to, clockwise: false)
            path.closeSubpath()
            return path
        }
        path.addArc(center: centre, radius: outer, startAngle: from, endAngle: to, clockwise: false)
        path.addArc(center: centre, radius: inner, startAngle: to, endAngle: from, clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// A word's renderings or forms as a ring: each one's part of the whole.
///
/// Every slice is named beside the ring with its count and percentage, so
/// nothing is carried by colour alone — the slices are one hue at different
/// strengths. Its own view so each ring keeps its own hover: two rings on
/// one page shared it, and slice IDs, which are positions, matched across
/// them.
/// Which figures the card prints, and what it draws under them.
///
/// Only what this word can answer is offered. A slot set to Forms on a word
/// that has none would draw nothing, and a chooser that offers it anyway
/// reads as a card that is broken rather than a word with no forms. A figure
/// already in another slot trades places with it instead of appearing twice.
private struct CardSlotsChooser: View {
    let available: [LampStrongsCardFigure]
    let charts: [LampStrongsGrouping]
    /// What the card draws in the chosen chart's place, here: Forms for a
    /// Translated As in a text in the word's own language (core decides).
    var standIn: LampStrongsGrouping? = nil
    @Binding var figures: String
    @Binding var chart: String

    private static let slotNames = ["First", "Second", "Third"]
    private static let labelWidth: Double = 56

    var body: some View {
        let chosen = LampStrongsCardChoice(storedFigures: figures, storedChart: chart)
        VStack(alignment: .leading, spacing: 10) {
            Text("Figures")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(0 ..< LampStrongsCardChoice.slots, id: \.self) { slot in
                slotRow(slot, in: chosen)
            }
            Divider()
            chartRow
            if available.count < LampStrongsCardFigure.allCases.count {
                Text("Figures this word has no answer for aren’t offered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        // A popover has no size of its own, and its content measured by a
        // picker's widest row jumps as the word changes.
        .frame(width: 300)
    }

    private func slotRow(_ slot: Int, in chosen: LampStrongsCardChoice) -> some View {
        let held = figure(at: slot, in: chosen)
        return HStack(spacing: 8) {
            Text(Self.slotNames[min(slot, Self.slotNames.count - 1)])
                .font(.callout)
                .frame(width: Self.labelWidth, alignment: .leading)
            Picker(
                "",
                selection: Binding(
                    get: { held },
                    set: { put($0, at: slot, in: chosen) }
                )
            ) {
                ForEach(offered(at: slot, in: chosen)) { figure in
                    Text(title(of: figure)).tag(figure)
                }
            }
            .labelsHidden()
            .help(held.note)
        }
    }

    private var chartRow: some View {
        HStack(spacing: 8) {
            Text("Chart")
                .font(.callout)
                .frame(width: Self.labelWidth, alignment: .leading)
            Picker("", selection: $chart) {
                ForEach(offeredCharts, id: \.tag) { Text($0.title).tag($0.tag) }
            }
            .labelsHidden()
            .help("What the card draws under its figures")
        }
    }

    /// The charts this word can draw, the stored one where it cannot be drawn
    /// — so the menu shows what is actually set rather than going blank — and
    /// no chart at all.
    private var offeredCharts: [(tag: String, title: String)] {
        var offered = charts.map { (tag: $0.rawValue, title: $0.title) }
        if chart != LampStrongsCardChoice.noChart,
           !charts.contains(where: { $0.rawValue == chart }) {
            let title = LampStrongsGrouping(rawValue: chart)?.title ?? chart
            offered.append((
                tag: chart,
                // Says what the card draws instead, where it draws anything.
                title: title + (standIn.map { " (\($0.title) here)" } ?? " (none)")
            ))
        }
        offered.append((tag: LampStrongsCardChoice.noChart, title: "None"))
        return offered
    }

    /// Short, because it has to fit a picker in a popover: a longer way of
    /// saying it truncates, and a truncated row says nothing at all.
    private func title(of figure: LampStrongsCardFigure) -> String {
        available.contains(figure) ? figure.title : "\(figure.title) (none)"
    }

    private func figure(at slot: Int, in chosen: LampStrongsCardChoice) -> LampStrongsCardFigure {
        if chosen.figures.indices.contains(slot) { return chosen.figures[slot] }
        return offered(at: slot, in: chosen).first ?? .occurrences
    }

    private func offered(
        at slot: Int,
        in chosen: LampStrongsCardChoice
    ) -> [LampStrongsCardFigure] {
        guard chosen.figures.indices.contains(slot) else { return available }
        let held = chosen.figures[slot]
        return available.contains(held) ? available : available + [held]
    }

    private func put(
        _ figure: LampStrongsCardFigure,
        at slot: Int,
        in chosen: LampStrongsCardChoice
    ) {
        var slots = chosen.figures
        // Only reachable from a hand-edited setting, and filled rather than
        // refused so the chooser can always write a full row.
        while slots.count <= slot {
            slots.append(LampStrongsCardFigure.allCases.first { !slots.contains($0) } ?? .occurrences)
        }
        if let held = slots.firstIndex(of: figure), held != slot {
            // Two slots counting one thing is a card printing a number
            // twice, so the figures trade places.
            slots.swapAt(held, slot)
        } else {
            slots[slot] = figure
        }
        figures = LampStrongsCardChoice(figures: slots, chart: chosen.chart).storedFigures
    }
}

/// A grouping's shares as one band under the card's figures, with a key: a
/// segment for each slice, largest first, in the ring's own shades and under
/// the ring's own "six largest and Other" rule, so the card and the section
/// below it never disagree about what the slices are.
///
/// The key is under the band rather than beside it, which the Mac has room
/// for, because the phone has no such room and the card should be one object
/// on both. Names go beneath rather than inside the segments: a name inside
/// would wear its segment's colour and lose contrast as the shades fade.
/// Each named slice narrows the verses as the strip's columns do; "Other" is
/// a leftover rather than a value, so it narrows nothing.
private struct CardShareBar: View {
    let divisions: [LampStrongsChartDivision]
    /// A form in Latin letters, by division id, where the band is of forms.
    var letters: [Int: String] = [:]
    let choose: (LampStrongsFilter) -> Void

    private static let height: Double = 26
    private static let gap: Double = 2
    private static let type: Double = 11.5

    var body: some View {
        let slices = LampStrongsShare.slices(from: divisions.map(\.division))
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { proxy in
                let room = proxy.size.width - Self.gap * Double(max(slices.count - 1, 0))
                HStack(spacing: Self.gap) {
                    ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                        segment(slice, index: index, of: slices.count, width: max(2, room * slice.fraction))
                    }
                }
            }
            .frame(height: Self.height)
            // Ignored as a whole and said once: the segments are a drawing,
            // and the key under them is what a reader acts on.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(slices.map { "\($0.name) \($0.value)" }.joined(separator: ", "))
            WrappingRow(spacing: 10) {
                ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                    key(slice, index: index, of: slices.count)
                }
            }
        }
    }

    /// One slice named: its shade, its name, the letters where it is a form,
    /// and its share of everything charted — which is not its share of the
    /// six named ones, since "Other" holds the rest and the named six do not
    /// come to a hundred.
    private func key(_ slice: LampStrongsShare.Slice, index: Int, of count: Int) -> some View {
        let isLargest = index == 0 && !slice.isOther
        return choosable(slice) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(.tint)
                    .shareShade(opacity(index, of: count, isOther: slice.isOther))
                    .frame(width: 9, height: 9)
                Text(slice.name)
                    .font(.system(size: Self.type, weight: isLargest ? .bold : .regular))
                    .foregroundStyle(isLargest ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary))
                    .lineLimit(1)
                if let letters = Int(slice.id).flatMap({ letters[$0] }) {
                    Text(letters)
                        .font(.system(size: Self.type).italic())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(LampStrongsSpread.percent(slice.fraction))
                    .font(.system(size: Self.type, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .help("\(slice.name): \(slice.value) · \(LampStrongsSpread.percent(slice.fraction))")
        .accessibilityLabel("\(slice.name), \(slice.value), \(LampStrongsSpread.percent(slice.fraction))")
    }

    private func segment(
        _ slice: LampStrongsShare.Slice,
        index: Int,
        of count: Int,
        width: Double
    ) -> some View {
        choosable(slice) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.tint)
                .shareShade(opacity(index, of: count, isOther: slice.isOther))
                .frame(width: width, height: Self.height)
                .contentShape(Rectangle())
        }
        .help("\(slice.name): \(slice.value) · \(LampStrongsSpread.percent(slice.fraction))")
    }

    /// A button only where there is something to choose.
    ///
    /// A disabled button draws grey, and no section carries a filter — no
    /// single one says "these books" — so a band of sections came out grey
    /// from end to end and read as a chart that had failed rather than one
    /// that simply is not clickable. "Other" is a leftover rather than a
    /// value and has no filter either; its faint swatch is what marks it,
    /// not grey text. (ios-56 hit this first.)
    @ViewBuilder
    private func choosable(
        _ slice: LampStrongsShare.Slice,
        @ViewBuilder content: () -> some View
    ) -> some View {
        if let filter = filter(for: slice) {
            Button { choose(filter) } label: { content() }
                .buttonStyle(.plain)
                .chartClickable()
        } else {
            content()
        }
    }

    private func filter(for slice: LampStrongsShare.Slice) -> LampStrongsFilter? {
        guard !slice.isOther else { return nil }
        return divisions.first { String($0.division.id) == slice.id }?.filter
    }

    /// One hue, strongest for the largest slice, as the ring has it.
    private func opacity(_ index: Int, of count: Int, isOther: Bool) -> Double {
        guard !isOther else { return 0.2 }
        guard count > 1 else { return 1 }
        // Across three quarters of the range, as on the phone: five shades
        // over 60% were too alike to match a slice to its key.
        return 1 - 0.75 * (Double(index) / Double(count - 1))
    }
}

private struct ShareRing: View {
    /// More about a slice than its name, for a figure that needs reading:
    /// a form's Latin letters beside it, and what it does under it.
    struct Detail {
        var aside: String?
        var line: String?
        var help: String?
    }

    let divisions: [LampStrongsChartDivision]
    /// By division ID.
    var details: [Int: Detail] = [:]
    let choose: (LampStrongsFilter) -> Void

    @State private var hovered: LampStrongsShare.Slice?

    private static let size: Double = 164
    /// The ring's share of its radius.
    private static let thickness: Double = 0.38

    var body: some View {
        let slices = LampStrongsShare.slices(from: divisions.map(\.division))
        // Side by side where the column allows, the legend under the ring
        // where it does not.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                ring(slices)
                legend(slices).frame(minWidth: 180)
            }
            VStack(alignment: .leading, spacing: 14) {
                ring(slices)
                legend(slices)
            }
        }
        .padding(.vertical, 4)
    }

    /// The filter a slice stands for. Found by ID, not position: slices are
    /// ranked by count and "Other" stands for several.
    private func filter(for slice: LampStrongsShare.Slice) -> LampStrongsFilter? {
        guard !slice.isOther else { return nil }
        return divisions.first { String($0.division.id) == slice.id }?.filter
    }

    private func index(at point: CGPoint, among slices: [LampStrongsShare.Slice]) -> Int? {
        LampStrongsShareHit.index(
            at: point,
            in: CGSize(width: Self.size, height: Self.size),
            fractions: slices.map(\.fraction),
            thickness: Self.thickness
        )
    }

    private func ring(_ slices: [LampStrongsShare.Slice]) -> some View {
        ZStack {
            ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                DonutSlice(
                    start: slices.prefix(index).reduce(0) { $0 + $1.fraction },
                    extent: slice.fraction,
                    thickness: Self.thickness
                )
                .fill(.tint)
                .shareShade(opacity(index, of: slices.count, isOther: slice.isOther))
                // The others recede rather than vanish, so the ring keeps
                // its shape while one slice is picked out. Not too far: at a
                // tenth the ring read as empty, and a 1% slice was then the
                // only thing on it.
                .opacity(hovered == nil || hovered?.id == slice.id ? 1 : 0.35)
                // A hairline of the ground between slices: shades of one
                // colour run together, and a 1% slice beside another was
                // one band.
                .overlay {
                    if slices.count > 1 {
                        DonutSlice(
                            start: slices.prefix(index).reduce(0) { $0 + $1.fraction },
                            extent: slice.fraction,
                            thickness: Self.thickness
                        )
                        .stroke(.background, lineWidth: 1.5)
                    }
                }
            }
            // The hole holds the total, the one number a share otherwise
            // leaves you to add up.
            VStack(spacing: 0) {
                if let hovered {
                    Text(hovered.name)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text("\(hovered.value)")
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text(LampStrongsSpread.percent(hovered.fraction))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(slices.reduce(0) { $0 + $1.value })")
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text("in all").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 92)
            .animation(.easeOut(duration: 0.12), value: hovered?.id)
        }
        .frame(width: Self.size, height: Self.size)
        .contentShape(Rectangle())
        // One hover for the whole ring, worked out by angle: `.contentShape`
        // on a wedge did not narrow what `.onHover` reported, so every slice
        // answered for the whole square.
        .onContinuousHover { phase in
            guard case .active(let point) = phase else {
                hovered = nil
                return
            }
            hovered = index(at: point, among: slices).map { slices[$0] }
        }
        .onTapGesture { point in
            guard let index = index(at: point, among: slices),
                  let filter = filter(for: slices[index]) else { return }
            choose(filter)
        }
        // Only over a wedge, so the pointer does not promise a click in the
        // hole or the corners.
        .pointerStyle(hovered.flatMap(filter(for:)) == nil ? nil : .link)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(slices.map { "\($0.name) \($0.value)" }.joined(separator: ", "))
    }

    private func legend(_ slices: [LampStrongsShare.Slice]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                Button {
                    if let filter = filter(for: slice) { choose(filter) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.tint)
                            .shareShade(opacity(index, of: slices.count, isOther: slice.isOther))
                            .frame(width: 10, height: 10)
                            .overlay {
                                if hovered?.id == slice.id {
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(.primary, lineWidth: 1.5)
                                }
                            }
                        Text(slice.name).font(.callout).lineLimit(1)
                        if let aside = detail(for: slice)?.aside {
                            Text(aside)
                                .font(.system(.callout, design: .serif).italic())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text("\(slice.value)")
                            .font(.callout.monospacedDigit())
                        Text(LampStrongsSpread.percent(slice.fraction))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                    if let line = detail(for: slice)?.line {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(filter(for: slice) == nil)
                .help(detail(for: slice)?.help ?? "")
                .onHover { hovered = $0 ? slice : nil }
            }
        }
    }

    private func detail(for slice: LampStrongsShare.Slice) -> Detail? {
        Int(slice.id).flatMap { details[$0] }
    }

    /// One hue, strongest for the largest slice. "Other" is always faintest,
    /// because it is a leftover rather than a finding.
    private func opacity(_ index: Int, of count: Int, isOther: Bool) -> Double {
        guard !isOther else { return 0.2 }
        guard count > 1 else { return 1 }
        // Across three quarters of the range, as on the phone: five shades
        // over 60% were too alike to match a slice to its key.
        return 1 - 0.75 * (Double(index) / Double(count - 1))
    }
}

// MARK: - Occurrences

/// What an occurrence list holds and what narrowed it, with the chip that
/// widens it again.
///
/// Above the list rather than in the pane whose figure was clicked: the reader
/// clicks there and reads the effect here. One height with or without the
/// chip, so the rows under it don't move when a figure is chosen.
struct StrongsOccurrenceHeading: View {
    let analysis: LampStrongsAnalysis
    let shown: Int
    @Binding var filter: LampStrongsFilter?

    var body: some View {
        HStack(spacing: 6) {
            Text(LampStrongsFilter.heading(
                shown: shown,
                total: analysis.occurrenceCount,
                narrowed: filter != nil
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if let filter {
                Button {
                    self.filter = nil
                } label: {
                    HStack(spacing: 5) {
                        Text(filter.narrowing).lineLimit(1)
                        Image(systemName: "xmark.circle.fill")
                            .imageScale(.small)
                    }
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(.tint.opacity(0.22), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help("Show every occurrence again")
            }
            Spacer(minLength: 6)
            Text(analysis.translationAbbreviation ?? analysis.translationName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(height: 24)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// One occurrence: where it is, the form there, and the verse around it.
struct StrongsOccurrenceLabel: View {
    let occurrence: LampStrongsAnalysis.Occurrence
    /// The verse, where the analysis kept it. Only the translation being read
    /// keeps its verses.
    let verse: String?
    let fontSize: Double

    static func reference(_ reference: Int) -> String {
        let parts = LampBibleReferenceFormatter.components(of: reference)
        return "\(LampBibleReferenceFormatter.bookName(parts.book)) \(parts.chapter):\(parts.verse)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(Self.reference(occurrence.reference))
                    .font(.system(size: fontSize, weight: .medium))
                Spacer()
                if let form = occurrence.form, !form.isEmpty {
                    Text(form)
                        .font(.callout)
                        .foregroundStyle(Color.lampSecondaryText)
                }
            }
            if let verse {
                // The outer style is the default for spans that set none, so
                // the tagged word keeps the mark it was given. Scripture in
                // the text's own colour, as every search result shows it: in
                // the system grey these were the faintest verses in the app.
                snippet(of: verse)
                    .font(.system(size: fontSize))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
            } else if !occurrence.text.isEmpty {
                // No verse kept for this translation, so the rendered words on
                // their own.
                Text("“\(occurrence.text)”")
                    .font(.callout)
                    .foregroundStyle(Color.lampSecondaryText)
            }
        }
    }

    /// The verse with the tagged word picked out, so a row reads as the
    /// sentence it came from rather than as a word on its own.
    ///
    /// Marked as a find match (`lampFindMatch`), as Search's rows mark
    /// theirs: the thing searched for, in a list of results. Accent text reads
    /// as a link or a selection, which ColorRules.md names as the thing to
    /// avoid, and search rows have always drawn matches this way.
    private func snippet(of verse: String) -> Text {
        let snippet = LampStrongsContext.snippet(
            of: verse,
            from: occurrence.startOffset,
            to: occurrence.endOffset
        )
        return Text(snippet.isTrimmedAtStart ? "…" : "")
            + Text(snippet.before)
            + Text.lampFindMatch(snippet.word)
            + Text(snippet.after)
            + Text(snippet.isTrimmedAtEnd ? "…" : "")
    }
}

// MARK: - In the study pane

/// A Strong's analysis in the reader's sidebar, opened over a dictionary entry.
///
/// Here rather than in Search so the passage stays beside it: Search takes the
/// window, and the reader loses their place to read a word's figures. The
/// occurrences are a section of the pane, since a sidebar has no room for
/// Search's second column, and choosing one opens it in the reader beside.
///
/// `keys` is the way back. Each companion followed goes on the end and Back
/// takes it off, down to the entry the first was opened from.
struct StudyAnalysisView: View {
    @Binding var keys: [String]
    /// The translation the tab is reading, analysed first and the one whose
    /// verses are listed.
    let translationID: String?
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.readerReferenceActions) private var referenceActions
    @AppStorage("reader.fontSize") private var readerFontSize = LampTextScale.readerText.defaultValue
    @State private var loader = StrongsAnalysisLoader()
    @State private var filter: LampStrongsFilter?
    /// A translation put first from the pane, TAGNT for its forms, in place
    /// of the one the tab reads. Cleared by Back to it and by a new word.
    @State private var openedTranslationID: String?

    private var key: String { keys.last ?? "" }

    private var readingTranslationID: String? { translationID ?? model.selectedTranslationID }

    private var fontSize: Double { LampTextScale.studyText(readerSize: readerFontSize) }

    private var request: StrongsAnalysisLoader.Request {
        StrongsAnalysisLoader.Request(
            key: key,
            activeTranslationID: openedTranslationID ?? readingTranslationID,
            bookRange: nil,
            translationIDs: model.translations.map(\.id)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    keys.removeLast()
                } label: {
                    // "Back to", as every back row in the app says. It also
                    // settles "Dictionary" alone, which is the tab above it.
                    Label("Back to \(backTitle)", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help(backHelp)
                Spacer(minLength: 0)
                if openedTranslationID != nil, let reading = readingTranslationID {
                    let name = model.translations.first { $0.id == reading }
                        .map { $0.abbreviation ?? $0.name } ?? reading
                    Button("Back to \(name)") { openedTranslationID = nil }
                        .buttonStyle(.borderless)
                        .help("Analyse in \(name), the translation this tab reads")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            StrongsAnalysisPane(
                key: key,
                loader: loader,
                filter: $filter,
                analyse: { keys.append($0) },
                openIn: { openedTranslationID = $0 },
                bookRange: nil,
                fontSize: fontSize,
                sections: [.overview, .spread, .companions, .compare, .verses],
                verseRow: { occurrence, analysis in
                    AnyView(occurrenceRow(occurrence, in: analysis))
                },
                pinnedFill: Color.lampInspectorFill
            )
        }
        .task(id: request) {
            // A rendering chosen for the last key means nothing for this one.
            filter = nil
            loader.load(request, library: model.library)
        }
        .onChange(of: key) { openedTranslationID = nil }
        .onDisappear { loader.cancel() }
    }

    private var backHelp: String {
        // Says more than the button's own words, not the same again.
        keys.count > 1 ? "Back to the analysis of \(backTitle)" : "Back to the dictionary entry"
    }

    /// The key Back returns to, or the entry when this is the first.
    private var backTitle: String {
        keys.count > 1 ? keys[keys.count - 2] : "Dictionary"
    }

    private func occurrenceRow(
        _ occurrence: LampStrongsAnalysis.Occurrence,
        in analysis: LampStrongsAnalysis
    ) -> some View {
        let reference = StrongsOccurrenceLabel.reference(occurrence.reference)
        return Button {
            referenceActions.openInCurrent(occurrence.reference)
        } label: {
            StrongsOccurrenceLabel(
                occurrence: occurrence,
                verse: analysis.verseTexts[occurrence.reference],
                fontSize: fontSize
            )
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chartClickable()
        .help("Open \(reference) in the reader")
        .contextMenu {
            Button("Open \(reference)") {
                referenceActions.openInCurrent(occurrence.reference)
            }
            if referenceActions.opensTabs {
                Button("Open in New Tab", systemImage: "plus.square.on.square") {
                    referenceActions.openInNewTab(occurrence.reference)
                }
            }
            Button("Copy Verse") {
                let verse = analysis.verseTexts[occurrence.reference] ?? occurrence.text
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(reference) \(verse)", forType: .string)
            }
        }
    }
}

// MARK: - Add to Deck

/// A figure of the analysis as a deck chart: what to chart, and the slide's
/// title and caption.
struct AnalysisDeckChart {
    /// What the menu calls it where a figure offers several: "Case".
    var name: String
    var chart: LampPresentationChart
    var title: String?
    var caption: String
}

/// Puts a figure of the analysis on a slide: at the end of a chosen deck, or
/// in a new one, then opens it in Slide Studio.
///
/// The slide names what to chart and Lamp works the values out from the
/// library as it is added, as a deck from an agent is built, so nothing on it
/// is copied from the pane: a figure still loading cannot freeze on a slide.
/// The pane's filter narrows only its verse list, and the figures above it
/// count every occurrence; so a chart counts every occurrence too, unless
/// "Only occurrences…" is ticked.
struct AddToDeckMenu: View {
    let charts: [AnalysisDeckChart]
    /// The pane's filter, offered as "Only occurrences rendered “love”".
    let filter: LampStrongsFilter?
    /// The new deck's title and subtitle.
    let deckTitle: String
    let deckSubtitle: String?

    @EnvironmentObject private var model: LibraryModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var inbox = SlideStudioInbox.shared
    @State private var onlyFiltered = false

    var body: some View {
        Menu {
            if let narrowing {
                Toggle("Only Occurrences \(narrowing.label)", isOn: $onlyFiltered)
                Divider()
            }
            if charts.count == 1, let chart = charts.first {
                destinations(for: chart)
            } else {
                ForEach(charts.indices, id: \.self) { index in
                    Menu(charts[index].name) { destinations(for: charts[index]) }
                }
            }
        } label: {
            // A Label, not a bare image: a label set on the menu itself did
            // not reach VoiceOver, which read the symbol's own name.
            Label("Add to Deck", systemImage: "rectangle.stack.badge.plus")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add to a slide deck")
        .task { inbox.refreshDecks(rootURL: model.library.rootURL) }
    }

    @ViewBuilder
    private func destinations(for chart: AnalysisDeckChart) -> some View {
        Section("Add to Deck") {
            ForEach(inbox.decks) { deck in
                Button(deck.title) { Task { await add(chart, to: deck.id) } }
            }
        }
        Divider()
        Button("New Deck") { Task { await add(chart, to: nil) } }
    }

    /// The filter as a deck can carry it, with what the toggle calls it. A
    /// chapter has no deck equivalent: a chart's range is whole books.
    private typealias Narrowing = (label: String, filter: LampPresentationChart.Filter?, range: String?)

    private var narrowing: Narrowing? {
        switch filter {
        case .rendering(_, let text) where !text.isEmpty:
            return ("Translated “\(text)”", LampPresentationChart.Filter(rendering: text), nil)
        case .form(let text):
            return ("As \(text)", LampPresentationChart.Filter(form: text), nil)
        case .grammar(let feature, let value):
            return (
                "\(feature.title): \(value)",
                LampPresentationChart.Filter(grammar: .init(feature: feature, value: value)),
                nil
            )
        case .book(let number):
            let name = LampBibleReferenceFormatter.bookName(number)
            return ("in \(name)", nil, name)
        default:
            return nil
        }
    }

    private func add(_ figure: AnalysisDeckChart, to deckID: String?) async {
        var chart = figure.chart
        var caption = figure.caption
        if onlyFiltered, let narrowing {
            if let filter = narrowing.filter { chart.source.filter = filter }
            if let range = narrowing.range { chart.source.range = range }
            caption += " · only occurrences \(narrowing.label.prefix(1).lowercased() + narrowing.label.dropFirst())"
        }
        // Worked out now, so the slide draws in the deck's thumbnails and a
        // presentation at once. If the library cannot, the slide still goes
        // in, and Slide Studio says why when it is opened.
        if let worked = try? await model.library.workedOut(chart) { chart = worked }

        var blocks: [LampPresentationBlock] = []
        if let title = figure.title { blocks.append(.init(kind: .title, text: title)) }
        blocks.append(.init(kind: .chart, text: "", chart: chart))
        blocks.append(.init(kind: .caption, text: caption))
        let slide = LampPresentationSlide(layout: .image, blocks: blocks)

        let inbox = SlideStudioInbox.shared
        let store = LampPresentationDeckStore(rootURL: model.library.rootURL)
        do {
            if let deckID, inbox.isShowing(deckID) {
                // That window takes the slide and brings itself forward.
                // Opening one here would be a second editor of the deck.
                inbox.send(slide, to: deckID)
                return
            }
            var deck: LampPresentationDeck
            if let deckID {
                guard let stored = try store.deck(id: deckID) else {
                    model.errorMessage = "That deck is no longer in the library."
                    return
                }
                deck = stored
                deck.slides.append(slide)
            } else {
                let starter = LampPresentationDeck.starter(title: deckTitle, subtitle: deckSubtitle)
                deck = starter
                deck.slides = Array(starter.slides.prefix(1)) + [slide]
            }
            try store.save(deck)
            inbox.select(slide.id, in: deck.id)
            openWindow(id: "slide-studio", value: SlideStudioRequest(deckID: deck.id))
            inbox.refreshDecks(rootURL: model.library.rootURL, force: true)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}
