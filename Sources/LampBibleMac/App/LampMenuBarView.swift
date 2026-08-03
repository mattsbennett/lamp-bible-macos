import LampCore
import SwiftUI

struct LampMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: LibraryModel
    @State private var days: [(LampReadingPlan, LampReadingPlanDay)] = []
    @State private var isLoading = false

    private var dayNumber: Int { LampPlanCalendar.dayNumber(for: Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lamp Bible").font(.headline)
                    Text(Date().formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Lamp Bible", systemImage: "arrow.up.forward.app") {
                    openWindow(id: "reader")
                }
                .labelStyle(.iconOnly)
            }

            Divider()
            if isLoading {
                ProgressView("Loading readings…")
            } else if days.isEmpty {
                Text("No reading-plan assignments for today.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(days, id: \.0.id) { plan, day in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(plan.name).font(.subheadline.weight(.semibold))
                        ForEach(day.readings) { reading in
                            Button(reading.displayDescription) {
                                model.openReading(reading)
                                openWindow(id: "reader")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 330)
        .task(id: "\(dayNumber):\(model.selectedPlanIDs.sorted())") { await load() }
    }

    private func load() async {
        model.start()
        isLoading = true
        var loaded: [(LampReadingPlan, LampReadingPlanDay)] = []
        for plan in model.plans where model.selectedPlanIDs.contains(plan.id) {
            if let day = try? await model.library.readingPlanDay(moduleID: plan.id, day: dayNumber) {
                loaded.append((plan, day))
            }
        }
        guard !Task.isCancelled else { return }
        days = loaded
        isLoading = false
    }
}
