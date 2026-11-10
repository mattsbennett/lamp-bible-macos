import AppKit
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampCore
import SwiftUI

/// Where the reader was left, for Today's way back to it.
struct TodayReaderPlace: Equatable {
    /// "John 1".
    let title: String
    /// The translation's short name.
    let translation: String
    /// The verse being read, or the chapter's first, to show what is there.
    let verseNumber: Int?
    let verseText: String?
}

/// The day's landing page: the date, the readings the followed plans set for
/// it, and the ways on from there that the library already has — the passage
/// left open in the reader, the quiz on today's readings, the writing last
/// worked on.
///
/// Laid out as a page rather than one card at the top of an empty window:
/// the readings lead, as the day's one task, and the rest sit under them as
/// equals, each a single click from where it goes.
struct TodayView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var date = Date()
    @State private var daysByPlanID: [String: LampReadingPlanDay] = [:]
    @State private var isLoading = false
    @State private var isMakingPlan = false
    @State private var showingCalendar = false

    let readerPlace: TodayReaderPlace?
    let showImporter: () -> Void
    let showPlans: () -> Void
    let openReading: (PlanReadingMode) -> Void
    let openAllReadings: (PlanReadingMode) -> Void
    let continueReading: () -> Void
    let openQuiz: (String) -> Void
    let openWriting: (String) -> Void

    private var dayNumber: Int { LampPlanCalendar.dayNumber(for: date) }
    private var year: Int { LampPlanCalendar.year(for: date) }

    private var selectedPlans: [LampReadingPlan] {
        model.plans.filter { model.selectedPlanIDs.contains($0.id) }
    }

    private var request: TodayDayRequest {
        TodayDayRequest(
            day: dayNumber,
            year: year,
            planIDs: selectedPlans.map(\.id).sorted(),
            translationID: model.selectedTranslationID
        )
    }

    var body: some View {
        Group {
            if model.plans.isEmpty {
                ContentUnavailableView {
                    Label("No Reading Plans Installed", systemImage: "calendar.badge.plus")
                } description: {
                    Text("Make a plan from the passages you want to read, or install a plan .lamp module.")
                } actions: {
                    Button("New Plan…") { isMakingPlan = true }
                        .buttonStyle(.borderedProminent)
                    Button("Install Module…", action: showImporter)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        header
                        if !selectedPlans.isEmpty, !week.isEmpty {
                            weekStrip
                        }
                        AddedPlanNotice()
                        readings
                        companions
                    }
                    .frame(maxWidth: 940, alignment: .leading)
                    .padding(.horizontal, 40)
                    .padding(.top, 34)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Today")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { dateControls }
        }
        .sheet(isPresented: $isMakingPlan) { NewReadingPlanSheet() }
        // A plan asked for in another app is installed by Lamp, not by the
        // helper that was asked; here is where someone will look for it.
        .task { await model.takeInRequestedReadingPlans() }
        .task(id: request) { await loadDays() }
    }

    // MARK: The date

    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(isToday ? "Today · \(date.formatted(.dateTime.weekday(.wide)))"
                             : date.formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: 13, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(.tint)
                Text(date.formatted(.dateTime.month(.wide).day().year()))
                    .font(.system(size: 38, weight: .bold))
                Text(summary)
                    .font(.title3)
                    .foregroundStyle(Color.lampSecondaryText)
            }
            Spacer(minLength: 0)
            if totalReadings > 0 {
                TodayProgressRing(done: completedReadings, total: totalReadings)
            }
        }
    }

    private var summary: String {
        guard totalReadings > 0 else { return "Day \(dayNumber) of the year" }
        let remaining = totalReadings - completedReadings
        let progress = remaining == 0
            ? "every reading done"
            : "\(remaining) of \(totalReadings) \(totalReadings == 1 ? "reading" : "readings") to go"
        let minutes = remaining == 0 ? "" : remainingMinutes.map { " · about \($0) min" } ?? ""
        return "Day \(dayNumber) · \(progress)\(minutes)"
    }

    /// Steps a day either way, and the calendar for anything further. The
    /// date as words, rather than the field's numeric form, which read as a
    /// setting rather than as the day.
    private var dateControls: some View {
        HStack(spacing: 2) {
            Button("Previous Day", systemImage: "chevron.left") { step(by: -1) }
                .labelStyle(.iconOnly)
                .help("The day before")
            Button {
                showingCalendar = true
            } label: {
                Label(isToday ? "Today" : date.formatted(.dateTime.month(.abbreviated).day()),
                      systemImage: "calendar")
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
            }
            .help("Choose a day from the calendar")
            .popover(isPresented: $showingCalendar, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    DatePicker("Reading Date", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                    Button("Go to Today") {
                        date = Calendar.current.startOfDay(for: Date())
                        showingCalendar = false
                    }
                    .disabled(isToday)
                }
                .padding()
            }
            Button("Next Day", systemImage: "chevron.right") { step(by: 1) }
                .labelStyle(.iconOnly)
                .help("The day after")
        }
        .buttonStyle(.accessoryBar)
    }

    private func step(by days: Int) {
        date = Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
    }

    // MARK: The week

    /// The week around the day shown, each day with how much of its reading
    /// is done, so the page says how the week is going as well as today; a
    /// click on a day shows that day.
    private var weekStrip: some View {
        HStack(spacing: 8) {
            ForEach(week) { day in
                let state = completion(of: day)
                Button {
                    date = day.date
                } label: {
                    TodayWeekDayCell(
                        date: day.date,
                        isShown: Calendar.current.isDate(day.date, inSameDayAs: date),
                        isToday: Calendar.current.isDateInToday(day.date),
                        done: state.done,
                        total: state.total
                    )
                }
                .buttonStyle(.plain)
                .help(weekDayHelp(day, state))
                .accessibilityLabel(weekDayHelp(day, state))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func completion(of day: TodayWeekDay) -> (done: Int, total: Int) {
        var done = 0, total = 0
        for (planID, planDay) in day.plans {
            total += planDay.readings.count
            done += planDay.readings.count {
                model.completedReadingIDs.contains($0.completionID(planID: planID, day: planDay.day, year: day.year))
            }
        }
        return (done, total)
    }

    private func weekDayHelp(_ day: TodayWeekDay, _ state: (done: Int, total: Int)) -> String {
        let name = day.date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        guard state.total > 0 else { return "\(name): no readings" }
        return "\(name): \(state.done) of \(state.total) readings done"
    }

    // MARK: The readings

    @ViewBuilder
    private var readings: some View {
        if selectedPlans.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("No plan is set to appear in Today.")
                    .font(.title3.weight(.semibold))
                Text("Choose which of your reading plans set the day’s readings.")
                    .foregroundStyle(Color.lampSecondaryText)
                Button("Choose Plans", action: showPlans)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .lampCard(padding: 22)
        } else if isLoading && daysByPlanID.isEmpty {
            ProgressView("Loading Today’s Readings…")
                .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            VStack(alignment: .leading, spacing: LampMetrics.cardSpacing) {
                ForEach(selectedPlans) { plan in
                    if let day = daysByPlanID[plan.id] {
                        TodayPlanCard(
                            plan: plan,
                            day: day,
                            year: year,
                            wordCounts: wordCounts[plan.id] ?? [:],
                            openReading: openReading,
                            openAllReadings: openAllReadings
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(plan.name, systemImage: "checklist")
                                .font(.headline)
                            Text("This plan has no reading for day \(dayNumber).")
                                .foregroundStyle(Color.lampSecondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lampCard(padding: 20)
                    }
                }
            }
        }
    }

    private var completedReadings: Int {
        selectedPlans.reduce(0) { total, plan in
            guard let day = daysByPlanID[plan.id] else { return total }
            return total + day.readings.count {
                model.completedReadingIDs.contains($0.completionID(planID: plan.id, day: day.day, year: year))
            }
        }
    }

    private var totalReadings: Int {
        selectedPlans.reduce(0) { $0 + (daysByPlanID[$1.id]?.readings.count ?? 0) }
    }

    /// The seven days of the shown day's week, with each followed plan's
    /// readings for them.
    @State private var week: [TodayWeekDay] = []

    /// Each plan's readings' lengths in words, by reading. Counted once here
    /// for the rows and the day's total both.
    @State private var wordCounts: [String: [Int: Int]] = [:]
    @AppStorage("plans.wordsPerMinute") private var wordsPerMinute = 225

    /// What is left of the day's reading, in minutes. Nil until counted: a
    /// guess shown and then corrected is worse than nothing for the moment
    /// counting takes.
    private var remainingMinutes: Int? {
        guard !wordCounts.isEmpty else { return nil }
        var words = 0
        for plan in selectedPlans {
            guard let day = daysByPlanID[plan.id] else { continue }
            for reading in day.readings where !model.completedReadingIDs.contains(
                reading.completionID(planID: plan.id, day: day.day, year: year)
            ) {
                words += wordCounts[plan.id]?[reading.id] ?? 0
            }
        }
        return max(1, Int((Double(words) / Double(max(wordsPerMinute, 1))).rounded()))
    }

    // MARK: The ways on

    /// Each one shown only where the library has it; the grid closes up
    /// around what is there.
    @ViewBuilder
    private var companions: some View {
        let quizzes = todaysQuizzes
        let writing = latestWriting
        if readerPlace != nil || !quizzes.isEmpty || writing != nil {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pick Up Where You Left Off")
                    .lampSectionHeading()
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 250), spacing: LampMetrics.cardSpacing, alignment: .top)],
                    alignment: .leading,
                    spacing: LampMetrics.cardSpacing
                ) {
                    if let readerPlace {
                        TodayCompanionCard(
                            symbol: "book",
                            eyebrow: "Continue Reading",
                            title: readerPlace.title,
                            detail: readerPlace.verseText,
                            detailIsScripture: true,
                            verseNumber: readerPlace.verseNumber,
                            footnote: readerPlace.translation,
                            action: ("Open Reader", continueReading)
                        )
                    }
                    ForEach(quizzes, id: \.id) { quiz in
                        TodayCompanionCard(
                            symbol: "questionmark.bubble",
                            eyebrow: "Today’s Quiz",
                            title: quiz.name,
                            detail: quiz.description,
                            detailIsScripture: false,
                            verseNumber: nil,
                            footnote: "\(quiz.questionsPerReading) questions a reading · day \(dayNumber)",
                            action: ("Take the Quiz", { openQuiz(quiz.id) })
                        )
                    }
                    if let writing {
                        TodayCompanionCard(
                            symbol: "sun.max",
                            eyebrow: "Your Writing",
                            title: writing.title,
                            detail: writing.summary ?? writing.subtitle,
                            detailIsScripture: false,
                            verseNumber: nil,
                            footnote: writing.lastModified.map {
                                "Edited \($0.formatted(.relative(presentation: .named)))"
                            },
                            action: ("Keep Writing", { openWriting(writing.id) })
                        )
                    }
                }
            }
        }
    }

    /// The quiz modules written for the plans Today follows.
    private var todaysQuizzes: [LampQuizModule] {
        let planIDs = Set(selectedPlans.map(\.id))
        return model.quizModules.filter { planIDs.contains($0.planID) }
    }

    /// The reader's own writing most recently changed.
    private var latestWriting: LampDevotional? {
        model.devotionals
            .filter { $0.isEditable && !$0.title.isEmpty }
            .max { ($0.lastModified ?? .distantPast) < ($1.lastModified ?? .distantPast) }
    }

    // MARK: Loading

    private func loadDays() async {
        isLoading = true
        await model.loadPlanProgress(year: year)
        var loaded: [String: LampReadingPlanDay] = [:]
        do {
            for plan in selectedPlans {
                if let day = try await model.library.readingPlanDay(moduleID: plan.id, day: dayNumber) {
                    loaded[plan.id] = day
                }
            }
            guard !Task.isCancelled else { return }
            daysByPlanID = loaded
            week = try await loadWeek(around: date, today: loaded)
        } catch {
            guard !Task.isCancelled else { return }
            model.errorMessage = error.localizedDescription
            daysByPlanID = [:]
        }
        isLoading = false
        await loadWordCounts(for: loaded)
    }

    /// The shown day's week, reusing the shown day's readings already read.
    private func loadWeek(
        around shown: Date,
        today: [String: LampReadingPlanDay]
    ) async throws -> [TodayWeekDay] {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: shown) else { return [] }
        var days: [TodayWeekDay] = []
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: interval.start) else { continue }
            let number = LampPlanCalendar.dayNumber(for: day)
            let year = LampPlanCalendar.year(for: day)
            var plans: [(planID: String, day: LampReadingPlanDay)] = []
            for plan in selectedPlans {
                if calendar.isDate(day, inSameDayAs: shown) {
                    if let planDay = today[plan.id] { plans.append((plan.id, planDay)) }
                } else if let planDay = try await model.library.readingPlanDay(moduleID: plan.id, day: number) {
                    plans.append((plan.id, planDay))
                }
            }
            try Task.checkCancellation()
            days.append(TodayWeekDay(date: day, year: year, plans: plans))
        }
        return days
    }

    private func loadWordCounts(for days: [String: LampReadingPlanDay]) async {
        guard let translationID = model.selectedTranslationID else {
            wordCounts = [:]
            return
        }
        var counts: [String: [Int: Int]] = [:]
        for (planID, day) in days {
            for reading in day.readings {
                counts[planID, default: [:]][reading.id] = try? await model.library.translationWordCount(
                    moduleID: translationID,
                    startReference: reading.startReference,
                    endReference: reading.endReference
                )
            }
        }
        guard !Task.isCancelled else { return }
        wordCounts = counts
    }
}

