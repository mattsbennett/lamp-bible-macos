import LampCore
import SwiftUI

private struct PlanDayRequest: Hashable {
    let day: Int
    let year: Int
    let planIDs: [String]
}

struct TodayPlansView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var date = Date()
    @State private var daysByPlanID: [String: LampReadingPlanDay] = [:]
    @State private var isLoading = false

    let showImporter: () -> Void
    let showPlans: () -> Void
    let openReading: (LampPlanReading) -> Void

    private var dayNumber: Int {
        LampPlanCalendar.dayNumber(for: date)
    }

    private var year: Int {
        Calendar.current.component(.year, from: date)
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
                    Text("Install a plan .lamp module, or build one in Module Studio.")
                } actions: {
                    Button("Install Module…", action: showImporter)
                        .buttonStyle(.borderedProminent)
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

                        ForEach(selectedPlans) { plan in
                            if let day = daysByPlanID[plan.id] {
                                PlanDayCard(
                                    plan: plan,
                                    day: day,
                                    year: year,
                                    openReading: openReading
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
                Button("Today", systemImage: "calendar.badge.clock") {
                    date = Date()
                }
                .disabled(Calendar.current.isDateInToday(date))

                DatePicker("Reading Date", selection: $date, displayedComponents: .date)
                    .labelsHidden()
            }
        }
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
    let showImporter: () -> Void
    let openReading: (LampPlanReading) -> Void

    private let date = Date()

    var body: some View {
        Group {
            if model.plans.isEmpty {
                ContentUnavailableView {
                    Label("No Reading Plans Installed", systemImage: "calendar.badge.plus")
                } description: {
                    Text("Plan JSON can be compiled in Module Studio and installed as a portable .lamp module.")
                } actions: {
                    Button("Install Module…", action: showImporter)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Reading Plans")
                                .font(.largeTitle.bold())
                            Text("Choose which plans appear in Today and preview the current assignments.")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 8)

                        ForEach(model.plans) { plan in
                            ReadingPlanCard(plan: plan, date: date, openReading: openReading)
                        }
                    }
                    .frame(maxWidth: 880, alignment: .leading)
                    .padding(36)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Reading Plans")
        .task {
            await model.loadPlanProgress(year: Calendar.current.component(.year, from: date))
        }
    }
}

private struct ReadingPlanCard: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var day: LampReadingPlanDay?
    let plan: LampReadingPlan
    let date: Date
    let openReading: (LampPlanReading) -> Void

    private var dayNumber: Int { LampPlanCalendar.dayNumber(for: date) }
    private var year: Int { Calendar.current.component(.year, from: date) }

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
                        planID: plan.id,
                        day: day,
                        year: year,
                        openReading: openReading
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
    let openReading: (LampPlanReading) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                if let description = plan.description, !description.isEmpty {
                    Text(description)
                        .foregroundStyle(.secondary)
                }
                PlanDayReadings(
                    planID: plan.id,
                    day: day,
                    year: year,
                    openReading: openReading
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
    let planID: String
    let day: LampReadingPlanDay
    let year: Int
    let openReading: (LampPlanReading) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Day \(day.day)")
                    .font(.headline)
                Spacer()
                Text("\(completedCount) of \(day.readings.count) complete")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(day.readings) { reading in
                HStack(spacing: 10) {
                    Button {
                        model.toggleReading(
                            planID: planID,
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
                        openReading(reading)
                    } label: {
                        Text(reading.displayDescription)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button("Open", systemImage: "arrow.right") {
                        openReading(reading)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Open in Reader")
                }
                .padding(.vertical, 3)
            }
        }
    }

    private var completedCount: Int {
        day.readings.count(where: isCompleted)
    }

    private func isCompleted(_ reading: LampPlanReading) -> Bool {
        model.completedReadingIDs.contains(
            reading.completionID(planID: planID, day: day.day, year: year)
        )
    }
}
