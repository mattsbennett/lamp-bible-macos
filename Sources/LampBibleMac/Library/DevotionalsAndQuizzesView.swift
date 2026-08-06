import AppKit
import LampCore
import LampModuleKit
import SwiftUI
import UniformTypeIdentifiers

struct DevotionalsView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("devotional.fontSize") private var devotionalFontSize = 17.0
    @State private var selection: String?
    @State private var query = ""
    @State private var categoryFilter: String?
    @State private var moduleFilter: String?
    @State private var devotionalPendingDeletion: LampDevotional?
    @State private var exportedURL: URL?
    @State private var presentingDevotional: LampDevotional?

    let showImporter: () -> Void
    let openReference: (Int) -> Void

    private var filteredDevotionals: [LampDevotional] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.devotionals.filter { devotional in
            guard categoryFilter == nil || normalizedCategory(devotional.category) == categoryFilter,
                  moduleFilter == nil || devotional.moduleID == moduleFilter else { return false }
            guard !trimmedQuery.isEmpty else { return true }
            return [
                devotional.title,
                devotional.subtitle,
                devotional.author,
                devotional.seriesName,
                devotional.summary,
                devotional.content,
            ]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(trimmedQuery) }
            || devotional.tags.contains { $0.localizedCaseInsensitiveContains(trimmedQuery) }
        }
    }

    private var selectedDevotional: LampDevotional? {
        filteredDevotionals.first { $0.id == selection } ?? filteredDevotionals.first
    }

    var body: some View {
        Group {
            if model.devotionals.isEmpty {
                ContentUnavailableView {
                    Label("No Devotionals", systemImage: "sun.max")
                } description: {
                    Text("Write your own devotional, install a devotional .lamp module, or build one in Module Studio.")
                } actions: {
                    HStack {
                        Button("New Devotional") { beginEditing(nil) }
                            .buttonStyle(.borderedProminent)
                        Button("Install Module…", action: showImporter)
                    }
                }
            } else if filteredDevotionals.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                HSplitView {
                    List(selection: $selection) {
                        ForEach(filteredDevotionals) { devotional in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 5) {
                                        Text(devotional.title)
                                            .font(.headline)
                                            .lineLimit(2)
                                        if devotional.isEditable {
                                            Image(systemName: "pencil.circle.fill")
                                                .foregroundStyle(.tint)
                                                .help("Editable personal devotional")
                                        }
                                    }
                                    Text(devotional.seriesName ?? devotional.moduleName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                if devotional.isEditable {
                                    Menu("Devotional Actions", systemImage: "ellipsis.circle") {
                                        Button("Edit", systemImage: "pencil") {
                                            beginEditing(devotional)
                                        }
                                        Button("Export…", systemImage: "square.and.arrow.up") {
                                            export(devotional)
                                        }
                                        Divider()
                                        Button("Delete", systemImage: "trash", role: .destructive) {
                                            devotionalPendingDeletion = devotional
                                        }
                                    }
                                    .labelStyle(.iconOnly)
                                    .menuStyle(.borderlessButton)
                                    .fixedSize()
                                    .help("Edit, export, or delete this devotional")
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .tag(Optional(devotional.id))
                            .simultaneousGesture(
                                TapGesture(count: 2)
                                    .onEnded {
                                        selection = devotional.id
                                        guard devotional.isEditable else { return }
                                        beginEditing(devotional)
                                    }
                            )
                            .help(devotional.isEditable
                                ? "Double-click to edit"
                                : "Installed devotionals are read-only")
                            .accessibilityAction(named: "Edit") {
                                guard devotional.isEditable else { return }
                                beginEditing(devotional)
                            }
                            .contextMenu {
                                if devotional.isEditable {
                                    Button("Edit") { beginEditing(devotional) }
                                    Button("Export…") { export(devotional) }
                                    Divider()
                                    Button("Delete", role: .destructive) {
                                        devotionalPendingDeletion = devotional
                                    }
                                }
                            }
                        }
                    }
                    .frame(minWidth: 230, idealWidth: 280, maxWidth: 360)

                    if let devotional = selectedDevotional {
                        devotionalDetail(devotional)
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
        }
        .navigationTitle("Devotionals")
        .searchable(text: $query, prompt: "Search devotionals")
        .toolbar {
            ToolbarItemGroup {
                Picker("Category", selection: $categoryFilter) {
                    Text("All Categories").tag(String?.none)
                    ForEach(devotionalCategories, id: \.self) { category in
                        Text(category.capitalized).tag(Optional(category))
                    }
                }
                Picker("Collection", selection: $moduleFilter) {
                    Text("All Collections").tag(String?.none)
                    ForEach(devotionalCollections, id: \.id) { collection in
                        Text(collection.name).tag(Optional(collection.id))
                    }
                }
                Button("New Devotional", systemImage: "square.and.pencil") { beginEditing(nil) }
                Button("Import Devotional", systemImage: "square.and.arrow.down") { importDevotional() }
                if let devotional = selectedDevotional, devotional.isEditable {
                    Button("Edit", systemImage: "pencil") { beginEditing(devotional) }
                    Menu("More", systemImage: "ellipsis.circle") {
                        Button("Export…", systemImage: "square.and.arrow.up") { export(devotional) }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            devotionalPendingDeletion = devotional
                        }
                    }
                }
                if let devotional = selectedDevotional {
                    Button("Present", systemImage: "rectangle.inset.filled.and.person.filled") {
                        presentingDevotional = devotional
                    }
                    ShareLink(
                        item: devotional.content,
                        subject: Text(devotional.title),
                        message: Text(devotional.summary ?? devotional.title)
                    ) {
                        Label("Share Markdown", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(item: $presentingDevotional) { devotional in
            DevotionalPresentationView(devotional: devotional)
                .environmentObject(model)
        }
        .confirmationDialog(
            "Delete this devotional?",
            isPresented: Binding(
                get: { devotionalPendingDeletion != nil },
                set: { if !$0 { devotionalPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let devotional = devotionalPendingDeletion else { return }
                delete(devotional)
            }
            Button("Cancel", role: .cancel) { devotionalPendingDeletion = nil }
        } message: {
            Text("This removes the personal devotional from this Mac. Installed module entries are never modified.")
        }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: model.devotionals) { _, _ in selectFirstIfNeeded() }
        .onChange(of: query) { _, _ in
            if !filteredDevotionals.contains(where: { $0.id == selection }) {
                selection = filteredDevotionals.first?.id
            }
        }
    }

    private func devotionalDetail(_ devotional: LampDevotional) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(devotional.title)
                            .font(.largeTitle.bold())
                        if devotional.isEditable {
                            Button("Edit", systemImage: "pencil") { beginEditing(devotional) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    if let subtitle = devotional.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        if let author = devotional.author, !author.isEmpty {
                            Label(author, systemImage: "person")
                        }
                        if let date = devotional.date, !date.isEmpty {
                            Label(date, systemImage: "calendar")
                        }
                        if let series = devotional.seriesName, !series.isEmpty {
                            Label(series, systemImage: "square.stack")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                if !devotional.keyScriptures.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Key Scripture")
                            .font(.headline)
                        HStack(spacing: 8) {
                            ForEach(devotional.keyScriptures) { scripture in
                                Button(scripture.displayDescription) {
                                    openReference(scripture.startReference)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                if let summary = devotional.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                Divider()

                DevotionalContentView(
                    markdown: devotional.content,
                    libraryRootURL: model.library.rootURL,
                    fontSize: devotionalFontSize
                )

                if let footnotes = devotional.footnotes, !footnotes.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Footnotes")
                            .font(.headline)
                        DevotionalContentView(
                            markdown: footnotes,
                            libraryRootURL: model.library.rootURL,
                            fontSize: max(devotionalFontSize - 1, 12)
                        )
                        .foregroundStyle(.secondary)
                    }
                }

                if !devotional.tags.isEmpty {
                    Text(devotional.tags.map { "#\($0)" }.joined(separator: "  "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func beginEditing(_ devotional: LampDevotional?) {
        openWindow(id: "devotional-editor", value: DevotionalEditorRequest(devotionalID: devotional?.id))
    }

    private var devotionalCategories: [String] {
        Array(Set(model.devotionals.compactMap { normalizedCategory($0.category) })).sorted()
    }

    private func normalizedCategory(_ category: String?) -> String? {
        category == "sermon" ? "exhortation" : category
    }

    private var devotionalCollections: [(id: String, name: String)] {
        Dictionary(grouping: model.devotionals, by: \.moduleID)
            .map { (id: $0.key, name: $0.value.first?.moduleName ?? $0.key) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func importDevotional() {
        let panel = NSOpenPanel()
        panel.title = "Import Devotional"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.json, UTType(exportedAs: "com.neus.lamp-bible.lamp", conformingTo: .data)]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        Task {
            do {
                let imported = try await model.library.importPersonalDevotional(from: sourceURL)
                model.refresh()
                selection = imported.first?.id
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func export(_ devotional: LampDevotional) {
        Task {
            do {
                let document = try await model.library.personalDevotionalDocument(id: devotional.id)
                let panel = NSSavePanel()
                panel.title = "Export Devotional Module"
                panel.nameFieldStringValue = document.suggestedModuleFilename
                panel.allowedContentTypes = [UTType(exportedAs: "com.neus.lamp-bible.lamp", conformingTo: .data)]
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
                _ = try await Task.detached(priority: .userInitiated) {
                    try LampModuleCompiler().compile(
                        data: document.jsonData,
                        sourceFilename: document.suggestedJSONFilename,
                        destinationURL: destinationURL
                    )
                }.value
                exportedURL = destinationURL
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func delete(_ devotional: LampDevotional) {
        devotionalPendingDeletion = nil
        Task {
            do {
                try await model.deletePersonalDevotional(id: devotional.id)
                selection = model.devotionals.first?.id
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func selectFirstIfNeeded() {
        if !model.devotionals.contains(where: { $0.id == selection }) {
            selection = model.devotionals.first?.id
        }
    }
}

private struct DevotionalPresentationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("devotional.fontSize") private var devotionalFontSize = 17.0
    let devotional: LampDevotional

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(devotional.title).font(.title.bold())
                    if let subtitle = devotional.subtitle { Text(subtitle).foregroundStyle(.secondary) }
                }
                Spacer()
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)
            Divider()
            ScrollView {
                DevotionalContentView(
                    markdown: devotional.content,
                    libraryRootURL: model.library.rootURL,
                    fontSize: devotionalFontSize + 5
                )
                .frame(maxWidth: 920, alignment: .leading)
                .padding(48)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(minWidth: 1_020, minHeight: 720)
    }
}

struct QuizzesView: View {
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("quiz.defaultAgeGroup") private var defaultQuizAgeGroup = ""
    @State private var selectedModuleID: String?
    @State private var selectedAgeGroupID: String?
    @State private var day = LampPlanCalendar.dayNumber(for: Date())
    @State private var questions: [LampQuizQuestion] = []
    @State private var revealedAnswers: Set<Int64> = []
    @State private var isLoading = false

    let showImporter: () -> Void
    let openReference: (Int) -> Void

    private var selectedModule: LampQuizModule? {
        model.quizModules.first { $0.id == selectedModuleID } ?? model.quizModules.first
    }

    private var selectedPlan: LampReadingPlan? {
        guard let planID = selectedModule?.planID else { return nil }
        return model.plans.first { $0.id == planID }
    }

    private var maximumDay: Int {
        max(selectedPlan?.duration ?? 366, 1)
    }

    private var loadKey: String {
        "\(selectedModule?.id ?? "none"):\(selectedAgeGroupID ?? "none"):\(day)"
    }

    var body: some View {
        Group {
            if model.quizModuleInstallations.isEmpty {
                ContentUnavailableView {
                    Label("No Quizzes", systemImage: "questionmark.bubble")
                } description: {
                    Text("Install a quiz .lamp module, or build one in Module Studio.")
                } actions: {
                    Button("Install Module…", action: showImporter)
                        .buttonStyle(.borderedProminent)
                }
            } else if let quiz = selectedModule {
                VStack(spacing: 0) {
                    quizControls(quiz)
                    Divider()
                    questionContent(quiz)
                }
            } else {
                ProgressView("Loading Quizzes…")
            }
        }
        .navigationTitle("Quizzes")
        .onAppear { configureSelection() }
        .onChange(of: model.quizModules) { _, _ in configureSelection() }
        .onChange(of: selectedModuleID) { _, _ in configureAgeGroup() }
        .onChange(of: selectedAgeGroupID) { _, ageGroupID in
            if let ageGroupID { defaultQuizAgeGroup = ageGroupID }
        }
        .task(id: loadKey) { await loadQuestions() }
    }

    private func quizControls(_ quiz: LampQuizModule) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Picker("Quiz", selection: $selectedModuleID) {
                    ForEach(model.quizModules) { module in
                        Text(module.name).tag(Optional(module.id))
                    }
                }
                .frame(maxWidth: 360)

                Picker("Age Group", selection: $selectedAgeGroupID) {
                    ForEach(quiz.ageGroups) { ageGroup in
                        Text("\(ageGroup.label) (\(ageGroup.ageRange))")
                            .tag(Optional(ageGroup.id))
                    }
                }
                .frame(maxWidth: 300)

                Stepper("Day \(day)", value: $day, in: 1...maximumDay)
                    .fixedSize()
            }

            if let description = quiz.description, !description.isEmpty {
                Text(description)
                    .foregroundStyle(.secondary)
            } else if let plan = selectedPlan {
                Text("Questions for \(plan.name)")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func questionContent(_ quiz: LampQuizModule) -> some View {
        if isLoading {
            ProgressView("Loading Day \(day)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if questions.isEmpty {
            ContentUnavailableView(
                "No Questions for Day \(day)",
                systemImage: "questionmark.bubble",
                description: Text("Choose another day or age group.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Day \(day)")
                            .font(.largeTitle.bold())
                        Spacer()
                        Text("\(questions.count) question\(questions.count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(questions) { question in
                        questionCard(question)
                    }
                }
                .frame(maxWidth: 820)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func questionCard(_ question: LampQuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Button {
                    openReference(question.startReference)
                } label: {
                    Label(question.readingDescription, systemImage: "book")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)

                Spacer()

                if question.isChristFocused {
                    Label("Christ-focused", systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(question.theme)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(question.question)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)

            if revealedAnswers.contains(question.id) {
                Divider()
                Text(question.answer)
                    .textSelection(.enabled)
                if !question.references.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(question.references, id: \.self) { reference in
                            Button(LampBibleReferenceFormatter.describeRange(from: reference, to: reference)) {
                                openReference(reference)
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }

            Button(revealedAnswers.contains(question.id) ? "Hide Answer" : "Reveal Answer") {
                if revealedAnswers.contains(question.id) {
                    revealedAnswers.remove(question.id)
                } else {
                    revealedAnswers.insert(question.id)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
    }

    private func configureSelection() {
        if !model.quizModules.contains(where: { $0.id == selectedModuleID }) {
            selectedModuleID = model.quizModules.first?.id
        }
        configureAgeGroup()
    }

    private func configureAgeGroup() {
        guard let quiz = selectedModule else {
            selectedAgeGroupID = nil
            return
        }
        if !quiz.ageGroups.contains(where: { $0.id == selectedAgeGroupID }) {
            selectedAgeGroupID = quiz.ageGroups.first { $0.id == defaultQuizAgeGroup }?.id
                ?? quiz.ageGroups.first?.id
        }
        day = min(max(day, 1), maximumDay)
    }

    private func loadQuestions() async {
        guard let quiz = selectedModule,
              let ageGroupID = selectedAgeGroupID else {
            questions = []
            return
        }
        isLoading = true
        revealedAnswers = []
        let loaded = await model.quizQuestions(
            moduleID: quiz.id,
            day: day,
            ageGroup: ageGroupID
        )
        guard !Task.isCancelled else { return }
        questions = loaded
        isLoading = false
    }
}
