import Testing
import Foundation
@testable import MootGateway

// MARK: - ReviewSchedule tests  (FAB5-G1 Part 1)
//
// Every case runs on a fixed UTC calendar. A schedule test that used
// `Calendar.current` would pass or fail depending on the machine's timezone.

@Suite("ReviewSchedule — windows and next-run instants (FAB5-G1)")
struct ReviewScheduleTests {

    static let schedule = ReviewSchedule(calendar: ReviewSchedule.utcCalendar)

    /// 2026-07-13T15:33:20Z — a Monday afternoon.
    static let now = Date(timeIntervalSince1970: 1_783_956_800)

    static func iso(_ date: Date) -> String { ReviewSchedule.iso8601(date) }

    @Test("dashboard window is unbounded and ends at now")
    func dashboardWindow() {
        let window = Self.schedule.window(for: .dashboard, now: Self.now)
        #expect(window.start == .distantPast)
        #expect(window.end == Self.now)
        #expect(window.contains(Self.now))
        #expect(window.contains(Date(timeIntervalSince1970: 0)))
        #expect(!window.contains(Self.now.addingTimeInterval(1)))
    }

    @Test("morning window opens at the start of yesterday")
    func morningWindow() {
        let window = Self.schedule.window(for: .morning, now: Self.now)
        #expect(Self.iso(window.start) == "2026-07-12T00:00:00Z")
        #expect(window.end == Self.now)
    }

    @Test("end-of-day window opens at the start of today")
    func endOfDayWindow() {
        let window = Self.schedule.window(for: .endOfDay, now: Self.now)
        #expect(Self.iso(window.start) == "2026-07-13T00:00:00Z")
        #expect(window.end == Self.now)
    }

    @Test("weekly window looks back seven calendar days, preserving time of day")
    func weeklyWindow() {
        let window = Self.schedule.window(for: .weekly, now: Self.now)
        #expect(Self.iso(window.start) == "2026-07-06T15:33:20Z")
        #expect(window.end == Self.now)
    }

    @Test("the drift split instant is the window start")
    func splitInstant() {
        let window = Self.schedule.window(for: .weekly, now: Self.now)
        #expect(Self.schedule.splitInstant(for: window) == window.start)
    }

    @Test("next morning is today when the hour has not passed")
    func nextMorningLaterToday() {
        // 2026-07-13T04:00:00Z — before the 07:00 morning hour.
        let earlyMorning = Date(timeIntervalSince1970: 1_783_915_200)
        #expect(Self.iso(earlyMorning) == "2026-07-13T04:00:00Z")
        #expect(Self.iso(Self.schedule.nextMorning(after: earlyMorning))
                == "2026-07-13T07:00:00Z")
    }

    @Test("next morning rolls to tomorrow once the hour has passed")
    func nextMorningTomorrow() {
        #expect(Self.iso(Self.schedule.nextMorning(after: Self.now))
                == "2026-07-14T07:00:00Z")
    }

    @Test("next end-of-day is later today when the hour has not passed")
    func nextEndOfDayLaterToday() {
        #expect(Self.iso(Self.schedule.nextEndOfDay(after: Self.now))
                == "2026-07-13T18:00:00Z")
    }

    @Test("the next occurrence is strictly after the given instant")
    func nextOccurrenceIsStrict() {
        // Exactly 07:00:00 — a scheduler that fired now and re-asked must get
        // tomorrow, not the instant it is standing on.
        let atSevenAM = Date(timeIntervalSince1970: 1_783_926_000)
        #expect(Self.iso(atSevenAM) == "2026-07-13T07:00:00Z")
        #expect(Self.iso(Self.schedule.nextMorning(after: atSevenAM))
                == "2026-07-14T07:00:00Z")
    }

    @Test("custom review hours are honoured")
    func customHours() {
        let custom = ReviewSchedule(
            morningHour: 5, endOfDayHour: 22, calendar: ReviewSchedule.utcCalendar)
        #expect(Self.iso(custom.nextMorning(after: Self.now)) == "2026-07-14T05:00:00Z")
        #expect(Self.iso(custom.nextEndOfDay(after: Self.now)) == "2026-07-13T22:00:00Z")
    }

    @Test("window bounds are inclusive on both ends")
    func windowContainsBoundaries() {
        let window = ReviewWindow(start: Self.now, end: Self.now.addingTimeInterval(60))
        #expect(window.contains(window.start))
        #expect(window.contains(window.end))
        #expect(!window.contains(window.start.addingTimeInterval(-1)))
        #expect(!window.contains(window.end.addingTimeInterval(1)))
        #expect(window.duration == 60)
    }

    @Test("ISO8601 rendering matches what the lens boundary parses")
    func iso8601Rendering() {
        // LensTools.requireDate uses a plain ISO8601DateFormatter
        // (.withInternetDateTime): no fractional seconds, trailing Z.
        let rendered = ReviewSchedule.iso8601(Self.now)
        #expect(rendered == "2026-07-13T15:33:20Z")
        #expect(ISO8601DateFormatter().date(from: rendered) == Self.now)
    }

    @Test("the UTC calendar helper really is UTC")
    func utcCalendar() {
        #expect(ReviewSchedule.utcCalendar.timeZone.secondsFromGMT() == 0)
    }

    @Test("window round-trips through the report coders")
    func windowRoundTrip() throws {
        let window = Self.schedule.window(for: .weekly, now: Self.now)
        let data = try ReviewReport.makeEncoder().encode(window)
        let decoded = try ReviewReport.makeDecoder().decode(ReviewWindow.self, from: data)
        #expect(decoded == window)
    }
}
