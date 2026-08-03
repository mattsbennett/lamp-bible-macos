import AppKit
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampModuleKit
import SwiftUI

struct UnifiedSearchView: View {
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("search.history") private var historyData = Data()
    @State private var query = ""
    @State private var selectedKind: LampModuleKind?
    @State private var selectedModuleID: String?
    @State private var selectedResultID: String?

    let showImporter: () -> Void
    let openReference: (Int) -> Void
    let openKind: (LampModuleKind) -> Void

    private var history: [LampSearchHistoryEntry] {
        LampSearchHistoryStore.decode(historyData)
    }

    private var selectedResult: LampModuleSearchResult? {
        model.moduleSearchResults.first { $0.id == selectedResultID }
            ?? model.moduleSearchResults.first
    }

    private var availableModules: [(id: String, name: String)] {
        var values: [(id: String, name: String)] = model.modules
            .filter { selectedKind == nil || $0.kind == selectedKind }
            .map { (id: $0.id, name: $0.name) }
        if selectedKind == nil || selectedKind == .notes {
            values.append(("personal-notes", "My Notes"))
        }
        if selectedKind == nil || selectedKind == .highlights {
            values += model.translations.map {
                ("personal-highlights:\($0.id)", "My \($0.abbreviation ?? $0.name) Highlights")
            }
        }
        if selectedKind == nil || selectedKind == .devotional {
            values.append(("personal-devotionals", "My Devotionals"))
        }
        var seen: Set<String> = []
        return values.filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Group {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchLanding
            } else if model.isModuleSearching && model.moduleSearchResults.isEmpty {
                ProgressView("Searching Library…")
            } else if model.moduleSearchResults.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                HSplitView {
                    resultsList
                    if let selectedResult {
                        resultDetail(selectedResult)
                    } else {
                        ContentUnavailableView("Choose a Result", systemImage: "text.magnifyingglass")
                    }
                }
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, placement: .toolbar, prompt: "Search Bibles and modules")
        .onSubmit(of: .search) { saveSearch() }
        .onChange(of: query) { _, _ in runSearch() }
        .onChange(of: selectedKind) { _, _ in
            selectedModuleID = nil
            runSearch()
        }
        .onChange(of: selectedModuleID) { _, _ in runSearch() }
        .onChange(of: model.moduleSearchResults) { _, results in
            if !results.contains(where: { $0.id == selectedResultID }) {
                selectedResultID = results.first?.id
            }
        }
        .toolbar { searchToolbar }
        .overlay(alignment: .bottomTrailing) {
            if model.isModuleSearching && !model.moduleSearchResults.isEmpty {
                ProgressView("Updating Results…")
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                    .padding()
            }
        }
    }

    private var searchLanding: some View {
        Group {
            if history.isEmpty {
                ContentUnavailableView {
                    Label("Search Your Library", systemImage: "text.magnifyingglass")
                } description: {
                    Text("Search scripture, dictionaries, commentaries, notes, devotionals, plans, quizzes, and highlighted verses.")
                } actions: {
                    if model.modules.isEmpty {
                        Button("Install Module…", action: showImporter)
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                List {
                    Section("Recent Searches") {
                        ForEach(history) { entry in
                            Button {
                                query = entry.query
                                selectedKind = entry.kind
                                selectedModuleID = entry.moduleID
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.query)
                                        Text(historyDescription(entry))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Spacer()
                        Button("Clear Search History", role: .destructive) {
                            historyData = Data()
                        }
                    }
                    .padding()
                    .background(.bar)
                }
            }
        }
    }

    private var resultsList: some View {
        List(selection: $selectedResultID) {
            ForEach(model.moduleSearchResults) { result in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Image(systemName: icon(for: result.kind))
                            .foregroundStyle(.tint)
                        Text(result.title)
                            .font(.headline)
                            .lineLimit(2)
                        Spacer()
                        Text(result.kind.displayName)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    Text(result.moduleName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(result.snippet)
                        .lineLimit(3)
                        .foregroundStyle(.primary)
                }
                .padding(.vertical, 6)
                .tag(Optional(result.id))
                .contextMenu {
                    if let reference = result.startReference {
                        Button("Open \(result.referenceDescription ?? "Reference")") {
                            openReference(reference)
                        }
                    }
                    Button("Copy Result") { copy(result) }
                }
            }
        }
        .frame(minWidth: 340, idealWidth: 440)
        .listStyle(.inset)
    }

    private func resultDetail(_ result: LampModuleSearchResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Label(result.kind.displayName, systemImage: icon(for: result.kind))
                        .font(.headline)
                        .foregroundStyle(.tint)
                    Text(result.title)
                        .font(.largeTitle.bold())
                    if let subtitle = result.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Text(result.moduleName)
                        .foregroundStyle(.secondary)
                }

                if let description = result.referenceDescription {
                    Label(description, systemImage: "book")
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text(result.snippet)
                    .font(result.kind == .translation ? .system(.body, design: .serif) : .body)
                    .lineSpacing(5)
                    .textSelection(.enabled)

                HStack {
                    if let reference = result.startReference {
                        Button("Open in Reader", systemImage: "book") {
                            saveSearch()
                            openReference(reference)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if [.devotional, .plan, .quiz].contains(result.kind) {
                        Button("Open \(result.kind.displayName)") {
                            saveSearch()
                            openKind(result.kind)
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Copy", systemImage: "doc.on.doc") { copy(result) }
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ToolbarContentBuilder
    private var searchToolbar: some ToolbarContent {
        ToolbarItem {
            Picker("Content", selection: $selectedKind) {
                Text("All Content").tag(LampModuleKind?.none)
                ForEach(LampModuleKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(Optional(kind))
                }
            }
            .frame(minWidth: 150)
        }

        ToolbarItem {
            Picker("Module", selection: $selectedModuleID) {
                Text("All Modules").tag(String?.none)
                ForEach(availableModules, id: \.id) { module in
                    Text(module.name).tag(Optional(module.id))
                }
            }
            .frame(minWidth: 170)
        }
    }

    private func runSearch() {
        model.searchModules(query, kind: selectedKind, moduleID: selectedModuleID)
    }

    private func saveSearch() {
        let entry = LampSearchHistoryEntry(
            query: query,
            kind: selectedKind,
            moduleID: selectedModuleID
        )
        historyData = LampSearchHistoryStore.encode(
            LampSearchHistoryStore.adding(entry, to: history)
        )
    }

    private func historyDescription(_ entry: LampSearchHistoryEntry) -> String {
        if let moduleID = entry.moduleID,
           let module = availableModules.first(where: { $0.id == moduleID }) {
            return module.name
        }
        return entry.kind?.displayName ?? "All Content"
    }

    private func copy(_ result: LampModuleSearchResult) {
        let text = [result.title, result.referenceDescription, result.snippet]
            .compactMap { $0 }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func icon(for kind: LampModuleKind) -> String {
        switch kind {
        case .translation: "books.vertical"
        case .dictionary: "character.book.closed"
        case .commentary: "text.book.closed"
        case .devotional: "sun.max"
        case .notes: "note.text"
        case .plan: "checklist"
        case .highlights: "highlighter"
        case .quiz: "questionmark.bubble"
        }
    }
}

private extension LampModuleKind {
    static var allCases: [LampModuleKind] {
        [.translation, .dictionary, .commentary, .devotional, .notes, .plan, .highlights, .quiz]
    }

    var displayName: String {
        switch self {
        case .translation: "Scripture"
        case .dictionary: "Dictionaries"
        case .commentary: "Commentaries"
        case .devotional: "Devotionals"
        case .notes: "Notes"
        case .plan: "Reading Plans"
        case .highlights: "Highlights"
        case .quiz: "Quizzes"
        }
    }
}
