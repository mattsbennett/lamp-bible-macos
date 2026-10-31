import AppKit
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampCore
import SwiftUI

private struct PlanDayRequest: Hashable {
    let day: Int
    let year: Int
    let planIDs: [String]
}

struct PlanReadingMode: Equatable {
    let planID: String
    let planName: String
    let day: Int
    let year: Int
    let readings: [LampPlanReading]
    var activeReadingID: Int

    var activeReading: LampPlanReading? {
        readings.first { $0.id == activeReadingID }
    }
}

struct TodayPlansView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var date = Date()
    @State private var daysByPlanID: [String: LampReadingPlanDay] = [:]
    @State private var isLoading = false
    @State private var isMakingPlan = false

    let showImporter: () -> Void
    let showPlans: () -> Void
    let openReading: (PlanReadingMode) -> Void
    let openAllReadings: (PlanReadingMode) -> Void

    private var dayNumber: Int {
        LampPlanCalendar.dayNumber(for: date)
    }

    private var year: Int {
        LampPlanCalendar.year(for: date)
    }

    private var selectedPlans: [LampReadingPlan] {
        model.plans.filter { model.selectedPlanIDs.contains($0.id) }
    }

    private var request: PlanDayRequest {
        PlanDayRequest(
            day: dayNumber,
            year: year,
            planIDs: selectedPlans.map(\.id).sorted()
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
            } else if selectedPlans.isEmpty {
                ContentUnavailableView {
                    Label("Choose a Reading Plan", systemImage: "checklist")
                } description: {
                    Text("Select one or more installed plans to include in Today.")
                } actions: {
                    Button("Choose Plans", action: showPlans)
                        .buttonStyle(.borderedProminent)
                }
            } else if isLoading && daysByPlanID.isEmpty {
                ProgressView("Loading Today’s Readings…")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(date.formatted(date: .complete, time: .omitted))
                                .font(.largeTitle.bold())
                            Text("Plan day \(dayNumber)")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }

                        AddedPlanNotice()

                        ForEach(selectedPlans) { plan in
                            if let day = daysByPlanID[plan.id] {
                                PlanDayCard(
                                    plan: plan,
                                    day: day,
                                    year: year,
                                    openReading: openReading,
                                    openAllReadings: openAllReadings
                                )
                            } else {
                                GroupBox(plan.name) {
                                    ContentUnavailableView(
                                        "No Reading for This Date",
                                        systemImage: "calendar",
                                        description: Text("This plan does not contain day \(dayNumber).")
                                    )
                                    .frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 880, alignment: .leading)
                    .padding(36)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Today")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                CalendarDateField(title: "Reading Date", selection: $date)
            }
        }
        .sheet(isPresented: $isMakingPlan) { NewReadingPlanSheet() }
        // A plan asked for in another app is installed by Lamp, not by the
        // helper that was asked; here is where someone will look for it.
        .task { await model.takeInRequestedReadingPlans() }
        .task(id: request) {
            await loadDays()
        }
    }

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
        } catch {
            guard !Task.isCancelled else { return }
            model.errorMessage = error.localizedDescription
            daysByPlanID = [:]
        }
        isLoading = false
    }
}

struct ReadingPlansView: View {
    @EnvironmentObject private var model: LibraryModel
    /// A plan a search result asked for. This list has no selection — every
    /// plan is shown at once — so the request is honoured by scrolling to it
    /// rather than by selecting it.
    @Binding var initialPlanID: String?
    let showImporter: () -> Void
    let openReading: (PlanReadingMode) -> Void
    let openAllReadings: (PlanReadingMode) -> Void

    @State private var isMakingPlan = false
    private let date = Date()

    /// Brings the plan a search result named into view, and forgets the
    /// request so returning here later does not scroll away from wherever
    /// the reader left off.
    ///
    /// The list is lazy, so a plan far down it may not be built yet when
    /// this first runs; the scroll is asked for on the next turn of the
    /// run loop, by which time the row exists.
    private func showRequestedPlan(with proxy: ScrollViewProxy) {
        guard let id = initialPlanID else { return }
        initialPlanID = nil
        Task { @MainActor in
            withAnimation { proxy.scrollTo(id, anchor: .top) }
        }
    }

