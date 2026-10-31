#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampCore
#if canImport(FoundationModels)
import LampIntelligence
#endif
import SwiftUI

/// Making a reading plan to order: what to read, how fast, and from when.
///
/// The form works on every Mac Lamp runs on. Where Apple Intelligence can be
/// asked, a description fills the form in — and only fills it in. The model
/// names books, a length, a pace, a start and rest days; core lays out the
/// days; and the dates and readings are on screen before anything is added,
/// because a model can still misread what was asked for.
struct NewReadingPlanSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    @State private var form = LampReadingPlanForm()
    /// The plan as core lays it out, worked out again whenever the form moves.
    @State private var draft: LampReadingPlanDraft?
    /// Why the form as it stands cannot be laid out, in core's own words.
    @State private var problem: String?
    @State private var words = ""
    @State private var isAsking = false
    @State private var assistantProblem: String?
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Reading Plan")
                    .font(.title2.bold())
                Text("Lamp works out the days. Say what to read, how long for, and when to start.")
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            HStack(spacing: 0) {
                fields
                    .frame(minWidth: 400, idealWidth: 430)
                Divider()
                preview
                    .frame(minWidth: 330, idealWidth: 390)
            }

            Divider()

            HStack {
                if isAdding { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Plan", action: add)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft == nil || isAdding)
            }
            .padding(20)
        }
        // A definite size rather than an ideal one: the form is a scroll view
        // with no height of its own to offer, so a sheet asked for its ideal
        // size came out at the minimum and cut the form off below "What to
        // Read". This fits inside the app's own smallest window.
        .frame(width: 880, height: 720)
        // Laid out again on every change, so the days on the right are always
        // the days the form on the left describes.
        .task(id: form) { layOutThePlan() }
    }

    // MARK: - The form

    private var fields: some View {
        Form {
            if let assistantUnavailableReason {
                Section("Describe Your Plan") {
                    Label(assistantUnavailableReason, systemImage: "sparkles")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Section("Describe Your Plan") {
                    TextField(
                        "Description",
                        text: $words,
                        prompt: Text("the Gospels in a month, weekdays only")
                    )
                    .labelsHidden()
                    .lineLimit(2)
                    .onSubmit(askTheModel)
                    HStack {
                        Button("Fill In the Form", systemImage: "sparkles", action: askTheModel)
                            .disabled(
                                words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || isAsking
                            )
                        if isAsking { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    if let assistantProblem {
                        Label(assistantProblem, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Apple Intelligence fills in the form on this Mac. Look it over before you add the plan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("The Plan") {
                TextField("Name", text: $form.name, prompt: Text("The Gospels in a Month"))
                TextField(
                    "Description",
                    text: $form.planDescription,
                    prompt: Text("Matthew to John, a few chapters a day")
                )
            }

            ForEach($form.tracks) { $track in
                trackSection($track)
            }

            Section("How Long") {
                Picker("Length", selection: $form.length) {
                    ForEach(LampReadingPlanForm.Length.allCases) { length in
                        Text(length.title).tag(length)
                    }
                }
                if form.length == .days {
                    Stepper(
                        "Reading days: \(form.readingDays)",
                        value: $form.readingDays,
                        in: 1...366
                    )
                } else {
                    Text("As long as the chapters a day take. Give at least one reading a pace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DatePicker("Starts", selection: $form.start, displayedComponents: .date)
            }

            Section("Days Off") {
                HStack(spacing: 4) {
                    ForEach(LampWeekday.inWeekOrder, id: \.self) { day in
                        Toggle(day.shortTitle, isOn: restDay(day))
                            .toggleStyle(.button)
                            .help("No reading on \(day.title)s")
                    }
                }
                Text("The plan runs on past its days off, so it still has all of its reading days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func trackSection(_ track: Binding<LampReadingPlanForm.Track>) -> some View {
        let title: String = form.tracks.count > 1
            ? "Reading \(number(of: track.wrappedValue))"
            : "What to Read"
        return Section(title) {
            TextField(
                "Passages",
                text: track.passages,
                prompt: Text("Matthew–John"),
                axis: .vertical
            )
            .lineLimit(1...4)
            Text("One run of scripture per line: Matthew–John, Psalms 1–41, NT, Romans 8.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Stepper(
                track.wrappedValue.chaptersPerDay == 0
                    ? "Pace: spread over the plan"
                    : "Pace: \(track.wrappedValue.chaptersPerDay) chapters a day",
                value: track.chaptersPerDay,
                in: 0...20
            )
            if form.tracks.count > 1 {
                Button("Remove This Reading", systemImage: "minus") {
                    form.tracks.removeAll { $0.id == track.wrappedValue.id }
                }
            }
            // In the last reading's own section rather than one of its own:
            // a section to hold one button costs the height that "How Long"
            // needs to be on screen beside the days it decides.
            if track.wrappedValue.id == form.tracks.last?.id {
                Button("Add Another Reading", systemImage: "plus") {
                    form.tracks.append(LampReadingPlanForm.Track())
                }
                .help("Readings run side by side: every day of the plan has a portion of each")
            }
        }
    }

    private func number(of track: LampReadingPlanForm.Track) -> Int {
        (form.tracks.firstIndex { $0.id == track.id } ?? 0) + 1
    }

    private func restDay(_ day: LampWeekday) -> Binding<Bool> {
        Binding(
            get: { form.restDays.contains(day) },
            set: { isResting in
                if isResting {
                    form.restDays.insert(day)
                } else {
                    form.restDays.remove(day)
                }
            }
        )
    }

    // MARK: - The days, before anything is added

    @ViewBuilder
    private var preview: some View {
        if let draft {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.plan.name)
                        .font(.headline)
                    Text(lengthDescription(draft))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(draft.days, id: \.number) { day in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(dayTitle(day))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(day.readings) { reading in
                                    Text(reading.displayDescription)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(16)
                }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: form.isBlank ? "calendar" : "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(problem ?? "Fill in the form to see the plan's days.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func lengthDescription(_ draft: LampReadingPlanDraft) -> String {
        let days = "\(draft.plan.duration) reading day\(draft.plan.duration == 1 ? "" : "s")"
        guard let perDay = draft.plan.readingsPerDay, perDay > 1 else { return days }
        return "\(days) · \(perDay) readings a day"
    }

    private func dayTitle(_ day: LampReadingPlanDraft.Day) -> String {
        let date = day.date.formatted(
            .dateTime.weekday(.abbreviated).day().month(.abbreviated)
        )
        return "\(date) · Day \(day.number)"
    }

    // MARK: - Doing it

    /// Lays the form out, or keeps the reason it cannot be.
    ///
    /// Core's errors are written to be shown as they are, so nothing is worded
    /// again here. A blank form is not an error and says nothing.
    private func layOutThePlan() {
        guard !form.isBlank else {
            draft = nil
            problem = nil
            return
        }
        do {
            draft = try form.draft()
            problem = nil
        } catch {
            draft = nil
            problem = error.localizedDescription
        }
    }

    /// Why the on-device model cannot be asked here, in words to show, or nil
    /// when it can be.
    ///
    /// Apple Intelligence's language model arrived in macOS 26, so on anything
    /// earlier there is nothing to ask and the form stands alone.
    private var assistantUnavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return LampReadingPlanAssistant.unavailableReason
        }
        #endif
        return """
            Making a plan from a description needs Apple Intelligence, on \
            macOS 26 or later. The form works on any Mac.
            """
    }

    private func askTheModel() {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return }
        let asked = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, !isAsking else { return }
        isAsking = true
        assistantProblem = nil
        Task {
            do {
                form = LampReadingPlanForm.filled(
                    from: try await LampReadingPlanAssistant().request(for: asked)
                )
            } catch is CancellationError {
                // The sheet closed under it. Nobody is waiting to be told.
            } catch {
                // Core words these to be shown as they are, because the
                // model's own errors name its internals.
                assistantProblem = error.localizedDescription
            }
            isAsking = false
        }
        #endif
    }

    private func add() {
        guard let draft, !isAdding else { return }
        isAdding = true
        Task {
            do {
                try await model.addReadingPlan(draft)
                dismiss()
            } catch {
                problem = error.localizedDescription
                isAdding = false
            }
        }
    }
}
