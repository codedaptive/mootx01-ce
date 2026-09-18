//! QueryDateWindow — deterministic absolute-date-expression parsing for the
//! temporal_recall recipe. Twin of Swift
//! `NeuronKit/Reduction/QueryDateWindow.swift`; see that file for the design
//! rationale (decision record DECISION_SEARCH_STRATEGY_RECIPES_2026-08-19,
//! item 4). Pure string→window computation: no clock, no locale.

/// One inclusive UTC window an absolute date expression names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueryDateWindow {
    /// Inclusive window start, "YYYY-MM-DDT00:00:00Z" form.
    pub start: String,
    /// Inclusive window end, "YYYY-MM-DDT23:59:59Z" form.
    pub end: String,
    /// The query substring the window was parsed from (diagnostic).
    pub matched_text: String,
}

/// The result of parsing a query for absolute date expressions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum QueryDateParse {
    /// No absolute date expression found.
    None,
    /// Fully-anchored windows (year known).
    Anchored(Vec<QueryDateWindow>),
    /// Month-only expression: month known, year not — the recipe expands
    /// this against the estate's own year span.
    MonthOnly { month: u32, matched_text: String },
}

fn month_number(name: &str) -> Option<u32> {
    match name {
        "january" => Some(1), "february" => Some(2), "march" => Some(3),
        "april" => Some(4), "may" => Some(5), "june" => Some(6),
        "july" => Some(7), "august" => Some(8), "september" => Some(9),
        "october" => Some(10), "november" => Some(11), "december" => Some(12),
        _ => None,
    }
}

/// Day counts per month; February resolved with the standard leap rule.
fn days_in(month: u32, year: i32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        _ => {
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
            if leap { 29 } else { 28 }
        }
    }
}

fn day_window(y: i32, m: u32, d: u32, text: &str) -> QueryDateWindow {
    QueryDateWindow {
        start: format!("{y:04}-{m:02}-{d:02}T00:00:00Z"),
        end: format!("{y:04}-{m:02}-{d:02}T23:59:59Z"),
        matched_text: text.to_string(),
    }
}

fn month_window(y: i32, m: u32, text: &str) -> QueryDateWindow {
    QueryDateWindow {
        start: format!("{y:04}-{m:02}-01T00:00:00Z"),
        end: format!("{y:04}-{m:02}-{:02}T23:59:59Z", days_in(m, y)),
        matched_text: text.to_string(),
    }
}

fn year_window(y: i32, text: &str) -> QueryDateWindow {
    QueryDateWindow {
        start: format!("{y:04}-01-01T00:00:00Z"),
        end: format!("{y:04}-12-31T23:59:59Z"),
        matched_text: text.to_string(),
    }
}

/// Expands a month-only parse against a year range: one month window per
/// year, ascending. Twin of Swift `expandMonthOnly`.
pub fn expand_month_only(
    month: u32, matched_text: &str, years: std::ops::RangeInclusive<i32>,
) -> Vec<QueryDateWindow> {
    years.map(|y| month_window(y, month, matched_text)).collect()
}

/// Parses the first absolute date expression in a query. Grammar and
/// precedence are the Swift twin's, byte for byte on the golden pins.
pub fn parse_query_date_expression(query: &str) -> QueryDateParse {
    let tokens: Vec<String> = query
        .split_whitespace()
        .map(|t| t.to_lowercase().trim_matches(|c: char| ".,!?;:()'\"".contains(c)).to_string())
        .collect();

    let is_year = |n: i32| (1900..=2099).contains(&n);
    let is_day = |n: i32| (1..=31).contains(&n);

    // ISO date token anywhere: YYYY-MM-DD.
    for t in &tokens {
        if t.len() == 10 && t.as_bytes().get(4) == Some(&b'-') {
            let p: Vec<&str> = t.split('-').collect();
            if p.len() == 3 {
                if let (Ok(y), Ok(m), Ok(d)) =
                    (p[0].parse::<i32>(), p[1].parse::<u32>(), p[2].parse::<u32>())
                {
                    if is_year(y) && (1..=12).contains(&m) && is_day(d as i32) {
                        return QueryDateParse::Anchored(vec![day_window(y, m, d, t)]);
                    }
                }
            }
        }
    }

    for (i, t) in tokens.iter().enumerate() {
        let Some(month) = month_number(t) else { continue };
        let prev = if i > 0 { tokens[i - 1].as_str() } else { "" };
        let next = tokens.get(i + 1).map(String::as_str).unwrap_or("");
        let next2 = tokens.get(i + 2).map(String::as_str).unwrap_or("");
        // "8 May 2023"
        if let (Ok(d), Ok(y)) = (prev.parse::<i32>(), next.parse::<i32>()) {
            if is_day(d) && is_year(y) {
                return QueryDateParse::Anchored(vec![day_window(
                    y, month, d as u32, &format!("{prev} {t} {next}"))]);
            }
        }
        // "May 8, 2023"
        if let (Ok(d), Ok(y)) = (next.parse::<i32>(), next2.parse::<i32>()) {
            if is_day(d) && is_year(y) {
                return QueryDateParse::Anchored(vec![day_window(
                    y, month, d as u32, &format!("{t} {next} {next2}"))]);
            }
        }
        // "May 2023"
        if let Ok(y) = next.parse::<i32>() {
            if is_year(y) {
                return QueryDateParse::Anchored(vec![month_window(
                    y, month, &format!("{t} {next}"))]);
            }
        }
        // bare month → month-only (a day without a year also lands here;
        // day precision without a year would guess).
        return QueryDateParse::MonthOnly { month, matched_text: t.clone() };
    }

    // year-only
    for t in &tokens {
        if let Ok(y) = t.parse::<i32>() {
            if is_year(y) {
                return QueryDateParse::Anchored(vec![year_window(y, &y.to_string())]);
            }
        }
    }
    QueryDateParse::None
}

