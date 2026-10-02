import Foundation
import Testing
@testable import GitokenCore

@Suite struct QuietPolicyTests {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        return c
    }()

    func at(_ hour: Int, _ minute: Int, day: Int = 2) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func wrappingQuietHoursCoverLateNightAndEarlyMorning() {
        let q = QuietHours(enabled: true, start: .init(hour: 22, minute: 0), end: .init(hour: 8, minute: 0))
        #expect(q.contains(at(22, 0), calendar: calendar))
        #expect(q.contains(at(3, 30), calendar: calendar))
        #expect(!q.contains(at(8, 0), calendar: calendar))
        #expect(!q.contains(at(21, 59), calendar: calendar))
    }

    @Test func equalStartAndEndNeverSilences() {
        let q = QuietHours(enabled: true, start: .init(hour: 9, minute: 0), end: .init(hour: 9, minute: 0))
        #expect(!q.contains(at(9, 0), calendar: calendar))
    }

    @Test func globalSnoozeTakesPrecedenceThenManualThenHours() {
        let q = QuietHours(enabled: true, start: .init(hour: 22, minute: 0), end: .init(hour: 8, minute: 0))
        let now = at(23, 0)
        let until = now.addingTimeInterval(600)
        #expect(QuietPolicy.reason(now: now, globalSnoozeUntil: until, manualQuiet: true, quietHours: q, calendar: calendar)
            == .globalSnooze(until: until))
        #expect(QuietPolicy.reason(now: now, globalSnoozeUntil: now.addingTimeInterval(-1), manualQuiet: true, quietHours: q, calendar: calendar)
            == .manual)
        #expect(QuietPolicy.reason(now: now, globalSnoozeUntil: nil, manualQuiet: false, quietHours: q, calendar: calendar)
            == .quietHours(until: .init(hour: 8, minute: 0)))
        #expect(QuietPolicy.reason(now: at(12, 0), globalSnoozeUntil: nil, manualQuiet: false, quietHours: q, calendar: calendar) == nil)
    }

    @Test func untilTomorrowIsNineAMNextDayEvenJustBeforeMidnight() {
        let deadline = SnoozeOption.untilTomorrow.deadline(from: at(23, 50), calendar: calendar)
        #expect(deadline == at(9, 0, day: 3))
    }
}
