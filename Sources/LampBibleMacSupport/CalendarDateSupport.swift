import Foundation

/// Converts calendar days to and from the portable `yyyy-MM-dd` value stored in
/// devotional metadata. Components are interpreted in the supplied calendar so
/// a date never moves backward or forward when the user's time zone is not UTC.
public enum LampCalendarDate {
    public static func date(
        from storedValue: String,
        calendar: Calendar = .current
    ) -> Date? {
        let value = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day

        guard let date = calendar.date(from: components) else { return nil }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year,
              resolved.month == month,
              resolved.day == day else { return nil }
        return date
    }

    public static func storedString(
        from date: Date,
        calendar: Calendar = .current
    ) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    public static func today(calendar: Calendar = .current) -> String {
        storedString(from: Date(), calendar: calendar)
    }
}
