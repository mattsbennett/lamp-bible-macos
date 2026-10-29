import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampModuleKit
import SwiftUI

/// A key's lemma and gloss, read the way the agent tool reads them.
///
/// Deliberately the same rule as `analyzeStrongs`: the first permitted
/// lexicon's lemma, and the first sense carrying either a gloss or a short
/// definition. The pane and an outside agent looking at the same key should
/// not disagree about what the word is.
struct StrongsEntry: Equatable, Sendable {
    var lemma: String?
    var transliteration: String?
    var gloss: String?
}

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
    private(set) var entries: [String: StrongsEntry] = [:]
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
        for result in results {
            let normalized = LampStrongsKey.normalized(result.key)
            let known = entries[normalized]
            entries[normalized] = StrongsEntry(
                lemma: known?.lemma ?? result.lemma,
                transliteration: known?.transliteration ?? result.transliteration,
                gloss: known?.gloss
                    ?? result.senses.lazy.compactMap { $0.gloss ?? $0.shortDefinition }.first
            )
        }
        // Asking for a key no lexicon holds must not ask again on every
        // translation, so record the absence as well as the answer.
        for key in missing where entries[key] == nil {
            entries[key] = StrongsEntry()
        }
    }
}

/// What a Strong's key does across the translations that tag it.
struct StrongsAnalysisPane: View {
    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case spread = "Spread"
        case companions = "Companions"
        case compare = "Compare"