    var body: some View {
        Group {
            if model.plans.isEmpty {
                ContentUnavailableView {
                    Label("No Reading Plans Installed", systemImage: "calendar.badge.plus")
                } description: {
                    Text("Make a plan from the passages you want to read, or install one as a portable .lamp module.")
                } actions: {
                    Button("New Plan…") { isMakingPlan = true }
                        .buttonStyle(.borderedProminent)
                    Button("Install Module…", action: showImporter)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Reading Plans")
                                    .font(.largeTitle.bold())
                                Text("Choose which plans appear in Today and preview the current assignments.")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.bottom, 8)

                            AddedPlanNotice()

                            ForEach(model.plans) { plan in
                                ReadingPlanCard(
                                    plan: plan,
                                    date: date,
                                    openReading: openReading,
                                    openAllReadings: openAllReadings
                                )
                                .id(plan.id)
                            }
                        }
                        .frame(maxWidth: 880, alignment: .leading)
                        .padding(36)
                        .frame(maxWidth: .infinity)
                    }
                    .onAppear { showRequestedPlan(with: proxy) }
                    .onChange(of: initialPlanID) { _, _ in showRequestedPlan(with: proxy) }
                }
            }
        }
        .navigationTitle("Reading Plans")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Plan", systemImage: "calendar.badge.plus") { isMakingPlan = true }
                    .help("Make a reading plan from the passages you want to read")
            }
        }
        .sheet(isPresented: $isMakingPlan) { NewReadingPlanSheet() }
        .task {
            await model.loadPlanProgress(year: LampPlanCalendar.year(for: date))
            await model.takeInRequestedReadingPlans()
        }
    }
}

/// What another app asked Lamp to add, said where the plan turns up.
///
/// The asking happened in another app; this is the only place the reader finds
/// out that their library has a plan in it that they did not install here.
private struct AddedPlanNotice: View {
    @EnvironmentObject private var model: LibraryModel

    var body: some View {
        if let message = model.addedPlanMessage {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(message, systemImage: "calendar.badge.plus")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Dismiss", systemImage: "xmark") { model.addedPlanMessage = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct ReadingPlanCard: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var day: LampReadingPlanDay?
    let plan: LampReadingPlan
    let date: Date
    let openReading: (PlanReadingMode) -> Void
    let openAllReadings: (PlanReadingMode) -> Void

    private var dayNumber: Int { LampPlanCalendar.dayNumber(for: date) }
    private var year: Int { LampPlanCalendar.year(for: date) }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plan.name).font(.title2.weight(.semibold))
                        if let author = plan.author, !author.isEmpty {
                            Text(author).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Toggle(
                        "Include in Today",
                        isOn: Binding(
                            get: { model.selectedPlanIDs.contains(plan.id) },
                            set: { model.setPlanSelected(plan.id, selected: $0) }
                        )
                    )
                    .toggleStyle(.switch)
                }

                if let description = plan.description, !description.isEmpty {
                    Text(description)
                }

                HStack(spacing: 18) {
                    Label("\(plan.duration) days", systemImage: "calendar")
                    if let readingsPerDay = plan.readingsPerDay {
                        Label("\(readingsPerDay) readings per day", systemImage: "book.pages")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                if let day {
                    Divider()
                    PlanDayReadings(
                        plan: plan,
                        day: day,
                        year: year,
                        openReading: openReading,
                        openAllReadings: openAllReadings
                    )
                }

                if let fullDescription = plan.fullDescription, !fullDescription.isEmpty {
                    DisclosureGroup("About This Plan") {
                        Text(fullDescription)
                            .textSelection(.enabled)
                            .padding(.top, 8)
                    }
                }
            }
            .padding(8)
        }
        .task(id: dayNumber) {
            do {
                day = try await model.library.readingPlanDay(moduleID: plan.id, day: dayNumber)
            } catch {
                model.errorMessage = error.localizedDescription
                day = nil
            }
        }
    }
}

private struct PlanDayCard: View {
    let plan: LampReadingPlan
    let day: LampReadingPlanDay
    let year: Int
    let openReading: (PlanReadingMode) -> Void
    let openAllReadings: (PlanReadingMode) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                if let description = plan.description, !description.isEmpty {
                    Text(description)
                        .foregroundStyle(.secondary)
                }
                PlanDayReadings(
                    plan: plan,
                    day: day,
                    year: year,
                    openReading: openReading,
                    openAllReadings: openAllReadings
                )
            }
            .padding(8)
        } label: {
            Label(plan.name, systemImage: "checklist")
                .font(.headline)
        }
    }
}

