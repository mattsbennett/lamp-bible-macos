import LampCore
import SwiftUI

struct DevotionalsView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var selection: String?
    @State private var query = ""

    let showImporter: () -> Void
    let openReference: (Int) -> Void

    private var filteredDevotionals: [LampDevotional] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return model.devotionals }
        return model.devotionals.filter { devotional in
            [
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
            if model.devotionalModules.isEmpty {
                ContentUnavailableView {
                    Label("No Devotionals", systemImage: "sun.max")
                } description: {
                    Text("Install a devotional .lamp module, or build one in Module Studio.")
                } actions: {
                    Button("Install Module…", action: showImporter)
                        .buttonStyle(.borderedProminent)
                }
            } else if model.devotionals.isEmpty {
                ContentUnavailableView(
                    "No Devotional Entries",
                    systemImage: "sun.max",
                    description: Text("The installed devotional modules do not contain any entries.")
                )
            } else {
                HSplitView {
                    List(selection: $selection) {
                        ForEach(filteredDevotionals) { devotional in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(devotional.title)
                                    .font(.headline)
                                    .lineLimit(2)
                                Text(devotional.seriesName ?? devotional.moduleName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 4)
                            .tag(Optional(devotional.id))
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
                    Text(devotional.title)
                        .font(.largeTitle.bold())
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

                Text(devotional.content)
                    .font(.body)
                    .lineSpacing(6)
                    .textSelection(.enabled)

                if let footnotes = devotional.footnotes, !footnotes.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Footnotes")
                            .font(.headline)
                        Text(footnotes)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
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

    private func selectFirstIfNeeded() {
        if !model.devotionals.contains(where: { $0.id == selection }) {
            selection = model.devotionals.first?.id
        }
    }
}

struct QuizzesView: View {
    @EnvironmentObject private var model: LibraryModel
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
            selectedAgeGroupID = quiz.ageGroups.first?.id
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