        var id: String { rawValue }
    }

    let key: String
    let loader: StrongsAnalysisLoader
    @Binding var filter: LampStrongsFilter?
    /// Analyses another key, for a companion the reader chooses.
    let analyse: (String) -> Void
    /// The books being searched, so the shape can put back the ones the key
    /// never reaches.
    let bookRange: ClosedRange<Int>?

    @State private var section: Section = .overview
    @State private var style: LampStrongsChartStyle = .bars
    @State private var measure: LampStrongsSpreadMeasure = .occurrences
    @State private var bySection = false
    @State private var openBook: Int?
    /// Set once rather than per search, so it is remembered.
    @AppStorage("strongs.shareAsRing") private var shareAsRing = true

    /// The analysis the pane describes: the translation being read, which
    /// `LampStrongsAnalysisOrder` keeps at the front.
    private var analysis: LampStrongsAnalysis? { loader.analyses.first }

    private var entry: StrongsEntry? { loader.entries[LampStrongsKey.normalized(key)] }

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
                header(analysis)
                Divider()
                Picker("Section", selection: $section) {
                    ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(10)
                Divider()
                ScrollView {
                    switch section {
                    case .overview: overview(analysis)
                    case .spread: spread(analysis)
                    case .companions: companions(analysis)
                    case .compare: compare
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 320, idealWidth: 400)
    }

    // MARK: - Header

    private func header(_ analysis: LampStrongsAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(analysis.key)
                    .font(.title3.weight(.semibold))
                if let lemma = entry?.lemma, !lemma.isEmpty {
                    Text(lemma).font(.title3)
                }
                if let transliteration = entry?.transliteration, !transliteration.isEmpty {
                    Text(transliteration).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if loader.isFillingRest {
                    ProgressView().controlSize(.small)
                }
            }
            if let gloss = entry?.gloss, !gloss.isEmpty {
                Text(gloss).font(.callout).foregroundStyle(.secondary)
            }
            Text(countSummary(analysis))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let filter {
                HStack(spacing: 6) {
                    Button {
                        self.filter = nil
                    } label: {
                        HStack(spacing: 4) {
                            Text(filter.label).lineLimit(1)
                            Image(systemName: "xmark.circle.fill")
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.tint.opacity(0.18), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Show every occurrence again")
                    Spacer()
                }
            }
        }
        .padding(10)
    }

    /// Both verse counts are named, because they answer different questions
    /// and a bare "verses" beside a rate reads as the wrong denominator: the
    /// rate is per tagged *word*, not per verse.
    private func countSummary(_ analysis: LampStrongsAnalysis) -> String {
        let rate = (analysis.ratePerThousandWords * 100).rounded() / 100
        return "\(analysis.occurrenceCount) occurrences in \(analysis.verseCount) verses · "
            + "\(rate) per 1,000 tagged words · \(analysis.translationAbbreviation ?? analysis.translationName)"
    }

    // MARK: - Overview

    private func overview(_ analysis: LampStrongsAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !analysis.renderings.isEmpty {
                group("Rendered As") {
                    ForEach(analysis.renderings) { rendering in
                        renderingRow(rendering)
                    }
                    Text("What translators reached for, not what the word means.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !analysis.forms.isEmpty {
                group("Forms") {
                    ForEach(analysis.forms) { form in
                        chooseRow(
                            title: form.text,
                            count: form.count,
                            isChosen: filter == .form(form.text)
                        ) {
                            choose(.form(form.text))
                        }
                    }
                }
            }
            if !analysis.grammar.isEmpty {
                group("Grammar") {
                    ForEach(LampGrammarFeature.allCases, id: \.self) { feature in
                        let values = analysis.grammar.filter { $0.feature == feature }
                        if !values.isEmpty {
                            Text(feature.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                            ForEach(values, id: \.value) { count in
                                chooseRow(
                                    title: count.value,
                                    count: count.count,
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
        }
        .padding(10)
    }

    private func renderingRow(_ rendering: LampStrongsAnalysis.Rendering) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            chooseRow(
                title: rendering.text.isEmpty ? "(no English of its own)" : rendering.text,
                count: rendering.count,
                isChosen: filter == .rendering(id: rendering.id, text: rendering.text)
            ) {
                choose(.rendering(id: rendering.id, text: rendering.text))
            }
            if rendering.variants.count > 1 {
                DisclosureGroup("\(rendering.variants.count) variants") {
                    ForEach(rendering.variants, id: \.text) { variant in
                        HStack {
                            Text(variant.text).font(.caption)
                            Spacer()
                            Text("\(variant.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.caption)
                .padding(.leading, 10)
            }
        }
    }

    // MARK: - Spread

    /// One row of the chapter grid: the cell height plus room for the
    /// book's name beside it.
    private static let gridRowHeight: Double = 13

    /// Books unless sections were asked for — and always books for the grid,
    /// which is drawn from chapters that only a book has.
    private var showsBooks: Bool { !bySection || style.needsBooks }

    private func spread(_ analysis: LampStrongsAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Chart", selection: $style) {
                ForEach(LampStrongsChartStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 10) {
                Picker("By", selection: $bySection) {
                    Text("Books").tag(false)
                    Text("Sections").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .disabled(style.needsBooks)
                .help(style.needsBooks ? "Chapters belong to books" : "")
                Spacer()
                if style.usesMeasure {
                    Picker("Measure", selection: $measure) {
                        ForEach(LampStrongsSpreadMeasure.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                } else if style == .share {
                    Picker("Shape", selection: $shareAsRing) {
                        Text("Ring").tag(true)
                        Text("Pie").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 110)
                }
            }

            switch style {
            case .bars: barsChart(analysis)
            case .columns: columnsChart(analysis)
            case .grid: gridChart(analysis)
            case .share: shareChart(analysis)
            }

            if style != .share {
                Text("“More” and “fewer” mean beyond chance, not simply above or "
                    + "below average.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(10)
    }

    // MARK: - Bars

    @ViewBuilder
    private func barsChart(_ analysis: LampStrongsAnalysis) -> some View {
        let divisions = showsBooks ? analysis.books : analysis.sections
        let bars = LampStrongsSpread.bars(divisions, measure: measure)
        if bars.isEmpty {
            nothingToChart
        }
        ForEach(bars) { bar in
            spreadBar(bar, isBook: showsBooks)
            if showsBooks, openBook == bar.id {
                chapterStrip(analysis, book: bar.id)
            }
        }
    }

    // MARK: - The shape across the canon

    /// One column per book in Bible order, gaps and all.
    ///
    /// Fitted to the width rather than scrolled: a shape you have to scroll
    /// through is not a shape, and the whole point is seeing where the key
    /// gathers in one look.
    @ViewBuilder
    private func columnsChart(_ analysis: LampStrongsAnalysis) -> some View {
        // The same list bars use. Core's `books` is already every book with
        // tags of the key's own language, zeros included — so a Greek key
        // gives the 27 New Testament books and nothing else. Padding it out
        // to the whole canon, as this did, is what put two thirds of empty
        // Old Testament on the chart.
        let divisions = showsBooks ? analysis.books : analysis.sections
        let bars = LampStrongsSpread.bars(divisions, measure: measure)
        if bars.isEmpty {
            nothingToChart
        } else {
            let tallest = bars.max { $0.share < $1.share }
            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { proxy in
                    let gap: Double = bars.count > 40 ? 1 : 2
                    let width = max(
                        2,
                        (proxy.size.width - gap * Double(bars.count - 1)) / Double(bars.count)
                    )
                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(bars) { bar in
                            Button {
                                choose(.book(number: bar.id))
                            } label: {
                                RoundedRectangle(cornerRadius: min(2, width / 2))
                                    .fill(fill(for: bar.expectation))
                                    .frame(
                                        width: width,
                                        height: bar.share > 0
                                            ? max(2, 96 * bar.share)
                                            : 1
                                    )
                                    .opacity(bar.share > 0 ? 1 : 0.25)
                            }
                            .buttonStyle(.plain)
                            .help(helpText(bar))
                            // The one label worth drawing, over the column it
                            // belongs to. Centred in the row instead, it
                            // pointed at whatever happened to be in the
                            // middle.
                            .overlay(alignment: .top) {
                                if bar.id == tallest?.id, bar.occurrenceCount > 0 {
                                    Text("\(LampBibleReferenceFormatter.bookAbbreviation(bar.id)) "
                                        + "\(bar.occurrenceCount)")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.tint)
                                        .fixedSize()
                                        .offset(y: -13)
                                }
                            }
                        }
                    }
                    .frame(height: 96, alignment: .bottom)
                }
                .frame(height: 96)

                // Selective labels: the ends anchor the order, and the tallest
                // is the one anyone will ask about. A name on all sixty-six
                // would be a grey smear.
                // The ends anchor the order; the peak labels itself above its
                // own column.
                HStack(spacing: 4) {
                    Text(bars.first?.name ?? "").font(.caption2)
                    Spacer()
                    Text(bars.last?.name ?? "").font(.caption2)
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
                let cell = max(2, min(12, (proxy.size.width - 80) / Double(longest)))
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(rows) { row in
                        HStack(spacing: 5) {
                            Text(row.name)
                                .font(.caption2)
                                .lineLimit(1)
                                .frame(width: 74, alignment: .trailing)
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
                                            .frame(width: cell - 1, height: 11)
                                    }
                                    .buttonStyle(.plain)
                                    .help("\(row.name) \(chapter.number): "
                                        + "\(chapter.occurrenceCount)")
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
                    Text("0").font(.caption2).foregroundStyle(.secondary)
                    ForEach([0.07, 0.4, 0.7, 1.0], id: \.self) { step in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(.tint)
                            .opacity(step)
                            .frame(width: 11, height: 9)
                    }
                    Text("\(busiest) in a chapter")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 3)
            }
        }
    }

    // MARK: - Share

    /// Each division's proportion of the whole.
    ///
    /// Every slice is named with its count and percentage beside the ring, so
    /// nothing here is carried by colour alone — which matters more than
    /// usual, since the slices are one hue at different strengths rather than
    /// separate colours.
    @ViewBuilder
    private func shareChart(_ analysis: LampStrongsAnalysis) -> some View {
        let slices = LampStrongsShare.slices(
            from: showsBooks ? analysis.books : analysis.sections
        )
        if slices.isEmpty {
            nothingToChart
        } else {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                        DonutSlice(
                            start: slices.prefix(index).reduce(0) { $0 + $1.fraction },
                            extent: slice.fraction,
                            thickness: shareAsRing ? 0.38 : 1
                        )
                        .fill(.tint)
                        .opacity(sliceOpacity(index, of: slices.count, isOther: slice.isOther))
                        .help("\(slice.name): \(slice.value)")
                    }
                    // The hole is somewhere to put the total, which is the
                    // one number a share otherwise leaves you to add up.
                    if shareAsRing {
                        VStack(spacing: 0) {
                            Text("\(slices.reduce(0) { $0 + $1.value })")
                                .font(.callout.weight(.semibold).monospacedDigit())
                            Text("in all").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 104, height: 104)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.tint)
                                .opacity(
                                    sliceOpacity(index, of: slices.count, isOther: slice.isOther)
                                )
                                .frame(width: 9, height: 9)
                            Text(slice.name).font(.caption).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(slice.value)")
                                .font(.caption.monospacedDigit())
                            Text("\(Int((slice.fraction * 100).rounded()))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    /// One hue, strongest for the largest slice. "Other" is always faintest,
    /// because it is a leftover rather than a finding.
    private func sliceOpacity(_ index: Int, of count: Int, isOther: Bool) -> Double {
        guard !isOther else { return 0.2 }
        guard count > 1 else { return 1 }
        return 1 - 0.6 * (Double(index) / Double(count - 1))
    }

    private var nothingToChart: some View {
        Text("Nothing to chart in these books.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func spreadBar(_ bar: LampStrongsSpreadBar, isBook: Bool) -> some View {
        Button {
            if isBook {
                openBook = openBook == bar.id ? nil : bar.id
                choose(.book(number: bar.id))
            }
        } label: {
            HStack(spacing: 8) {
                Text(bar.name)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(width: 96, alignment: .trailing)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(fill(for: bar.expectation))
                            .frame(width: bar.share > 0
                                ? max(2, proxy.size.width * bar.share)
                                : 0)
                    }
                }
                .frame(height: 13)
                Text(measureLabel(bar))
                    .font(.caption.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
                standing(bar.expectation)
                    .frame(width: 16)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText(bar))
    }

    private func chapterStrip(_ analysis: LampStrongsAnalysis, book: Int) -> some View {
        let chapters = analysis.books.first { $0.id == book }?.chapters ?? []
        let most = chapters.map(\.occurrenceCount).max() ?? 0
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(chapters) { chapter in
                Button {
                    choose(.chapter(book: book, number: chapter.number))
                } label: {
                    VStack(spacing: 2) {
                        Capsule()
                            .fill(filter == .chapter(book: book, number: chapter.number)
                                ? AnyShapeStyle(.tint)
                                : AnyShapeStyle(.tint.opacity(0.5)))
                            .frame(
                                width: 7,
                                height: most > 0
                                    ? max(2, 34 * Double(chapter.occurrenceCount) / Double(most))
                                    : 2
                            )
                        Text("\(chapter.number)")
                            .font(.system(size: 7))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Chapter \(chapter.number): \(chapter.occurrenceCount)")
            }
            Spacer()
        }
        .padding(.leading, 104)
        .padding(.bottom, 4)
    }

    private func measureLabel(_ bar: LampStrongsSpreadBar) -> String {
        switch measure {
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
        return "\(bar.name): \(bar.occurrenceCount) in \(bar.wordCount) tagged words\(standing)"
    }

    private func fill(for expectation: LampStrongsAnalysis.Expectation) -> AnyShapeStyle {
        switch expectation {
        case .more: AnyShapeStyle(.tint)
        case .fewer: AnyShapeStyle(.secondary)
        case .asExpected: AnyShapeStyle(.tint.opacity(0.55))
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
        VStack(alignment: .leading, spacing: 8) {
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
                            Text(companion.key).font(.callout.weight(.medium))
                            if let lemma = loader.entries[companion.key]?.lemma {
                                Text(lemma).font(.callout)
                            }
                            Spacer()
                            Text(String(format: "%.1f× chance", companion.lift))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if let gloss = loader.entries[companion.key]?.gloss {
                            Text(gloss).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Text("\(companion.sharedVerseCount) shared verses of \(companion.verseCount)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
        .padding(10)
    }

    // MARK: - Compare

    private var compare: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(loader.analyses, id: \.translationID) { analysis in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(analysis.translationAbbreviation ?? analysis.translationName)
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text("\(analysis.occurrenceCount) in \(analysis.verseCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(analysis.renderings.prefix(3)
                        .map { "\($0.text.isEmpty ? "—" : $0.text) (\($0.count))" }
                        .joined(separator: ", "))
                        .font(.caption)
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
        .padding(10)
    }

    // MARK: - Pieces

    private func group<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func chooseRow(
        title: String,
        count: Int,
        isChosen: Bool,
        choose: @escaping () -> Void
    ) -> some View {
        Button(action: choose) {
            HStack(spacing: 6) {
                Text(title).font(.callout).lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                isChosen ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Choosing the filter already in force removes it, so the same click both
    /// narrows and widens and nobody has to find the chip to get back.
    private func choose(_ next: LampStrongsFilter) {
        filter = filter == next ? nil : next
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
