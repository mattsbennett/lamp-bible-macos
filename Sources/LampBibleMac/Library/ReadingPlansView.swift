import AppKit
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampCore
import SwiftUI

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

    /// Lamp's own plans and the reader's own, told apart by the module record
    /// each was installed from.
    private var groups: LampReadingPlanGrouping.Groups {
        LampReadingPlanGrouping.split(model.plans, installed: model.modules)
    }

    /// Both headings are always shown, and each says what its group is.
    ///
    /// "Built In" rather than "Included" because that is what the Modules
    /// list calls a module that came with Lamp — same thing, so the same
    /// word, and `shippingbox` is the mark it wears there.
    ///
    /// They were drawn only beside one another, which left the usual library
    /// — Lamp's three plans and nothing else — with no heading at all, and
    /// so nothing to say which of the plans on screen were the reader's own.
    /// That was the complaint. A heading that outranks the plan names it
    /// gathers, with a line saying what it gathers, is what tells them apart;
    /// the group being empty is itself worth seeing, since New Plan sits in
    /// it.
    private func groupHeading(
        _ title: String,
        _ systemImage: String,
        _ caption: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
            }
            .font(.title2.weight(.bold))
            Text(caption)
                .font(.callout)
                .foregroundStyle(Color.lampSecondaryText)
        }
        .padding(.top, 8)
        .accessibilityAddTraits(.isHeader)
    }

    /// The last thing under "Your Plans", so that making one reads as the way
    /// that group comes to have anything in it. The toolbar keeps its own New
    /// Plan button: on a Mac that is where a new-thing button belongs, and it
    /// is reachable from the Included half of the list too.
    private var newPlanRow: some View {
        Button { isMakingPlan = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Plan")
                        .font(.headline)
                    Text("Say what to read and how long for. Lamp works out the days.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lampCard()
    }

    private func cards(_ plans: [LampReadingPlan]) -> some View {
        ForEach(plans) { plan in
            ReadingPlanCard(
                plan: plan,
                date: date,
                openReading: openReading,
                openAllReadings: openAllReadings
            )
            .id(plan.id)
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
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Reading Plans")
                                    .font(.largeTitle.bold())
                                Text("Choose which plans appear in Today and preview the current assignments.")
                                    .font(.title3)
                                    .foregroundStyle(Color.lampSecondaryText)
                            }

                            AddedPlanNotice()

                            // Kept at the top level of the lazy stack rather
                            // than wrapped in a group, so the cards are still
                            // built as they are scrolled to.
                            groupHeading(
                                "Built In", "shippingbox", "Plans that come with Lamp."
                            )
                            cards(groups.included)
                            groupHeading(
                                "Your Plans", "person.circle", "Plans you've made or added."
                            )
                            cards(groups.yours)
                            newPlanRow
                        }
                        // Wider, and the intro tighter, so a plan's card and
                        // the next one's title both fit on the first screen.
                        .frame(maxWidth: 960, alignment: .leading)
                        .padding(.horizontal, 40)
                        .padding(.top, 24)
                        .padding(.bottom, 36)
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
/// Shown in Today too (TodayView.swift).
struct AddedPlanNotice: View {
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
    @State private var isConfirmingDelete = false
    let plan: LampReadingPlan
    let date: Date
    let openReading: (PlanReadingMode) -> Void
    let openAllReadings: (PlanReadingMode) -> Void

    private var dayNumber: Int { LampPlanCalendar.dayNumber(for: date) }
    private var year: Int { LampPlanCalendar.year(for: date) }

    /// The module this plan is removed through, or nil for one that came
    /// with Lamp — those stay.
    private var removableModule: LampInstalledModule? {
        LampReadingPlanGrouping.removableModule(for: plan, installed: model.modules)
    }

    /// In the card's menu and in its context menu both: the menu is the one
    /// that can be found, and the context menu is where a right-click looks.
    @ViewBuilder
    private var deletePlanButton: some View {
        if removableModule != nil {
            Button("Delete Plan…", systemImage: "trash", role: .destructive) {
                isConfirmingDelete = true
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plan.name)
                            .font(.title2.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        if let author = plan.author, !author.isEmpty {
                            Text(author).foregroundStyle(Color.lampSecondaryText)
                        }
                    }
                    Spacer(minLength: 12)
                    Toggle(
                        "Include in Today",
                        isOn: Binding(
                            get: { model.selectedPlanIDs.contains(plan.id) },
                            set: { model.setPlanSelected(plan.id, selected: $0) }
                        )
                    )
                    .toggleStyle(.switch)

                    if removableModule != nil {
                        Menu("More", systemImage: "ellipsis.circle") {
                            deletePlanButton
                        }
                        .labelStyle(.iconOnly)
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("More actions for this plan")
                    }
                }

                if let description = plan.description, !description.isEmpty {
                    // A reading measure, not the card's full width: the
                    // description ran the width of the window.
                    Text(description)
                        .lineSpacing(2)
                        .frame(maxWidth: 600, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 18) {
                    Label(plan.lengthDescription, systemImage: "calendar")
                    if let readingsPerDay = plan.readingsPerDay {
                        Label("\(readingsPerDay) readings per day", systemImage: "book.pages")
                    }
                }
                .font(.callout)
                .foregroundStyle(Color.lampSecondaryText)

                if let day {
                    Divider()
                        .padding(.top, 2)
                    PlanDayReadings(
                        plan: plan,
                        day: day,
                        year: year,
                        openReading: openReading,
                        openAllReadings: openAllReadings
                    )
                }

                if let fullDescription = plan.fullDescription, !fullDescription.isEmpty {
                    DisclosureGroup {
                        Text(fullDescription)
                            .lineSpacing(2)
                            .foregroundStyle(Color.lampProse)
                            .frame(maxWidth: 600, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.top, 8)
                    } label: {
                        Text("About This Plan")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Color.lampSecondaryText)
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lampCard(padding: 20)
        .contextMenu { deletePlanButton }
        .confirmationDialog(
            "Delete “\(plan.name)”?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            if let module = removableModule {
                // `LibraryModel.remove(_:)` records the removal through
                // LampSyncRemovedModules before it goes, which is what carries
                // the deletion to the other devices; core's own remove drops
                // the plan from the followed list and takes its completed
                // readings with it.
                Button("Delete Plan", role: .destructive) { model.remove(module) }
            }
        } message: {
            Text("The plan is deleted here and on any device you sync with.")
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // Where today falls in the plan, said in words beside the
                // day, so it cannot be mistaken for the ring, which counts
                // the readings done.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Day \(day.day)")
                        .font(.headline)
                    if let position = calendarPosition {
                        Text(position)
                            .font(.callout)
                            .foregroundStyle(Color.lampSecondaryText)
                            .monospacedDigit()
                    }
                }
                Spacer()
                // How far through today's readings, drawn as well as said: the
                // count alone gave the eye nothing to see at a glance.
                PlanDayProgressRing(
                    fraction: day.readings.isEmpty
                        ? 0 : Double(completedCount) / Double(day.readings.count)
                )
                Text("\(completedCount) of \(day.readings.count) read")
                    .font(.callout)
                    .foregroundStyle(Color.lampSecondaryText)
                    .monospacedDigit()
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
                    // Here and on each reading's context menu, rather than as
                    // a second small icon on every row beside its chevron,
                    // where the two read as one ambiguous cluster.
                    if !ExternalBibleApplication.openableOnThisMac.isEmpty {
                        Divider()
                        ForEach(ExternalBibleApplication.openableOnThisMac) { application in
                            Menu("Open in \(application.rawValue)") {
                                ForEach(day.readings) { reading in
                                    Button(reading.displayDescription) {
                                        openExternally(reading, using: application)
                                    }
                                }
                            }
                        }
                    }
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More plan actions")
            }

            VStack(spacing: 0) {
                ForEach(Array(day.readings.enumerated()), id: \.element.id) { index, reading in
                    if index > 0 {
                        Divider().padding(.leading, 40)
                    }
                    PlanReadingRow(
                        reading: reading,
                        isCompleted: isCompleted(reading),
                        readingTime: wordCounts[reading.id].map {
                            ReadingTimeEstimator.description(
                                wordCount: $0,
                                wordsPerMinute: wordsPerMinute
                            )
                        },
                        wordsPerMinute: wordsPerMinute,
                        preferredApplication: preferredApplication,
                        toggle: {
                            model.toggleReading(
                                planID: plan.id,
                                day: day.day,
                                readingIndex: reading.id,
                                year: year
                            )
                        },
                        open: { openReading(readingMode(activeReadingID: reading.id)) },
                        openExternally: { openExternally(reading, using: $0) }
                    )
                }
            }
        }
        .task(id: wordCountRequest) { await loadWordCounts() }
    }

    /// "85% through the year" for a year plan; "of 22" for a shorter one.
    private var calendarPosition: String? {
        guard plan.duration > 1, day.day <= plan.duration else { return nil }
        // A year plan keeps a slot for 29 February, so its length is 366; a
        // share of the year says the useful thing without that arithmetic.
        if plan.duration >= 365 {
            let percent = Int((Double(day.day) / Double(plan.duration) * 100).rounded())
            return "· \(percent)% through the year"
        }
        return "of \(plan.duration)"
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

/// One reading in a day: its checkbox, its passage and how long it takes,
/// and a chevron to open it. Another Bible app is offered from the row's
/// context menu and the day's More menu.
///
/// The time sits beside the passage rather than at the far edge of the card,
/// where it had drifted away from the reading it belonged to among a cluster
/// of small controls. The whole row opens the reading, and says so on hover.
private struct PlanReadingRow: View {
    let reading: LampPlanReading
    let isCompleted: Bool
    let readingTime: String?
    let wordsPerMinute: Int
    let preferredApplication: ExternalBibleApplication?
    let toggle: () -> Void
    let open: () -> Void
    let openExternally: (ExternalBibleApplication) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(isCompleted ? Color.accentColor : Color.lampSecondaryText)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(isCompleted ? "Mark incomplete" : "Mark complete")
            .accessibilityLabel(isCompleted ? "Mark \(reading.displayDescription) incomplete" : "Mark \(reading.displayDescription) complete")

            Button(action: open) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(reading.displayDescription)
                        .font(.system(size: 14.5))
                        .foregroundStyle(isCompleted ? .secondary : .primary)
                    if let readingTime {
                        Text(readingTime)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(Color.lampSecondaryText)
                            .help("Estimated at \(wordsPerMinute) words per minute")
                    }
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Shown with the row's hover: the whole row opens the reading, and
            // a chevron on every row at rest, beside the day's Open button,
            // blurred what was clickable.
            Button("Open", systemImage: "chevron.right", action: open)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(Color.lampSecondaryText)
                .fontWeight(.semibold)
                .help("Open in Reader")
                .opacity(isHovering ? 1 : 0)
        }
        .contextMenu {
            Button("Open in Reader", systemImage: "book", action: open)
            Button(isCompleted ? "Mark Incomplete" : "Mark Complete", action: toggle)
            // Nothing to offer is the ordinary case: most readers have no
            // other Bible app at all.
            if !ExternalBibleApplication.openableOnThisMac.isEmpty {
                Divider()
                if let preferredApplication {
                    Button("Open in \(preferredApplication.rawValue)") {
                        openExternally(preferredApplication)
                    }
                    Divider()
                }
                ForEach(ExternalBibleApplication.openableOnThisMac) { application in
                    Button("Open in \(application.rawValue)") {
                        openExternally(application)
                    }
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 8)
        .background(
            isHovering ? Color.lampTileFill : .clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .padding(.horizontal, -8)
        .onHover { isHovering = $0 }
    }
}

/// A small ring that fills as the day's readings are ticked off.
private struct PlanDayProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            // An accent track, faint, so the ring reads as progress waiting to
            // fill rather than as a control that is switched off.
            Circle()
                .stroke(Color.accentColor.opacity(0.22), lineWidth: 3.5)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
        .animation(.easeOut(duration: 0.25), value: fraction)
        .accessibilityHidden(true)
    }
}