/// Returns the window widened by `days` on each side (the sliding-window
/// expansion, ruling Q2 2026-08-19: expand ±1 day at a time until enough
/// candidates exist to compare, hard cap ±10). Pure civil-calendar
/// arithmetic; time-of-day suffixes are preserved. `days <= 0` returns the
/// window unchanged. Twin of Swift `paddedWindow`.
pub fn padded_window(window: &QueryDateWindow, days: i64) -> QueryDateWindow {
    if days <= 0 {
        return window.clone();
    }
    QueryDateWindow {
        start: shift_iso_day(&window.start, -days),
        end: shift_iso_day(&window.end, days),
        matched_text: window.matched_text.clone(),
    }
}

/// Shifts the DATE part of a fixed-shape ISO string by `days`, preserving
/// the time-of-day suffix. Hinnant days-from-civil / civil-from-days pure
/// integer math — no clock; twin of Swift `shiftISODay`.
pub fn shift_iso_day(iso: &str, days: i64) -> String {
    let y: i64 = iso[0..4].parse().unwrap_or(1970);
    let m: i64 = iso[5..7].parse().unwrap_or(1);
    let d: i64 = iso[8..10].parse().unwrap_or(1);
    let suffix = &iso[10..];
    // days_from_civil (Hinnant)
    let yy = if m <= 2 { y - 1 } else { y };
    let era = if yy >= 0 { yy } else { yy - 399 } / 400;
    let yoe = yy - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let z = era * 146_097 + doe - 719_468 + days;
    // civil_from_days (Hinnant)
    let z2 = z + 719_468;
    let era2 = if z2 >= 0 { z2 } else { z2 - 146_096 } / 146_097;
    let doe2 = z2 - era2 * 146_097;
    let yoe2 = (doe2 - doe2 / 1460 + doe2 / 36_524 - doe2 / 146_096) / 365;
    let yr = yoe2 + era2 * 400;
    let doy2 = doe2 - (365 * yoe2 + yoe2 / 4 - yoe2 / 100);
    let mp2 = (5 * doy2 + 2) / 153;
    let day = doy2 - (153 * mp2 + 2) / 5 + 1;
    let mon = if mp2 < 10 { mp2 + 3 } else { mp2 - 9 };
    let year = if mon <= 2 { yr + 1 } else { yr };
    format!("{year:04}-{mon:02}-{day:02}{suffix}")
}

/// True when an ISO event-time string falls inside the window (inclusive).
/// Lexicographic comparison is correct for the fixed-width UTC ISO shape.
pub fn window_contains(window: &QueryDateWindow, event_time: &str) -> bool {
    event_time >= window.start.as_str() && event_time <= window.end.as_str()
}