private struct TodayDayRequest: Hashable {
    let day: Int
    let year: Int
    let planIDs: [String]
    /// Reading times are counted in the translation being read.
    let translationID: String?
}

private struct TodayWeekDay: Identifiable {
    let date: Date
    let year: Int
    let plans: [(planID: String, day: LampReadingPlanDay)]

    var id: Date { date }
}

/// One day of the week strip: its name and date, and a mark for its reading —
/// a filled check when all of it is done, a partial ring part way, an empty
/// ring before any. The day shown is filled with the accent; today's name is
/// in the accent when another day is shown.
private struct TodayWeekDayCell: View {
    let date: Date
    let isShown: Bool
    let isToday: Bool
    let done: Int
    let total: Int
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 5) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)))
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(isShown || isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.lampSecondaryText))
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
            mark
                .frame(height: 14)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        // The day shown in a wash of the accent with an accent edge, not
        // solid: solid, it was the heaviest thing on the page and outweighed
        // the Start Reading button below it.
        .background(
            isShown ? AnyShapeStyle(Color.accentColor.opacity(0.13))
                : AnyShapeStyle(isHovered ? Color.lampRowHover : Color.lampCardFill),
            in: RoundedRectangle(cornerRadius: LampMetrics.tileRadius + 3, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LampMetrics.tileRadius + 3, style: .continuous)
                .strokeBorder(isShown ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.lampCardStroke),
                              lineWidth: isShown ? 1.5 : 1)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var mark: some View {
        let tint = AnyShapeStyle(.tint)
        if total == 0 {
            Text("–").font(.caption).foregroundStyle(.tertiary)
        } else if done >= total {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
        } else {
            ZStack {
                Circle().stroke(Color.lampSecondaryText.opacity(0.7), lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: Double(done) / Double(total))
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
        }
    }
}

