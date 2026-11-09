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
    @Binding var filter: LampStrongsFilter?
    /// Analyses another key, for a companion the reader chooses.
    let analyse: (String) -> Void
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
    @State private var spreadGrouping: LampStrongsSpreadGrouping = .books
    @State private var measure: LampStrongsSpreadMeasure = .occurrences
    @State private var openBook: Int?
    /// The slice the pointer is over, named in the ring's hole. Every slice
    /// is a shade of one colour, so matching one to its row by eye is hard.
    /// Set once rather than per search, so it is remembered.
    @AppStorage("strongs.renderingsAsRing") private var renderingsAsRing = false
    @AppStorage("strongs.formsAsRing") private var formsAsRing = false
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var septuagint = SeptuagintLoader()
    /// Collapsed to begin with: the Septuagint is a second subject, and what
    /// it holds costs a search a word to work out.
    @State private var isShowingSeptuagint = false

    /// The analysis the pane describes: the translation being read, which
    /// `LampStrongsAnalysisOrder` keeps at the front.
    private var analysis: LampStrongsAnalysis? { loader.analyses.first }

    private var entry: LampStrongsHeadword? { loader.entries[LampStrongsKey.normalized(key)] }

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

    /// Segmented beside Search's occurrence column, where there is room for
    /// it. In the study column, the column's own tabs: five segments do not
    /// shrink, and pushed the pane past both of the column's edges.
    @ViewBuilder
    private var sectionPicker: some View {
        let selection = Binding(get: { shownSection }, set: { section = $0 })
        if sections.contains(.verses) {
            UnderlinedTabs(
                label: "Section",
                items: sections.map { ($0, $0.rawValue) },
                selection: selection,
                spacing: 14
            )
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Picker("Section", selection: selection) {
                ForEach(sections) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
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
        VStack(alignment: .leading, spacing: 14) {
            if let back {
                Button(action: back.go) {
                    Label(back.title, systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Back to \(back.title)")
                .help("Back to \(back.title)")
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
            HStack(alignment: .top, spacing: 0) {
                statTile("Occurrences", value: analysis.occurrenceCount)
                statTile("Verses", value: analysis.verseCount)
                statTile("Books", value: analysis.booksWithOccurrences, of: analysis.books.count)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(analysis.occurrenceCount) times in \(analysis.verseCount) verses, "
                    + "in \(analysis.booksWithOccurrences) of \(analysis.books.count) books"
            )
            if analysis.books.count > 1 {
                canonStrip(analysis.books)
            }
            Text(cardFootnote(analysis))
                .font(.caption)
                .foregroundStyle(.secondary)
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

    /// A label over a large figure, the unit small beside it.
    private func statTile(_ label: String, value: Int, of total: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value)")
                    .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let total {
                    Text("of \(total)")
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The rate and the translation counted, under the figures they qualify.
    /// The rate is per tagged *word*, which "per 1,000 tagged words" says,
    /// so it is not read against the verses beside it.
    private func cardFootnote(_ analysis: LampStrongsAnalysis) -> String {
        let rate = (analysis.ratePerThousandWords * 100).rounded() / 100
        return "\(rate) per 1,000 tagged words\u{00A0}· "
            + (analysis.translationAbbreviation ?? analysis.translationName)
    }

    private static let stripHeight: Double = 64
    private static let stripLabelBand: Double = 16

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
                                        .frame(height: isEmpty
                                            ? 2
                                            : max(5, Self.stripHeight * Double(book.occurrenceCount) / Double(most)))
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
                        let centre = (column + gap) * Double(standout.offset) + column / 2
                        let top = Self.stripLabelBand + Self.stripHeight
                            - max(5, Self.stripHeight * Double(standout.element.occurrenceCount) / Double(most))
                        Text(standout.element.name)
                            .font(.system(size: Self.chartFinePrintSize, weight: .bold))
                            .foregroundStyle(.tint)
                            .fixedSize()
                            .position(
                                x: min(max(centre, 40), proxy.size.width - 40),
                                y: max(top - 8, 6)
                            )
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

    private func overview(_ analysis: LampStrongsAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if !analysis.renderings.isEmpty {
                group(
                    "Rendered As",
                    note: "What translators reached for, not what the word means.",
                    asRing: $renderingsAsRing
                ) {
                    if renderingsAsRing {
                        ShareRing(
                            divisions: LampStrongsGrouping.renderings.divisions(of: analysis),
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
            if !analysis.forms.isEmpty {
                group("Forms", asRing: $formsAsRing) {
                    if formsAsRing {
                        ShareRing(
                            divisions: LampStrongsGrouping.forms.divisions(of: analysis),
                            choose: choose
                        )
                    } else {
                        let most = analysis.forms.map(\.count).max() ?? 0
                        ForEach(analysis.forms) { form in
                            chooseRow(
                                title: form.text,
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
                group("Grammar") {
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
    private static let chartFinePrintSize: Double = 11.5
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

    private func fill(for expectation: LampStrongsAnalysis.Expectation) -> AnyShapeStyle {
        switch expectation {
        case .more: AnyShapeStyle(.tint)
        case .fewer: AnyShapeStyle(Color.primary.opacity(0.32))
        case .asExpected: AnyShapeStyle(.tint.opacity(0.55))
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
            if analysis.companions.isEmpty {
                Text("No other key shares enough verses with this one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                            Text(String(format: "%.1f× chance", companion.lift))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if let gloss = loader.entries[companion.key]?.gloss {
                            Text(gloss)
                                .font(.system(size: max(10, fontSize - 2)))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Text("\(companion.sharedVerseCount) shared verses of \(companion.verseCount)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
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
                Text("Strongest association first, which is not the largest multiple: "
                    + "a high multiple over few verses says less than a smaller one "
                    + "over many.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Compare

    private var compare: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(loader.analyses, id: \.translationID) { analysis in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(analysis.translationAbbreviation ?? analysis.translationName)
                            .font(.system(size: fontSize, weight: .medium))
                        Spacer()
                        Text("\(analysis.occurrenceCount) in \(analysis.verseCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(analysis.renderings.prefix(3)
                        .map { "\($0.text.isEmpty ? "—" : $0.text) (\($0.count))" }
                        .joined(separator: ", "))
                        .font(.system(size: max(10, fontSize - 2)))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
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

    // MARK: - Pieces

    /// A section of the overview: the shared section heading, with what the
    /// section means said beneath it rather than trailing after.
    /// A titled group, with a List / Ring switch at its heading where
    /// `asRing` is given.
    private func group<Content: View>(
        _ title: String,
        note: String? = nil,
        asRing: Binding<Bool>? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .lampSectionHeading()
                Spacer(minLength: 8)
                if let asRing {
                    Picker("Show \(title) as", selection: asRing) {
                        Text("List").tag(false)
                        Text("Ring").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .help("A list to compare, or a ring of each one's part of the whole")
                }
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        count: Int,
        most: Int,
        isChosen: Bool,
        choose: @escaping () -> Void
    ) -> some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: fontSize))
                    .lineLimit(1)
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
        .help("\(title): \(count)." + Self.listsThese(count))
    }

    /// What a click on a figure does, said in its help, since nothing else on
    /// a chart says it can be clicked. A figure of nought has nothing to list.
    private static func listsThese(_ count: Int) -> String {
        count > 0 ? " Click to list only these." : ""
    }

    /// The empty length behind a bar, a step off the pane in either
    /// appearance: `.quaternary` all but vanished on dark.
    private static var barTrack: Color { Color.primary.opacity(0.08) }

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
private struct ShareRing: View {
    let divisions: [LampStrongsChartDivision]
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
                .opacity(
                    hovered == nil || hovered?.id == slice.id
                        ? opacity(index, of: slices.count, isOther: slice.isOther)
                        // The others recede rather than vanish, so the ring
                        // keeps its shape while one slice is picked out.
                        : 0.12
                )
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
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.tint)
                            .opacity(opacity(index, of: slices.count, isOther: slice.isOther))
                            .frame(width: 10, height: 10)
                            .overlay {
                                if hovered?.id == slice.id {
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(.primary, lineWidth: 1.5)
                                }
                            }
                        Text(slice.name).font(.callout).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(slice.value)")
                            .font(.callout.monospacedDigit())
                        Text(LampStrongsSpread.percent(slice.fraction))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(filter(for: slice) == nil)
                .onHover { hovered = $0 ? slice : nil }
            }
        }
    }

    /// One hue, strongest for the largest slice. "Other" is always faintest,
    /// because it is a leftover rather than a finding.
    private func opacity(_ index: Int, of count: Int, isOther: Bool) -> Double {
        guard !isOther else { return 0.2 }
        guard count > 1 else { return 1 }
        return 1 - 0.6 * (Double(index) / Double(count - 1))
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
                        .foregroundStyle(.secondary)
                }
            }
            if let verse {
                // The outer style is the default for spans that set none, so
                // the tagged word keeps the mark it was given.
                snippet(of: verse)
                    .font(.system(size: fontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } else if !occurrence.text.isEmpty {
                // No verse kept for this translation, so the rendered words on
                // their own.
                Text("“\(occurrence.text)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The verse with the tagged word picked out, so a row reads as the
    /// sentence it came from rather than as a word on its own.
    ///
    /// Marked as a find match — yellow behind text that keeps its colour —
    /// because that is what it is: the thing searched for. Accent text reads
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

    private var key: String { keys.last ?? "" }

    private var fontSize: Double { LampTextScale.studyText(readerSize: readerFontSize) }

    private var request: StrongsAnalysisLoader.Request {
        StrongsAnalysisLoader.Request(
            key: key,
            activeTranslationID: translationID ?? model.selectedTranslationID,
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
                    Label(backTitle, systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                // Named for where it goes: "Dictionary" alone is also the
                // tab above it.
                .accessibilityLabel(backHelp)
                .help(backHelp)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            StrongsAnalysisPane(
                key: key,
                loader: loader,
                filter: $filter,
                analyse: { keys.append($0) },
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
        .onDisappear { loader.cancel() }
    }

    private var backHelp: String {
        keys.count > 1 ? "Back to \(backTitle)" : "Back to the dictionary entry"
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
