import Foundation

// QueryDateWindow — deterministic absolute-date-expression parsing for the
// temporal_recall recipe (decision record
// DECISION_SEARCH_STRATEGY_RECIPES_2026-08-19, item 4).
//
// The recall lanes measure content similarity and currency; none of them
// reads a date stated in the QUERY ("in July", "on 8 May 2023") and matches
// it against drawer event_time. This module supplies that reading: it parses
// explicit absolute date expressions out of a query string and returns the
// UTC windows they name. Version 1 is absolute-only by design ruling —
// relative expressions ("last week") need a reference clock and are a
// separate, later surface.
//
// Determinism: pure string→window computation. No Date(), no Calendar
// locale, no current time anywhere — the same query yields the same windows
// on every machine forever. Month-only expressions cannot know a year, so
// they return one window PER YEAR in a caller-supplied plausible range; the
// recipe intersects those with the estate's actual event-time span.

/// One inclusive UTC window an absolute date expression names.
public struct QueryDateWindow: Sendable, Equatable {
    /// Inclusive window start, "YYYY-MM-DDT00:00:00Z" form.
    public let start: String
    /// Inclusive window end, "YYYY-MM-DDT23:59:59Z" form.
    public let end: String
    /// The query substring the window was parsed from (diagnostic).
    public let matchedText: String

    public init(start: String, end: String, matchedText: String) {
        self.start = start
        self.end = end
        self.matchedText = matchedText
    }
}

/// The result of parsing a query for absolute date expressions.
public enum QueryDateParse: Sendable, Equatable {
    /// No absolute date expression found.
    case none
    /// Fully-anchored windows (year known).
    case anchored([QueryDateWindow])
    /// Month-only expression: the month is known, the year is not.
    /// The recipe expands this against the estate's own year span.
    case monthOnly(month: Int, matchedText: String)
}

private let queryMonthNames: [String: Int] = [
    "january": 1, "february": 2, "march": 3, "april": 4, "may": 5,
    "june": 6, "july": 7, "august": 8, "september": 9, "october": 10,
    "november": 11, "december": 12,
]

/// Day counts per month; February resolved with the standard leap rule.
private func daysIn(month: Int, year: Int) -> Int {
    switch month {
    case 1, 3, 5, 7, 8, 10, 12: return 31
    case 4, 6, 9, 11: return 30
    default:
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        return leap ? 29 : 28
    }
}

private func dayWindow(_ y: Int, _ m: Int, _ d: Int, _ text: String) -> QueryDateWindow {
    QueryDateWindow(
        start: String(format: "%04d-%02d-%02dT00:00:00Z", y, m, d),
        end: String(format: "%04d-%02d-%02dT23:59:59Z", y, m, d),
        matchedText: text)
}

private func monthWindow(_ y: Int, _ m: Int, _ text: String) -> QueryDateWindow {
    QueryDateWindow(
        start: String(format: "%04d-%02d-01T00:00:00Z", y, m),
        end: String(format: "%04d-%02d-%02dT23:59:59Z", y, m, daysIn(month: m, year: y)),
        matchedText: text)
}

private func yearWindow(_ y: Int, _ text: String) -> QueryDateWindow {
    QueryDateWindow(
        start: String(format: "%04d-01-01T00:00:00Z", y),
        end: String(format: "%04d-12-31T23:59:59Z", y),
        matchedText: text)
}

/// Expands a month-only parse against a year range (typically the estate's
/// own event-time span): one month window per year, in ascending year order.
public func expandMonthOnly(
    month: Int, matchedText: String, years: ClosedRange<Int>
) -> [QueryDateWindow] {
    years.map { monthWindow($0, month, matchedText) }
}

/// Parses the first absolute date expression in a query.
///
/// Grammar v1 (design ruling Q2 — absolute only):
///   day-month-year   "8 May 2023" / "8 May, 2023" / "May 8, 2023" → day window
///   ISO date         "2023-05-08"                                  → day window
///   month-year       "May 2023" / "in May 2023"                    → month window
///   month-only       "in July" / bare month name                   → monthOnly
///   year-only        "in 2023" / bare 1900–2099 number             → year window
///
/// Longest-anchor-wins: a day-month-year match is preferred over the
/// month-year reading of the same tokens, month-year over month-only.
/// Month names inside other words do not match (word-boundary tokenizing).
public func parseQueryDateExpression(_ query: String) -> QueryDateParse {
    // Word-boundary tokens, lowercased, punctuation stripped at the edges.
    let rawTokens = query.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
    let tokens: [String] = rawTokens.map {
        $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:()'\""))
    }

    func int(_ s: String) -> Int? { Int(s) }
    func isYear(_ n: Int) -> Bool { (1900...2099).contains(n) }
    func isDay(_ n: Int) -> Bool { (1...31).contains(n) }

    // ISO date token anywhere: YYYY-MM-DD.
    for t in tokens where t.count == 10 && t[t.index(t.startIndex, offsetBy: 4)] == "-" {
        let p = t.split(separator: "-").map(String.init)
        if p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]),
           isYear(y), (1...12).contains(m), isDay(d) {
            return .anchored([dayWindow(y, m, d, t)])
        }
    }

    for (i, t) in tokens.enumerated() {
        guard let month = queryMonthNames[t] else { continue }
        let prev = i > 0 ? tokens[i - 1] : ""
        let next = i + 1 < tokens.count ? tokens[i + 1] : ""
        let next2 = i + 2 < tokens.count ? tokens[i + 2] : ""
        // "8 May 2023" / "8 May, 2023"
        if let d = int(prev), isDay(d), let y = int(next), isYear(y) {
            return .anchored([dayWindow(y, month, d, "\(prev) \(t) \(next)")])
        }
        // "May 8, 2023"
        if let d = int(next), isDay(d), let y = int(next2), isYear(y) {
            return .anchored([dayWindow(y, month, d, "\(t) \(next) \(next2)")])
        }
        // "8 May" with no year: month-only is the honest reading (the year is
        // unstated); day precision without a year would guess.
        // "May 2023"
        if let y = int(next), isYear(y) {
            return .anchored([monthWindow(y, month, "\(t) \(next)")])
        }
        // bare month → month-only
        return .monthOnly(month: month, matchedText: t)
    }

    // year-only: "in 2023" or a bare plausible year token
    for t in tokens {
        if let y = int(t), isYear(y) {
            return .anchored([yearWindow(y, String(y))])
        }
    }
    return .none
}