private struct PlanDayReadings: View {
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("plans.wordsPerMinute") private var wordsPerMinute = 225
    @AppStorage("plans.externalBibleApp") private var externalBibleApp = ""
    @State private var wordCounts: [Int: Int] = [:]
    let plan: LampReadingPlan
    let day: LampReadingPlanDay
    let year: Int
    let openReading: (PlanReadingMode) -> Void
    let openAllReadings: (PlanReadingMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Day \(day.day)")
                    .font(.headline)
                Spacer()
                Text("\(completedCount) of \(day.readings.count) complete")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open", systemImage: "book") {
                    guard let first = day.readings.first else { return }
                    openReading(readingMode(activeReadingID: first.id))
                }
                .buttonStyle(.borderedProminent)
                .disabled(day.readings.isEmpty)

                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Open All in Tabs", systemImage: "rectangle.stack.badge.plus") {
                        guard let first = day.readings.first else { return }
                        openAllReadings(readingMode(activeReadingID: first.id))
                    }
                    .disabled(day.readings.isEmpty)
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .help("More plan actions")
            }

            ForEach(day.readings) { reading in
                HStack(spacing: 10) {
                    Button {
                        model.toggleReading(
                            planID: plan.id,
                            day: day.day,
                            readingIndex: reading.id,
                            year: year
                        )
                    } label: {
                        Image(systemName: isCompleted(reading) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isCompleted(reading) ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isCompleted(reading) ? "Mark incomplete" : "Mark complete")

                    Button {
                        openReading(readingMode(activeReadingID: reading.id))
                    } label: {
                        Text(reading.displayDescription)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button("Open", systemImage: "arrow.right") {
                        openReading(readingMode(activeReadingID: reading.id))
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Open in Reader")

                    if let wordCount = wordCounts[reading.id] {
                        Text(ReadingTimeEstimator.description(
                            wordCount: wordCount,
                            wordsPerMinute: wordsPerMinute
                        ))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Estimated at \(wordsPerMinute) words per minute")
                    }

                    // Nothing to offer is the ordinary case: most readers
                    // have no other Bible app at all, and a button that opens
                    // an empty menu is worse than no button.
                    if !ExternalBibleApplication.openableOnThisMac.isEmpty {
                        Menu("Open in External Bible", systemImage: "arrow.up.right.square") {
                            if let preferredApplication {
                                Button("Open in \(preferredApplication.rawValue)") {
                                    openExternally(reading, using: preferredApplication)
                                }
                                Divider()
                            }
                            ForEach(ExternalBibleApplication.openableOnThisMac) { application in
                                Button(application.rawValue) {
                                    openExternally(reading, using: application)
                                }
                            }
                        }
                        .labelStyle(.iconOnly)
                        .menuStyle(.borderlessButton)
                        .help("Open in another Bible app")
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .task(id: wordCountRequest) { await loadWordCounts() }
    }

    private var completedCount: Int {
        day.readings.count(where: isCompleted)
    }

    private func isCompleted(_ reading: LampPlanReading) -> Bool {
        model.completedReadingIDs.contains(
            reading.completionID(planID: plan.id, day: day.day, year: year)
        )
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

    private var preferredApplication: ExternalBibleApplication? {
        // Checked against what this Mac can open, not just what was chosen:
        // a default saved while an app was installed outlives the app.
        ExternalBibleApplication(rawValue: externalBibleApp)
            .flatMap { ExternalBibleApplication.openableOnThisMac.contains($0) ? $0 : nil }
    }

    private var wordCountRequest: String {
        "\(model.selectedTranslationID ?? "none"):\(day.day):\(day.readings.map(\.id))"
    }

    private func loadWordCounts() async {
        guard let translationID = model.selectedTranslationID else {
            wordCounts = [:]
            return
        }
        var loaded: [Int: Int] = [:]
        for reading in day.readings {
            loaded[reading.id] = try? await model.library.translationWordCount(
                moduleID: translationID,
                startReference: reading.startReference,
                endReference: reading.endReference
            )
        }
        guard !Task.isCancelled else { return }
        wordCounts = loaded
    }

    private func openExternally(
        _ reading: LampPlanReading,
        using application: ExternalBibleApplication
    ) {
        guard let url = application.url(
            startReference: reading.startReference,
            endReference: reading.endReference
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
