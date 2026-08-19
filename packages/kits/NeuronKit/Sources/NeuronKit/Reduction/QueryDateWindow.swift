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