/// How much of the day's reading is done, as a ring the eye takes in at once.
private struct TodayProgressRing: View {
    let done: Int
    let total: Int

    private var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }

    var body: some View {
        // The track in a wash of the accent rather than grey, so the ring
        // reads as the day's measure even before anything is read; a grey
        // track at 0 of 3 read as a decoration.
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.28), lineWidth: 9)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(.tint, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text("\(done) of \(total)")
                    .font(.system(size: 17, weight: .bold).monospacedDigit())
                Text(done == total ? "all read" : "read")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.lampSecondaryText)
            }
        }
        .frame(width: 84, height: 84)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(done) of \(total) readings done")
    }
}

/// One plan's readings for the day.
private struct TodayPlanCard: View {
    @EnvironmentObject private var model: LibraryModel
    let plan: LampReadingPlan
    let day: LampReadingPlanDay
    let year: Int
    let wordCounts: [Int: Int]
    let openReading: (PlanReadingMode) -> Void
    let openAllReadings: (PlanReadingMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "checklist")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.name)
                        .font(.title3.weight(.semibold))
                    Text("Day \(day.day) · \(completedCount) of \(day.readings.count) done")
                        .font(.callout)
                        .foregroundStyle(Color.lampSecondaryText)
                }
                Spacer(minLength: 12)
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Open All in Tabs", systemImage: "rectangle.stack.badge.plus") {
                        guard let first = day.readings.first else { return }
                        openAllReadings(readingMode(activeReadingID: first.id))
                    }
                    .disabled(day.readings.isEmpty)
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More plan actions")
                // Plain once the day is done, as on the phone: reading
                // again is no longer the thing to do next.
                if isDayDone {
                    readButton.buttonStyle(.bordered)
                } else {
                    readButton.buttonStyle(.borderedProminent)
                }
            }
            .padding(.bottom, 12)

            if let description = plan.description, !description.isEmpty {
                // Held to a reading measure: across the full card it ran to
                // one very long line.
                Text(description)
                    .font(.callout)
                    .foregroundStyle(Color.lampSecondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 600, alignment: .leading)
                    .padding(.bottom, 12)
            }

            VStack(spacing: 0) {
                ForEach(day.readings) { reading in
                    Divider()
                    TodayReadingRow(
                        plan: plan,
                        day: day,
                        year: year,
                        reading: reading,
                        wordCount: wordCounts[reading.id],
                        open: { openReading(readingMode(activeReadingID: reading.id)) }
                    )
                }
            }
        }
        .lampCard(padding: 20)
    }

    private var completedCount: Int {
        day.readings.count(where: isCompleted)
    }

    private var readButton: some View {
        Button {
            guard let next = firstUnread ?? day.readings.first else { return }
            openReading(readingMode(activeReadingID: next.id))
        } label: {
            Label(readTitle, systemImage: "book")
                .padding(.horizontal, 4)
        }
        .controlSize(.large)
        .disabled(day.readings.isEmpty)
        .help("Open the plan’s readings in the reader")
    }

    private var isDayDone: Bool {
        !day.readings.isEmpty && firstUnread == nil
    }

    /// The same words as the phone's Today button.
    private var readTitle: String {
        if isDayDone { return "Read Again" }
        return completedCount == 0 ? "Start Reading" : "Continue Reading"
    }

    private var firstUnread: LampPlanReading? {
        day.readings.first { !isCompleted($0) }
    }

    private func isCompleted(_ reading: LampPlanReading) -> Bool {
        model.completedReadingIDs.contains(reading.completionID(planID: plan.id, day: day.day, year: year))
    }

    private func readingMode(activeReadingID: Int) -> PlanReadingMode {
        PlanReadingMode(
            planID: plan.id,
            planName: plan.name,
            day: day.day,
            year: year,
            readings: day.readings,
            activeReadingID: activeReadingID
        )
    }
}

