#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI

/// The compact native calendar field used anywhere a day is selected.
struct CalendarDateField: View {
    let title: String
    @Binding var selection: Date
    @State private var showingCalendar = false

    var body: some View {
        HStack(spacing: 6) {
            DatePicker(title, selection: $selection, displayedComponents: .date)
                .datePickerStyle(.field)
                .labelsHidden()

            Button("Show Calendar", systemImage: "calendar") {
                showingCalendar = true
            }
            .labelStyle(.iconOnly)
            .help("Choose from calendar")
            .popover(isPresented: $showingCalendar, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Choose Date")
                        .font(.headline)
                    DatePicker(title, selection: $selection, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                }
                .padding()
            }

            Button("Today", systemImage: "calendar.badge.clock") {
                selection = Calendar.current.startOfDay(for: Date())
            }
            .labelStyle(.iconOnly)
            .disabled(Calendar.current.isDateInToday(selection))
            .help("Use today")
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// A calendar field for optional dates stored as portable devotional metadata.
struct StoredCalendarDateField: View {
    let title: String
    @Binding var storedValue: String

    private var trimmedValue: String {
        storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedDate: Date? {
        LampCalendarDate.date(from: trimmedValue)
    }

    private var selection: Binding<Date> {
        Binding(
            get: {
                parsedDate ?? Calendar.current.startOfDay(for: Date())
            },
            set: {
                storedValue = LampCalendarDate.storedString(from: $0)
            }
        )
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                if parsedDate != nil {
                    CalendarDateField(title: title, selection: selection)
                } else {
                    if !trimmedValue.isEmpty {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .help("Unrecognized date: \(storedValue)")
                    }
                    Button(
                        trimmedValue.isEmpty ? "Add Date" : "Choose Date",
                        systemImage: "calendar.badge.plus"
                    ) {
                        storedValue = LampCalendarDate.today()
                    }
                }

                if !trimmedValue.isEmpty {
                    Button("Remove Date", systemImage: "xmark.circle") {
                        storedValue = ""
                    }
                    .labelStyle(.iconOnly)
                    .help("Remove date")
                }
            }
        }
    }
}
