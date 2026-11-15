import AppKit
import Combine
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampModuleKit
import SwiftUI
import UniformTypeIdentifiers

struct PlanReadingModeBar: View {
    @EnvironmentObject private var model: LibraryModel
    @Binding var mode: PlanReadingMode?
    @Binding var showingQuiz: Bool
    let openReading: (LampPlanReading) -> Void

    var body: some View {
        if let mode {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Plan Reading", systemImage: "checklist")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                    Text("\(mode.planName) · \(formattedDate(for: mode))")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                .frame(minWidth: 160, alignment: .leading)

                Divider()
                    .frame(height: 30)

                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(mode.readings) { reading in
                            HStack(spacing: 4) {
                                Button {
                                    model.toggleReading(
                                        planID: mode.planID,
                                        day: mode.day,
                                        readingIndex: reading.id,
                                        year: mode.year
                                    )
                                } label: {
                                    Image(systemName: isCompleted(reading, in: mode)
                                        ? "checkmark.circle.fill"
                                        : "circle")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(isCompleted(reading, in: mode) ? Color.accentColor : .secondary)
                                .help(isCompleted(reading, in: mode) ? "Mark incomplete" : "Mark complete")

                                Button(reading.displayDescription) {
                                    openReading(reading)
                                }
                                .buttonStyle(.plain)
                                .lineLimit(1)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(
                                reading.id == mode.activeReadingID
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.secondary.opacity(0.08),
                                in: Capsule()
                            )
                            .overlay {
                                Capsule().stroke(
                                    reading.id == mode.activeReadingID
                                        ? Color.accentColor.opacity(0.5)
                                        : Color.secondary.opacity(0.18)
                                )
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)

                Button(showingQuiz ? "Hide Quiz" : "Show Quiz", systemImage: "questionmark.bubble") {
                    showingQuiz.toggle()
                }
                .buttonStyle(.bordered)

                Button("Exit Plan Mode", systemImage: "xmark.circle") {
                    self.mode = nil
                }
                .buttonStyle(.borderless)
                .help("Exit plan reading mode")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func isCompleted(_ reading: LampPlanReading, in mode: PlanReadingMode) -> Bool {
        model.completedReadingIDs.contains(
            reading.completionID(planID: mode.planID, day: mode.day, year: mode.year)
        )
    }

    private func formattedDate(for mode: PlanReadingMode) -> String {
        LampPlanCalendar.date(forDayNumber: mode.day, year: mode.year)?
            .formatted(date: .abbreviated, time: .omitted)
            ?? "Day \(mode.day)"
    }
}

struct PlanReadingQuizPanel: View {
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("quiz.defaultAgeGroup") private var defaultQuizAgeGroup = ""
    @AppStorage("quiz.alwaysShowAnswers") private var alwaysShowAnswers = false
    let mode: PlanReadingMode
    let close: () -> Void
    let openReference: (Int) -> Void
    @State private var selectedQuizID: String?
    @State private var selectedAgeGroupID: String?
    @State private var questions: [LampQuizQuestion] = []
    @State private var revealedAnswers: Set<Int64> = []
    @State private var isLoading = false
    @StateObject private var readAloud = QuizReadAloudController()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reading Quiz")
                        .font(.headline)
                    Text(mode.activeReading?.displayDescription ?? "Day \(mode.day)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                QuizOptionsMenu()
                Button("Close Quiz", systemImage: "xmark") { close() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding(14)

            Divider()

            if matchingQuizzes.isEmpty {
                ContentUnavailableView(
                    "No Plan Quiz Installed",
                    systemImage: "questionmark.bubble",
                    description: Text("Install a quiz linked to \(mode.planName) to use it while reading.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let quiz = selectedQuiz {
                VStack(spacing: 10) {
                    if matchingQuizzes.count > 1 {
                        Picker("Quiz", selection: $selectedQuizID) {
                            ForEach(matchingQuizzes) { item in
                                Text(item.name).tag(Optional(item.id))
                            }
                        }
                    }

                    Picker("Age Group", selection: $selectedAgeGroupID) {
                        ForEach(quiz.ageGroups) { ageGroup in
                            Text("\(ageGroup.label) (\(ageGroup.ageRange))")
                                .tag(Optional(ageGroup.id))
                        }
                    }
                }
                .padding(12)

                Divider()

                quizContent
            } else {
                ProgressView("Loading quiz…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
        .onAppear { configureSelection() }
        .onChange(of: matchingQuizIDs) { _, _ in configureSelection() }
        .onChange(of: selectedQuizID) { _, _ in configureAgeGroup() }
        .onChange(of: loadKey) { _, _ in readAloud.stop() }
        .onChange(of: alwaysShowAnswers) { _, _ in readAloud.stop() }
        .onChange(of: selectedAgeGroupID) { _, ageGroupID in
            if let ageGroupID { defaultQuizAgeGroup = ageGroupID }
        }
        .task(id: loadKey) { await loadQuestions() }
        .onDisappear { readAloud.stop() }
    }

    @ViewBuilder
    private var quizContent: some View {
        if isLoading {
            ProgressView("Loading questions…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if displayedQuestions.isEmpty {
            ContentUnavailableView(
                "No Questions for This Reading",
                systemImage: "questionmark.bubble",
                description: Text("Try another age group or reading.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(displayedQuestions) { question in
                        questionCard(question)
                    }
                }
                .padding(14)
            }
        }
    }

    private func questionCard(_ question: LampQuizQuestion) -> some View {
        QuizQuestionCard(
            question: question,
            answerVisible: alwaysShowAnswers || revealedAnswers.contains(question.id),
            allowsAnswerToggle: !alwaysShowAnswers,
            showsTheme: false,
            readAloud: readAloud,
            openReference: openReference,
            toggleAnswer: {
                readAloud.stop()
                if revealedAnswers.contains(question.id) {
                    revealedAnswers.remove(question.id)
                } else {
                    revealedAnswers.insert(question.id)
                }
            }
        )
    }

    private var matchingQuizzes: [LampQuizModule] {
        model.quizModules.filter { $0.planID == mode.planID }
    }

    private var matchingQuizIDs: [String] {
        matchingQuizzes.map(\.id)
    }

    private var selectedQuiz: LampQuizModule? {
        matchingQuizzes.first { $0.id == selectedQuizID } ?? matchingQuizzes.first
    }

    private var loadKey: String {
        "\(selectedQuiz?.id ?? "none"):\(selectedAgeGroupID ?? "none"):\(mode.day)"
    }

    private var displayedQuestions: [LampQuizQuestion] {
        guard let reading = mode.activeReading else { return questions }
        let exact = questions.filter {
            $0.startReference == reading.startReference && $0.endReference == reading.endReference
        }
        if !exact.isEmpty { return exact }
        let overlapping = questions.filter {
            $0.startReference <= reading.endReference && $0.endReference >= reading.startReference
        }
        return overlapping.isEmpty ? questions : overlapping
    }

    private func configureSelection() {
        if !matchingQuizzes.contains(where: { $0.id == selectedQuizID }) {
            selectedQuizID = matchingQuizzes.first?.id
        }
        configureAgeGroup()
    }

    private func configureAgeGroup() {
        guard let quiz = selectedQuiz else {
            selectedAgeGroupID = nil
            return
        }
        if !quiz.ageGroups.contains(where: { $0.id == selectedAgeGroupID }) {
            selectedAgeGroupID = quiz.ageGroups.first { $0.id == defaultQuizAgeGroup }?.id
                ?? quiz.ageGroups.first?.id
        }
    }

    private func loadQuestions() async {
        guard let quiz = selectedQuiz, let ageGroupID = selectedAgeGroupID else {
            questions = []
            return
        }
        isLoading = true
        revealedAnswers = []
        let loaded = await model.quizQuestions(
            moduleID: quiz.id,
            day: mode.day,
            ageGroup: ageGroupID
        )
        guard !Task.isCancelled else { return }
        questions = loaded
        isLoading = false
    }
}
