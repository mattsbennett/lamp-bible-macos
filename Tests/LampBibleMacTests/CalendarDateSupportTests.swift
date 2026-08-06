import Foundation
import Testing
@testable import LampBibleMacSupport

struct CalendarDateSupportTests {
    @Test func roundTripsCalendarDaysWithoutUTCDateShifts() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Vancouver"))
        let localDate = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: 3,
            hour: 23
        )))

        let stored = LampCalendarDate.storedString(from: localDate, calendar: calendar)
        #expect(stored == "2026-08-03")

        let restored = try #require(LampCalendarDate.date(from: stored, calendar: calendar))
        let restoredComponents = calendar.dateComponents([.year, .month, .day], from: restored)
        #expect(restoredComponents.year == 2026)
        #expect(restoredComponents.month == 8)
        #expect(restoredComponents.day == 3)
    }

    @Test func rejectsMalformedAndImpossibleCalendarDays() {
        #expect(LampCalendarDate.date(from: "2026-8-03") == nil)
        #expect(LampCalendarDate.date(from: "2025-02-29") == nil)
        #expect(LampCalendarDate.date(from: "not a date") == nil)
    }
}
