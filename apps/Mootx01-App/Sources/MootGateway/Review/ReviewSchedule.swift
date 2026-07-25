import Foundation

// MARK: - ReviewSchedule  (FAB5-G1 — the time arithmetic behind the four reviews)
//
// Windows and next-run instants for the Review Center, and nothing else. Kept
// out of the builders so the window math is testable on its own and so FAB5-H2's
// review-prep worker can ask "when is the next end-of-day review due?" without
// building a report.
//
// Determinism: every function takes `now` as a parameter. Nothing in this file
// reads the clock — same rule the substrate engines follow. The calendar is
// injected too, because "start of day" and "seven days ago" are calendar-
// and timezone-dependent, and a test that depends on the machine's timezone is
// a flake waiting to happen.

// MARK: - ReviewWindow

/// The closed span a review covers, `start...end`.
public struct ReviewWindow: Codable, Sendable, Equatable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    /// The whole estate up to `end` — what the dashboard reads. `Date.distantPast`
    /// rather than an optional start so consumers never branch on nil, and so
    /// `contains` works uniformly for every kind of review.
    public static func unbounded(endingAt end: Date) -> ReviewWindow {
        ReviewWindow(start: .distantPast, end: end)
    }

    /// Inclusive on both ends: an item filed exactly at a boundary belongs to the
    /// window. Adjacent windows (yesterday's end-of-day, today's morning) can
    /// therefore both claim a boundary item — deliberate, since a review is a
    /// reading surface, not a partition of the estate.
    public func contains(_ date: Date) -> Bool {
        date >= start && date <= end
    }

    /// Span in seconds. `Date.distantPast`-anchored windows return a huge but
    /// finite value; callers that care use `kind == .dashboard` instead.
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

// MARK: - ReviewSchedule

/// Computes each review's window, and when the next morning / end-of-day review
/// falls due.
public struct ReviewSchedule: Sendable {

    /// Local hour the morning review is due. 07:00 — early enough to be waiting
    /// when the day starts, late enough that "yesterday" is over.
    public static let defaultMorningHour = 7
    /// Local hour the end-of-day review is due. 18:00 — end of a working day,
    /// while the day's context is still recoverable.
    public static let defaultEndOfDayHour = 18
    /// Days the weekly review looks back over.
    public static let weeklyLookbackDays = 7

    public let morningHour: Int
    public let endOfDayHour: Int
    public let calendar: Calendar

    /// - Parameters:
    ///   - morningHour: local hour (0–23) the morning review is due.
    ///   - endOfDayHour: local hour (0–23) the end-of-day review is due.
    ///   - calendar: the calendar and timezone all day arithmetic runs in.
    ///     Defaults to `.current`; tests inject a fixed-UTC calendar.
    public init(
        morningHour: Int = ReviewSchedule.defaultMorningHour,
        endOfDayHour: Int = ReviewSchedule.defaultEndOfDayHour,
        calendar: Calendar = .current
    ) {
        self.morningHour = morningHour
        self.endOfDayHour = endOfDayHour
        self.calendar = calendar
    }

    /// A UTC calendar — the deterministic choice for tests and for any caller
    /// that must produce the same windows regardless of machine timezone.
    public static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // Force-unwrap is safe: "UTC" is a guaranteed-present identifier in the
        // ICU timezone database on every Apple platform.
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: Windows

    /// The span a review of `kind` covers, ending at `now`.
    ///
    /// - dashboard: unbounded — the estate as it stands.
    /// - morning: from the start of YESTERDAY. A morning review is read before
    ///   today has produced much, so its useful context is yesterday's work plus
    ///   whatever has landed since midnight.
    /// - endOfDay: from the start of today — strictly what this day changed.
    /// - weekly: the trailing seven days.
    public func window(for kind: ReviewKind, now: Date) -> ReviewWindow {
        switch kind {
        case .dashboard:
            return .unbounded(endingAt: now)
        case .morning:
            return ReviewWindow(start: startOfDay(offsetByDays: -1, from: now), end: now)
        case .endOfDay:
            return ReviewWindow(start: startOfDay(offsetByDays: 0, from: now), end: now)
        case .weekly:
            return ReviewWindow(
                start: shifted(now, byDays: -Self.weeklyLookbackDays),
                end: now)
        }
    }

    /// The instant `moot_lens_drift` splits its before/after distributions at.
    /// The window start: "how has the estate's shape changed since this window
    /// opened?" For the unbounded dashboard window there is no meaningful split,
    /// so the dashboard's builder does not call the drift lens.
    public func splitInstant(for window: ReviewWindow) -> Date { window.start }

    // MARK: Next-run instants

    /// The next time a morning review falls due, strictly after `after`.
    public func nextMorning(after date: Date) -> Date {
        nextOccurrence(ofHour: morningHour, after: date)
    }

    /// The next time an end-of-day review falls due, strictly after `after`.
    public func nextEndOfDay(after date: Date) -> Date {
        nextOccurrence(ofHour: endOfDayHour, after: date)
    }

    /// Next instant at `hour`:00:00 local, strictly later than `date`. "Strictly"
    /// matters: called at exactly 07:00:00 the answer is tomorrow, so a scheduler
    /// that fires and immediately re-asks cannot loop on the same instant.
    private func nextOccurrence(ofHour hour: Int, after date: Date) -> Date {
        let today = startOfDay(offsetByDays: 0, from: date)
        // Force-unwrap is safe: adding whole hours to a start-of-day instant is
        // always representable in the Gregorian calendar.
        let todayAtHour = calendar.date(byAdding: .hour, value: hour, to: today)!
        if todayAtHour > date { return todayAtHour }
        let tomorrow = startOfDay(offsetByDays: 1, from: date)
        return calendar.date(byAdding: .hour, value: hour, to: tomorrow)!
    }

    // MARK: Day arithmetic

    /// Midnight of the day `offsetByDays` from `date`, in the injected calendar.
    private func startOfDay(offsetByDays offset: Int, from date: Date) -> Date {
        let base = calendar.startOfDay(for: date)
        guard offset != 0 else { return base }
        // Force-unwrap is safe: whole-day offsets from a valid start-of-day are
        // always representable. Calendar day arithmetic (not 86_400-second
        // multiples) so DST transitions land on real midnights.
        return calendar.date(byAdding: .day, value: offset, to: base)!
    }

    /// `date` shifted by whole calendar days, preserving time of day.
    private func shifted(_ date: Date, byDays days: Int) -> Date {
        calendar.date(byAdding: .day, value: days, to: date)!
    }

    // MARK: Wire formatting

    /// ISO8601 rendering for lens arguments that take an instant (`splitAt`).
    /// Plain `ISO8601DateFormatter()` — `.withInternetDateTime`, no fractional
    /// seconds — which is exactly what the lens boundary parses with
    /// (`LensTools.requireDate`). A fractional-seconds variant would be rejected.
    public static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