/// True when an ISO event-time string falls inside the window (inclusive).
/// String comparison is correct because all values share the fixed-width
/// "YYYY-MM-DDTHH:MM:SSZ" shape (ISO8601 UTC sorts lexicographically).
public func windowContains(_ window: QueryDateWindow, eventTime: String) -> Bool {
    eventTime >= window.start && eventTime <= window.end
}

/// Returns the window widened by `days` on each side (the sliding-window
/// expansion, ruling Q2 2026-08-19: expand ±1 day at a time until enough
/// candidates exist to compare, hard cap ±10). Pure civil-calendar
/// arithmetic on the fixed "YYYY-MM-DD…" bound shape; the time-of-day
/// parts of each bound are preserved (start keeps 00:00:00, end keeps
/// 23:59:59). `days <= 0` returns the window unchanged.
public func paddedWindow(_ window: QueryDateWindow, days: Int) -> QueryDateWindow {
    guard days > 0 else { return window }
    return QueryDateWindow(
        start: shiftISODay(window.start, by: -days),
        end: shiftISODay(window.end, by: days),
        matchedText: window.matchedText)
}

/// Shifts the DATE part of a fixed-shape ISO string by `days`, preserving
/// the time-of-day suffix. Hinnant civil-from-days / days-from-civil pure
/// integer math — no Calendar, no clock, identical in the Rust twin.
func shiftISODay(_ iso: String, by days: Int) -> String {
    let y = Int(iso.prefix(4))!
    let m = Int(iso.dropFirst(5).prefix(2))!
    let d = Int(iso.dropFirst(8).prefix(2))!
    let suffix = String(iso.dropFirst(10))
    // days_from_civil (Hinnant)
    let yy = m <= 2 ? y - 1 : y
    let era = (yy >= 0 ? yy : yy - 399) / 400
    let yoe = yy - era * 400
    let mp = (m + 9) % 12
    let doy = (153 * mp + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    var z = era * 146_097 + doe - 719_468
    z += days
    // civil_from_days (Hinnant)
    let z2 = z + 719_468
    let era2 = (z2 >= 0 ? z2 : z2 - 146_096) / 146_097
    let doe2 = z2 - era2 * 146_097
    let yoe2 = (doe2 - doe2 / 1460 + doe2 / 36_524 - doe2 / 146_096) / 365
    let yr = yoe2 + era2 * 400
    let doy2 = doe2 - (365 * yoe2 + yoe2 / 4 - yoe2 / 100)
    let mp2 = (5 * doy2 + 2) / 153
    let day = doy2 - (153 * mp2 + 2) / 5 + 1
    let mon = mp2 < 10 ? mp2 + 3 : mp2 - 9
    let year = mon <= 2 ? yr + 1 : yr
    return String(format: "%04d-%02d-%02d", year, mon, day) + suffix
}

/// True when the query ASKS FOR a date rather than stating one ("When did
/// Melanie go camping?", "What date was the gala?") — the Gap 3 scanner
/// fork (DECISION_DENSE_LANE_ENRICHMENT program). Deterministic token-
/// bigram scan; a query can be date-seeking AND carry an absolute date
/// ("When in 2023 did…"), in which case the parsed window wins upstream.
public func isDateSeekingQuery(_ query: String) -> Bool {
    let tokens = query.lowercased().split(separator: " ").map {
        $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:()'\""))
    }
    // "how long ago" — the one trigram form.
    for i in 0..<max(tokens.count, 2) - 2 where tokens.count >= 3 {
        if tokens[i] == "how" && tokens[i + 1] == "long" && tokens[i + 2] == "ago" {
            return true
        }
    }
    guard tokens.count >= 2 else { return false }
    for i in 0..<(tokens.count - 1) {
        let a = tokens[i], b = tokens[i + 1]
        if a == "when" && (b == "did" || b == "was" || b == "will" || b == "is") {
            return true
        }
        if (a == "what" || a == "which") && (b == "date" || b == "day" || b == "year" || b == "month") {
            return true
        }
    }
    return false
}