/// A reading: its tick, its passage, how long it takes, and the way to it.
/// The whole row opens the reading; the tick is its own target.
private struct TodayReadingRow: View {
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("plans.wordsPerMinute") private var wordsPerMinute = 225
    @AppStorage("plans.externalBibleApp") private var externalBibleApp = ""
    @State private var isHovered = false
    let plan: LampReadingPlan
    let day: LampReadingPlanDay
    let year: Int
    let reading: LampPlanReading
    let wordCount: Int?
    let open: () -> Void

    private var isCompleted: Bool {
        model.completedReadingIDs.contains(reading.completionID(planID: plan.id, day: day.day, year: year))
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.toggleReading(planID: plan.id, day: day.day, readingIndex: reading.id, year: year)
            } label: {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isCompleted ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.lampSecondaryText))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(isCompleted ? "Mark incomplete" : "Mark complete")
            .accessibilityLabel(isCompleted ? "Mark \(reading.displayDescription) incomplete"
                                            : "Mark \(reading.displayDescription) complete")

            Button(action: open) {
                HStack(spacing: 12) {
                    Text(reading.displayDescription)
                        .font(.system(size: 15, weight: .medium))
                        .strikethrough(isCompleted, color: .secondary)
                        .foregroundStyle(isCompleted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let wordCount {
                        Label(
                            ReadingTimeEstimator.description(wordCount: wordCount, wordsPerMinute: wordsPerMinute),
                            systemImage: "clock"
                        )
                        .labelStyle(.titleAndIcon)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(Color.lampSecondaryText)
                        .help("Estimated at \(wordsPerMinute) words per minute")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(reading.displayDescription) in the reader")
            .accessibilityLabel("Open \(reading.displayDescription)")

            // Nothing to offer is the ordinary case: most readers have no
            // other Bible app at all, and a button that opens an empty menu is
            // worse than no button. Where there is one, the button shows with
            // the row's hover, and the row's context menu holds the same; a
            // permanent cluster of small controls on every row was the noise.
            if !ExternalBibleApplication.openableOnThisMac.isEmpty {
                Menu("Open in External Bible", systemImage: "arrow.up.right.square") {
                    externalBibleItems
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Open in another Bible app")
                .opacity(isHovered ? 1 : 0)
                .accessibilityHidden(!isHovered)
            }
        }
        .contextMenu {
            Button("Open in Reader", action: open)
            Button(isCompleted ? "Mark Incomplete" : "Mark Complete") {
                model.toggleReading(planID: plan.id, day: day.day, readingIndex: reading.id, year: year)
            }
            if !ExternalBibleApplication.openableOnThisMac.isEmpty {
                Divider()
                Menu("Open in External Bible") { externalBibleItems }
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 8)
        .background(
            isHovered ? AnyShapeStyle(Color.primary.opacity(0.045)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: LampMetrics.tileRadius)
        )
        .padding(.horizontal, -8)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var externalBibleItems: some View {
        if let preferredApplication {
            Button("Open in \(preferredApplication.rawValue)") {
                openExternally(using: preferredApplication)
            }
            Divider()
        }
        ForEach(ExternalBibleApplication.openableOnThisMac) { application in
            Button(application.rawValue) { openExternally(using: application) }
        }
    }

    private var preferredApplication: ExternalBibleApplication? {
        // Checked against what this Mac can open, not just what was chosen:
        // a default saved while an app was installed outlives the app.
        ExternalBibleApplication(rawValue: externalBibleApp)
            .flatMap { ExternalBibleApplication.openableOnThisMac.contains($0) ? $0 : nil }
    }

    private func openExternally(using application: ExternalBibleApplication) {
        guard let url = application.url(
            startReference: reading.startReference,
            endReference: reading.endReference
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// One of the ways on from Today: what it is, what it holds, and its button.
private struct TodayCompanionCard: View {
    let symbol: String
    let eyebrow: String
    let title: String
    let detail: String?
    /// Scripture is set in the reader's serif, as it is everywhere else.
    let detailIsScripture: Bool
    /// Set before scripture as the reader sets it: small, raised, quieter.
    let verseNumber: Int?
    let footnote: String?
    let action: (title: String, run: () -> Void)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(eyebrow, systemImage: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(.tint)
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            if let detail, !detail.isEmpty {
                ((verseNumber.map {
                    Text("\($0) ")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .baselineOffset(5)
                        .foregroundStyle(Color.lampVerseNumber)
                } ?? Text(""))
                + Text(detail))
                    .font(detailIsScripture
                          ? .system(size: 15, design: .serif)
                          : .callout)
                    .foregroundStyle(detailIsScripture ? Color.lampProse : Color.lampSecondaryText)
                    .lineSpacing(3)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // On a line of its own, above the button, so neither cuts the
            // other short.
            if let footnote {
                Text(footnote)
                    .font(.callout)
                    .foregroundStyle(Color.lampSecondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            // Tinted, so the way on reads as a button rather than a grey chip.
            Button(action.title, action: action.run)
                .buttonStyle(.bordered)
                .tint(.accentColor)
                .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .lampCard(padding: 18)
    }
}