/// True when the query ASKS FOR a date rather than stating one. Twin of
/// Swift `isDateSeekingQuery` (Gap 3 scanner fork). Deterministic
/// token-bigram scan.
pub fn is_date_seeking_query(query: &str) -> bool {
    let tokens: Vec<String> = query
        .split_whitespace()
        .map(|t| t.to_lowercase().trim_matches(|c: char| ".,!?;:()'\"".contains(c)).to_string())
        .collect();
    if tokens.len() >= 3 {
        for w in tokens.windows(3) {
            if w[0] == "how" && w[1] == "long" && w[2] == "ago" {
                return true;
            }
        }
    }
    for w in tokens.windows(2) {
        let (a, b) = (w[0].as_str(), w[1].as_str());
        if a == "when" && matches!(b, "did" | "was" | "will" | "is") {
            return true;
        }
        if matches!(a, "what" | "which") && matches!(b, "date" | "day" | "year" | "month") {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    // Golden pins — literal twins of QueryDateWindowTests.swift.
    #[test]
    fn day_month_year_pins() {
        assert_eq!(
            parse_query_date_expression("What happened on 8 May 2023 at the fair?"),
            QueryDateParse::Anchored(vec![QueryDateWindow {
                start: "2023-05-08T00:00:00Z".into(),
                end: "2023-05-08T23:59:59Z".into(),
                matched_text: "8 may 2023".into(),
            }]));
        assert_eq!(
            parse_query_date_expression("The 2023-05-08 entry"),
            QueryDateParse::Anchored(vec![QueryDateWindow {
                start: "2023-05-08T00:00:00Z".into(),
                end: "2023-05-08T23:59:59Z".into(),
                matched_text: "2023-05-08".into(),
            }]));
    }

    #[test]
    fn month_year_leap_pin() {
        assert_eq!(
            parse_query_date_expression("back in February 2024"),
            QueryDateParse::Anchored(vec![QueryDateWindow {
                start: "2024-02-01T00:00:00Z".into(),
                end: "2024-02-29T23:59:59Z".into(),
                matched_text: "february 2024".into(),
            }]));
    }

    #[test]
    fn month_only_pin() {
        assert_eq!(
            parse_query_date_expression("When did Melanie go camping in July?"),
            QueryDateParse::MonthOnly { month: 7, matched_text: "july".into() });
        assert_eq!(
            expand_month_only(7, "july", 2022..=2023),
            vec![
                QueryDateWindow { start: "2022-07-01T00:00:00Z".into(),
                                  end: "2022-07-31T23:59:59Z".into(),
                                  matched_text: "july".into() },
                QueryDateWindow { start: "2023-07-01T00:00:00Z".into(),
                                  end: "2023-07-31T23:59:59Z".into(),
                                  matched_text: "july".into() },
            ]);
    }

    #[test]
    fn year_only_and_none() {
        assert_eq!(
            parse_query_date_expression("everything from 2023"),
            QueryDateParse::Anchored(vec![QueryDateWindow {
                start: "2023-01-01T00:00:00Z".into(),
                end: "2023-12-31T23:59:59Z".into(),
                matched_text: "2023".into(),
            }]));
        assert_eq!(parse_query_date_expression("What is Melanie's favorite song?"),
                   QueryDateParse::None);
        assert_eq!(parse_query_date_expression("mayonnaise recipes and marching bands"),
                   QueryDateParse::None);
    }

    #[test]
    fn day_without_year_is_month_only() {
        assert_eq!(
            parse_query_date_expression("they met on 8 May at the market"),
            QueryDateParse::MonthOnly { month: 5, matched_text: "may".into() });
    }

    #[test]
    fn date_seeking_pins() {
        // Literal twins of the Swift isDateSeekingQuery pins.
        assert!(is_date_seeking_query("When did Melanie go camping?"));
        assert!(is_date_seeking_query("What date was the gala in Boston?"));
        assert!(is_date_seeking_query("how long ago did they meet"));
        assert!(!is_date_seeking_query("Which city was Calvin at on October 3, 2023?"));
        assert!(!is_date_seeking_query("What is Melanie's favorite song?"));
    }

    #[test]
    fn padded_window_pins() {
        // Literal twins of Swift paddedWindowPins.
        let w = QueryDateWindow { start: "2023-10-03T00:00:00Z".into(),
                                  end: "2023-10-03T23:59:59Z".into(),
                                  matched_text: "x".into() };
        let p1 = padded_window(&w, 1);
        assert_eq!(p1.start, "2023-10-02T00:00:00Z");
        assert_eq!(p1.end, "2023-10-04T23:59:59Z");
        let feb = QueryDateWindow { start: "2024-03-01T00:00:00Z".into(),
                                    end: "2024-03-01T23:59:59Z".into(),
                                    matched_text: "x".into() };
        let p2 = padded_window(&feb, 1);
        assert_eq!(p2.start, "2024-02-29T00:00:00Z");
        assert_eq!(p2.end, "2024-03-02T23:59:59Z");
        let jan = QueryDateWindow { start: "2023-01-05T00:00:00Z".into(),
                                    end: "2023-01-05T23:59:59Z".into(),
                                    matched_text: "x".into() };
        let p3 = padded_window(&jan, 10);
        assert_eq!(p3.start, "2022-12-26T00:00:00Z");
        assert_eq!(p3.end, "2023-01-15T23:59:59Z");
        assert_eq!(padded_window(&w, 0), w);
    }

    #[test]
    fn containment_inclusive() {
        let w = QueryDateWindow { start: "2023-07-01T00:00:00Z".into(),
                                  end: "2023-07-31T23:59:59Z".into(),
                                  matched_text: "july".into() };
        assert!(window_contains(&w, "2023-07-17T14:31:00Z"));
        assert!(window_contains(&w, "2023-07-01T00:00:00Z"));
        assert!(!window_contains(&w, "2023-08-01T00:00:00Z"));
    }
}
