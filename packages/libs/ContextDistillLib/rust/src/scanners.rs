//! Hand-written scanners for every compiled-regex constant in
//! distill_plus_converter.py.
//!
//! # Pattern inventory (all 26 compiled constants, definition order)
//!
//! Each scanner function mirrors one Python `re.compile(...)` constant.
//! The original Python pattern string is cited in each function's doc
//! comment so conformance reviewers can cross-check without opening the
//! oracle file.
//!
//! | Constant                | Python pattern (abbreviated)           |
//! |-------------------------|----------------------------------------|
//! | TRAILER_RE              | `(?P<trailer>\s+\(\*\[\s.*?\s\]\*\))\s*$` (DOTALL) |
//! | PIPE_SPLIT_RE           | `\s+\|\s+`                             |
//! | INLINE_NUMBERED_RE      | `(?:^|\s)(?P<marker>\d+[.)]\s+)`       |
//! | LIST_MARKER_RE          | `^\s*(?:[-*+•]|\d+[.)])\s+`            |
//! | WORD_RE                 | `[A-Za-z0-9]+(?:['-][A-Za-z0-9]+)*`   |
//! | NUMBER_RE               | `\b\d+(?:[.,]\d+)?\b`                  |
//! | DATE_RE                 | `\b(?:\d{4}-\d{2}-\d{2}...|\d{4})\b`  |
//! | CAPITALIZED_RE          | `\b[A-Z][A-Za-z0-9_-]+\b`             |
//! | GREETING_PREFIX_RE      | `^\s*(?:hi|hello|...)...` (IGNORECASE) |
//! | GREETING_ONLY_RE        | `^\s*(?:hi|hello|...)...$` (IGNORECASE)|
//! | DIALOGUE_FILLER_ONLY_RE | `^\s*(?:exactly|precisely|...)...$` (IGNORECASE) |
//! | REVISION_MARKER_RE      | `\b(?:revised|updated|final)\s+...\b` (IGNORECASE) |
//! | INITIAL_DRAFT_MARKER_RE | `\b(?:first|initial|original)\s+...\b` (IGNORECASE) |
//! | OPERATIVE_RE            | `^\s*(?:please\s+)?(?:amend|...)\b` (IGNORECASE) |
//! | TURN_FILLER_RE          | `^\s*(?:acknowledged|noted|...)...$` (IGNORECASE) |
//! | ASSISTANT_BOILERPLATE_RE| `^\s*(?:certainly|sure|...)...$` (IGNORECASE DOTALL) |
//! | EMBEDDED_USER_FACT_RE   | `(?:^|\n).*?(?P<fact>\d{4}-...\s[—-]\s*user:\s*[^\n]+)` (IGNORECASE) |
//! | FENCE_OPEN_RE           | `` ^\s*(`{3,}|~{3,}) ``               |
//! | MARKDOWN_HEADING_RE     | `^(?P<marks>#{1,6})\s+\S`              |
//! | BOLD_HEADING_RE         | `^\s*\*\*[^*\n]{1,120}\*\*\s*:?[ \t]*$` |
//! | FIELD_LINE_RE           | `^\s*[A-Za-z][A-Za-z0-9 _./()-]{0,80}:\s*\S` |
//! | TABLE_SEPARATOR_RE      | `^\s*\|?\s*:?-{3,}:?\s*(...)+\|?\s*$` |
//! | DIAGRAM_RE              | `[─-╿]|(?:--?>|==>|<--?)`   |
//! | POLARITY_ONLY_RE        | `^\s*(?:yes|no)\b[.!?\s]*$` (IGNORECASE) |
//! | TRANSFORM_FOLLOWUP_RE   | `\b(?:adapt|convert|...)...\b` (IGNORECASE) |
//! | QUANTITY_VALUE_RE       | `^[€£$]?\d+(?:[.,]\d+)?....$`         |
//!
//! # No regex engines
//! Zero use of `regex` crate, `NSRegularExpression`, Swift `Regex`, or
//! any other pattern-matching engine.  Every scanner is a hand-written
//! state machine.
//!
//! # Unicode semantics
//! - `\s` → `char::is_whitespace()` (Python Unicode whitespace, see
//!   `python_text::is_python_whitespace` for documented divergences).
//! - `\b` (no `re.ASCII`) → `python_text::word_boundary_at` using
//!   Unicode alnum + `_` as `\w`.
//! - `\d` → `char::is_ascii_digit()` (all digit uses are ASCII-context).
//! - `IGNORECASE` → compare lowercased chars; `char::to_lowercase()`
//!   for single chars, Python-equivalent on ASCII text.
//!
//! # Code-point offsets
//! All `start_cp` / `end_cp` values are indices into the `Vec<char>`
//! representation of the input, matching Python's `match.start()` /
//! `match.end()` which count Unicode code points, not bytes.

use crate::python_text::{is_python_whitespace, py_word_char, word_boundary_at};

// ---------------------------------------------------------------------------
// Public match record
// ---------------------------------------------------------------------------

/// One scanner match, with code-point offsets and all capturing groups.
///
/// `groups[0]` is always the full match text.  `groups[1..]` are
/// capturing groups in order; `None` for non-participating groups
/// (matches Python's `match.group(N)` returning `None`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScannerMatch {
    /// Code-point index of the first character of the match (inclusive).
    pub start_cp: usize,
    /// Code-point index just past the last character of the match (exclusive).
    pub end_cp: usize,
    /// `groups[0]` = full match; `groups[1..]` = numbered capturing groups.
    pub groups: Vec<Option<String>>,
}

impl ScannerMatch {
    fn new(start_cp: usize, end_cp: usize, chars: &[char]) -> Self {
        let full: String = chars[start_cp..end_cp].iter().collect();
        Self { start_cp, end_cp, groups: vec![Some(full)] }
    }

    fn with_group(
        start_cp: usize,
        end_cp: usize,
        chars: &[char],
        group_start: usize,
        group_end: usize,
    ) -> Self {
        let full: String = chars[start_cp..end_cp].iter().collect();
        let group: String = chars[group_start..group_end].iter().collect();
        Self {
            start_cp,
            end_cp,
            groups: vec![Some(full), Some(group)],
        }
    }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Convert `text` to a char vector (code-point array).
fn to_chars(text: &str) -> Vec<char> {
    text.chars().collect()
}

/// True if `c` is in `[A-Za-z0-9]` (ASCII alphanumeric).
#[inline]
fn is_ascii_alnum(c: char) -> bool {
    c.is_ascii_alphanumeric()
}

/// True if `c` is in `[A-Za-z0-9_-]` (CAPITALIZED_RE body class).
#[inline]
fn is_cap_body(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_' || c == '-'
}

/// Try to match exactly `n` ASCII digits starting at `chars[i]`.
/// Returns the new position (i + n) on success, or None on failure.
fn try_n_digits(chars: &[char], i: usize, n: usize) -> Option<usize> {
    if i + n > chars.len() {
        return None;
    }
    if chars[i..i + n].iter().all(|c| c.is_ascii_digit()) {
        Some(i + n)
    } else {
        None
    }
}

/// Try to match 1..=max ASCII digits.  Returns end position if ≥ min
/// digits matched, else None.
fn try_digits_range(chars: &[char], i: usize, min: usize, max: usize) -> Option<usize> {
    let mut count = 0;
    while i + count < chars.len() && chars[i + count].is_ascii_digit() && count < max {
        count += 1;
    }
    if count >= min { Some(i + count) } else { None }
}

/// Try to match an ISO date `\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?)?`
/// starting at `chars[i]`.  Returns end position on success.
fn try_iso_date(chars: &[char], i: usize) -> Option<usize> {
    let mut pos = try_n_digits(chars, i, 4)?;
    if pos >= chars.len() || chars[pos] != '-' { return None; }
    pos += 1;
    pos = try_n_digits(chars, pos, 2)?;
    if pos >= chars.len() || chars[pos] != '-' { return None; }
    pos += 1;
    pos = try_n_digits(chars, pos, 2)?;
    // Optional T\d{2}:\d{2}(?::\d{2})?
    if pos < chars.len() && chars[pos] == 'T' {
        let t_pos = pos + 1;
        if let Some(h_end) = try_n_digits(chars, t_pos, 2) {
            if h_end < chars.len() && chars[h_end] == ':' {
                if let Some(m_end) = try_n_digits(chars, h_end + 1, 2) {
                    pos = m_end;
                    if pos < chars.len() && chars[pos] == ':' {
                        if let Some(s_end) = try_n_digits(chars, pos + 1, 2) {
                            pos = s_end;
                        }
                    }
                }
            }
        }
        // If T is followed by malformed time, pos stays at the date-only end.
    }
    Some(pos)
}

/// Try ISO datetime to minutes: `\d{4}-\d{2}-\d{2}T\d{2}:\d{2}`.
/// Returns end position if the FULL sequence including T and HH:MM matches.
fn try_iso_datetime_to_minutes(chars: &[char], i: usize) -> Option<usize> {
    let mut pos = try_n_digits(chars, i, 4)?;
    if pos >= chars.len() || chars[pos] != '-' { return None; }
    pos += 1;
    pos = try_n_digits(chars, pos, 2)?;
    if pos >= chars.len() || chars[pos] != '-' { return None; }
    pos += 1;
    pos = try_n_digits(chars, pos, 2)?;
    if pos >= chars.len() || chars[pos] != 'T' { return None; }
    pos += 1;
    pos = try_n_digits(chars, pos, 2)?;
    if pos >= chars.len() || chars[pos] != ':' { return None; }
    pos += 1;
    try_n_digits(chars, pos, 2)
}

/// Try short date `\d{1,2}[/-]\d{1,2}[/-]\d{2,4}` starting at `chars[i]`.
fn try_short_date(chars: &[char], i: usize) -> Option<usize> {
    let mut pos = try_digits_range(chars, i, 1, 2)?;
    if pos >= chars.len() || (chars[pos] != '/' && chars[pos] != '-') {
        return None;
    }
    pos += 1;
    pos = try_digits_range(chars, pos, 1, 2)?;
    if pos >= chars.len() || (chars[pos] != '/' && chars[pos] != '-') {
        return None;
    }
    pos += 1;
    try_digits_range(chars, pos, 2, 4)
}

/// Try DATE_RE alternatives in order at position `i` with leading `\b`.
/// Returns end position if any alternative matches.
fn try_date_re_at(chars: &[char], i: usize) -> Option<usize> {
    // Alternative 1: ISO date (longest, try first)
    if let Some(end) = try_iso_date(chars, i) {
        if word_boundary_at(chars, end) {
            return Some(end);
        }
    }
    // Alternative 2: short date
    if let Some(end) = try_short_date(chars, i) {
        if word_boundary_at(chars, end) {
            return Some(end);
        }
    }
    // Alternative 3: 4-digit year \d{4}\b
    if let Some(end) = try_n_digits(chars, i, 4) {
        // Must be exactly 4 digits: next char must not be digit
        if word_boundary_at(chars, end) {
            return Some(end);
        }
    }
    None
}

/// Case-insensitive comparison of chars[pos..] to `s`.
fn case_insensitive_match(chars: &[char], pos: usize, s: &str) -> bool {
    let s_chars: Vec<char> = s.chars().collect();
    if pos + s_chars.len() > chars.len() {
        return false;
    }
    for (i, &sc) in s_chars.iter().enumerate() {
        // Compare lowercase; use first char of multi-char lowercase
        let lc: char = chars[pos + i].to_lowercase().next().unwrap_or(chars[pos + i]);
        if lc != sc {
            return false;
        }
    }
    true
}

/// Check for em-dash U+2014 or ASCII hyphen U+002D.
/// Mirrors `[—-]` in the Python pattern.
#[inline]
fn is_em_or_hyphen(c: char) -> bool {
    c == '\u{2014}' || c == '-'
}

// ---------------------------------------------------------------------------
// 1. TRAILER_RE
//
// Python: re.compile(r"(?P<trailer>\s+\(\*\[\s.*?\s\]\*\))\s*$", re.DOTALL)
//
// Used by split_enrichment via find_trailer in digest.rs.
// On the corpus originals (without trailers), this returns 0 matches.
// ---------------------------------------------------------------------------

/// Scanner for TRAILER_RE.
///
/// Python pattern: `(?P<trailer>\s+\(\*\[\s.*?\s\]\*\))\s*$` (re.DOTALL)
///
/// Finds the grammar-v1 enrichment trailer at the end of a distilled
/// record.  On the plain `original` fields in the 509-row corpus, this
/// pattern produces 0 matches (trailers are not present in the source
/// text).  The function is provided for completeness and for use by
/// `split_enrichment`.
///
/// Returns the last (and typically only) match, anchored to the end of
/// the string.  The captured group 1 is the trailer text (same as the
/// full match since the group covers the whole pattern except trailing
/// whitespace).
pub fn scan_trailer_re(text: &str) -> Vec<ScannerMatch> {
    // Delegate to the same logic used by digest::split_enrichment.
    let chars = to_chars(text);
    match crate::digest::find_trailer_pub(text) {
        None => Vec::new(),
        Some((ws_start, trailer_text)) => {
            // The full match extends to end of string (including \s*).
            let full_end = chars.len();
            let full_text: String = chars[ws_start..full_end].iter().collect();
            // group 0 = full match, group 1 = trailer (same text; trailing
            // whitespace stripped in trailer but the Python group captures
            // up to the content_end not the string end)
            let trailer_text_stripped = trailer_text.trim().to_string();
            vec![ScannerMatch {
                start_cp: ws_start,
                end_cp: full_end,
                groups: vec![Some(full_text), Some(trailer_text_stripped)],
            }]
        }
    }
}

// ---------------------------------------------------------------------------
// 2. PIPE_SPLIT_RE
//
// Python: re.compile(r"\s+\|\s+")
// ---------------------------------------------------------------------------

/// Scanner for PIPE_SPLIT_RE.
///
/// Python pattern: `\s+\|\s+`
///
/// Matches one or more whitespace chars, a pipe `|`, and one or more
/// whitespace chars.  Used as a field separator in enrichment trailer
/// content and in pipe-delimited text.
///
/// No capturing groups: `groups[0]` is the full match.
pub fn scan_pipe_split_re(text: &str) -> Vec<ScannerMatch> {
    let chars = to_chars(text);
    let mut results = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if !is_python_whitespace(chars[i]) {
            i += 1;
            continue;
        }
        // Leading \s+
        let start = i;
        while i < chars.len() && is_python_whitespace(chars[i]) {
            i += 1;
        }
        // Literal |
        if i < chars.len() && chars[i] == '|' {
            let pipe_pos = i;
            i += 1;
            // Trailing \s+
            if i < chars.len() && is_python_whitespace(chars[i]) {
                while i < chars.len() && is_python_whitespace(chars[i]) {
                    i += 1;
                }
                results.push(ScannerMatch::new(start, i, &chars));
            } else {
                // No trailing whitespace — not a match; restart after pipe
                i = pipe_pos + 1;
            }
        }
        // If no |, continue from after leading whitespace (i already advanced)
    }
    results
}

// ---------------------------------------------------------------------------
// 3. INLINE_NUMBERED_RE
//
// Python: re.compile(r"(?:^|\s)(?P<marker>\d+[.)]\s+)")
// Groups: [full_match, marker_group]
// ---------------------------------------------------------------------------

/// Scanner for INLINE_NUMBERED_RE.
///
/// Python pattern: `(?:^|\s)(?P<marker>\d+[.)]\s+)`
///
/// Matches a numbered list marker (`1. `, `2) `, etc.) that is preceded
/// by either the start of the string or a whitespace character.  The
/// named group `marker` captures `\d+[.)]\s+` (without the leading
/// whitespace or `^`).
///
/// `groups[0]` = full match (includes leading whitespace or nothing for `^`)
/// `groups[1]` = `marker` group (`\d+[.)]\s+`)
pub fn scan_inline_numbered_re(text: &str) -> Vec<ScannerMatch> {
    let chars = to_chars(text);
    let mut results = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        // Check anchor: start of string or whitespace at i
        let anchor_is_ws = i > 0 && is_python_whitespace(chars[i]);
        let anchor_is_start = i == 0;
        let (match_start, digit_start) = if anchor_is_start && chars[i].is_ascii_digit() {
            (0, 0) // ^ with digits starting at 0
        } else if anchor_is_ws {
            let ws_pos = i;
            // The whitespace char at i is the anchor; digits follow at i+1
            if i + 1 < chars.len() && chars[i + 1].is_ascii_digit() {
                (ws_pos, i + 1)
            } else {
                i += 1;
                continue;
            }
        } else {
            i += 1;
            continue;
        };

        // Match \d+
        let mut pos = digit_start;
        while pos < chars.len() && chars[pos].is_ascii_digit() {
            pos += 1;
        }
        if pos == digit_start {
            i += 1;
            continue; // no digits
        }
        // Match [.)]
        if pos >= chars.len() || (chars[pos] != '.' && chars[pos] != ')') {
            i += 1;
            continue;
        }
        pos += 1;
        // Match \s+ (at least one whitespace)
        if pos >= chars.len() || !is_python_whitespace(chars[pos]) {
            i += 1;
            continue;
        }
        let marker_start = digit_start;
        while pos < chars.len() && is_python_whitespace(chars[pos]) {
            pos += 1;
        }
        let marker_end = pos;
        let match_end = marker_end;

        results.push(ScannerMatch::with_group(
            match_start,
            match_end,
            &chars,
            marker_start,
            marker_end,
        ));
        i = match_end; // advance past the match (non-overlapping)
    }
    results
}

// ---------------------------------------------------------------------------
// 4. LIST_MARKER_RE
//
// Python: re.compile(r"^\s*(?:[-*+•]|\d+[.)])\s+")
//
// `^` without re.MULTILINE → only matches at position 0.
// On the 509-row corpus the originals do not start with list markers,
// so this returns 0 matches.
// ---------------------------------------------------------------------------

/// Scanner for LIST_MARKER_RE.
///
/// Python pattern: `^\s*(?:[-*+•]|\d+[.)])\s+`
///
/// Matches a list marker at the start of the string only (no MULTILINE).
/// Returns 0 matches for strings that don't start with list markers.
///
/// No capturing groups.
pub fn scan_list_marker_re(text: &str) -> Vec<ScannerMatch> {
    let chars = to_chars(text);
    if chars.is_empty() {
        return Vec::new();
    }
    let mut pos = 0;
    // \s*
    while pos < chars.len() && is_python_whitespace(chars[pos]) {
        pos += 1;
    }
    // [-*+•] or \d+[.)]
    let bullet_end = if pos < chars.len()
        && (chars[pos] == '-'
            || chars[pos] == '*'
            || chars[pos] == '+'
            || chars[pos] == '\u{2022}')
    {
        pos + 1
    } else {
        // Try \d+[.)]
        let digit_start = pos;
        while pos < chars.len() && chars[pos].is_ascii_digit() {
            pos += 1;
        }
        if pos == digit_start {
            return Vec::new(); // no bullet char or digits
        }
        if pos >= chars.len() || (chars[pos] != '.' && chars[pos] != ')') {
            return Vec::new();
        }
        pos + 1
    };
    // \s+ (at least one)
    let mut trail_end = bullet_end;
    if trail_end >= chars.len() || !is_python_whitespace(chars[trail_end]) {
        return Vec::new();
    }
    while trail_end < chars.len() && is_python_whitespace(chars[trail_end]) {
        trail_end += 1;
    }
    vec![ScannerMatch::new(0, trail_end, &chars)]
}

// ---------------------------------------------------------------------------
// 5. WORD_RE
//
// Python: re.compile(r"[A-Za-z0-9]+(?:['-][A-Za-z0-9]+)*")
// ---------------------------------------------------------------------------

/// Scanner for WORD_RE.
///
/// Python pattern: `[A-Za-z0-9]+(?:['-][A-Za-z0-9]+)*`
///
/// Matches sequences of ASCII alphanumeric characters optionally
/// extended by single-quote `'` or hyphen `-` followed by more
/// alphanumeric chars.  This is the primary word tokeniser.
///
/// Examples: "hello", "it's", "well-known", "don't", "U.S.A" → "U"
///
/// No capturing groups.
pub fn scan_word_re(text: &str) -> Vec<ScannerMatch> {
    let chars = to_chars(text);
    let mut results = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if !is_ascii_alnum(chars[i]) {
            i += 1;
            continue;
        }
        let start = i;
        // Consume [A-Za-z0-9]+
        while i < chars.len() && is_ascii_alnum(chars[i]) {
            i += 1;
        }
        // Try to extend with (['-][A-Za-z0-9]+)*
        loop {
            if i >= chars.len() {
                break;
            }
            let sep = chars[i];
            if sep != '\'' && sep != '-' {
                break;
            }
            // Peek: the next char must be ASCII alnum for the extension
            if i + 1 >= chars.len() || !is_ascii_alnum(chars[i + 1]) {
                break;
            }
            i += 1; // consume ' or -
            while i < chars.len() && is_ascii_alnum(chars[i]) {
                i += 1;
            }
        }
        results.push(ScannerMatch::new(start, i, &chars));
    }
    results
}

// ---------------------------------------------------------------------------
// 6. NUMBER_RE
//
// Python: re.compile(r"\b\d+(?:[.,]\d+)?\b")
// ---------------------------------------------------------------------------

/// Scanner for NUMBER_RE.
///
/// Python pattern: `\b\d+(?:[.,]\d+)?\b`
///
/// Matches digit sequences at word boundaries, optionally followed by
/// `.` or `,` and more digits (for decimal/thousands notation).
///
/// The `\b` uses Python's Unicode `\w` definition (`py_word_char`).
///
/// No capturing groups.
pub fn scan_number_re(text: &str) -> Vec<ScannerMatch> {
    let chars = to_chars(text);
    let mut results = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if !chars[i].is_ascii_digit() {
            i += 1;
            continue;
        }
        // Check leading \b: char before must not be word char (or start)
        if !word_boundary_at(&chars, i) {
            i += 1;
            continue;
        }
        let start = i;
        // Consume \d+
        while i < chars.len() && chars[i].is_ascii_digit() {
            i += 1;
        }
        // Try optional [.,]\d+
        let extended_end = if i < chars.len() && (chars[i] == '.' || chars[i] == ',') {
            if i + 1 < chars.len() && chars[i + 1].is_ascii_digit() {
                let mut j = i + 1;
                while j < chars.len() && chars[j].is_ascii_digit() {
                    j += 1;
                }
                // Check trailing \b at j
                if word_boundary_at(&chars, j) {
                    j
                } else {
                    i // revert: no trailing boundary after decimal
                }
            } else {
                i
            }
        } else {
            i
        };

        let end = extended_end;
        // Check trailing \b at end (if we didn't extend with decimal)
        let end = if end == i {
            if word_boundary_at(&chars, i) { i } else {
                // trailing boundary failed at plain digit end; skip
                continue;
            }
        } else {
            end
        };

        results.push(ScannerMatch::new(start, end, &chars));
        i = end; // advance past the full match (decimal extension may go further than digit run)
    }
    results
}

// ---------------------------------------------------------------------------
// 7. DATE_RE
//
// Python:
//   DATE_RE = re.compile(
//       r"\b(?:\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?)?"
//       r"|\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\d{4})\b"
//   )
// ---------------------------------------------------------------------------

/// Scanner for DATE_RE.
///
/// Python pattern (combined):
/// `\b(?:\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?)?|\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\d{4})\b`
///
/// Three ordered alternatives, all bounded by `\b`:
/// 1. ISO date with optional time: `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM[:SS]`
/// 2. Short date: `M/D/YY` or `M-D-YYYY` (1-2 digits, separator, 2-4 year)
/// 3. Four-digit year: `YYYY` (exactly 4 digits at word boundaries)
///
/// No capturing groups.
pub fn scan_date_re(text: &str) -> Vec<ScannerMatch> {
    let chars = to_chars(text);
    let mut results = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        // Require leading \b (digit is a word char, so left must be non-word)
        if !chars[i].is_ascii_digit() {
            i += 1;
            continue;
        }
        if !word_boundary_at(&chars, i) {
            i += 1;
            continue;
        }
        if let Some(end) = try_date_re_at(&chars, i) {
            results.push(ScannerMatch::new(i, end, &chars));
            i = end;
        } else {
            i += 1;
        }
    }
    results
}

// ---------------------------------------------------------------------------
// 8. CAPITALIZED_RE
//
// Python: re.compile(r"\b[A-Z][A-Za-z0-9_-]+\b")
// ---------------------------------------------------------------------------

/// Scanner for CAPITALIZED_RE.
///
/// Python pattern: `\b[A-Z][A-Za-z0-9_-]+\b`
///
/// Matches words starting with an uppercase ASCII letter followed by
/// at least one additional `[A-Za-z0-9_-]` character, bounded by `\b`.
///
/// Backtracking: `[A-Za-z0-9_-]+` is greedy.  If the trailing `\b`
/// fails (e.g. the match ends on a `-` which is not a `\w` char),
/// the scanner backtracks by trimming trailing hyphens until `\b`
/// holds or no body chars remain.
///
/// No capturing groups.
pub fn scan_capitalized_re(text: &str) -> Vec<ScannerMatch> {
    let chars = to_chars(text);
    let mut results = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        // Leading \b: left must be non-word-char (or start of string),
        // and the char at i must be an uppercase ASCII letter (word char).
        let left_non_word = i == 0 || !py_word_char(chars[i - 1]);
        if !left_non_word || !chars[i].is_ascii_uppercase() {
            i += 1;
            continue;
        }
        let start = i;
        i += 1; // consume [A-Z]
        let body_start = i;
        // Greedy: consume [A-Za-z0-9_-]+
        while i < chars.len() && is_cap_body(chars[i]) {
            i += 1;
        }
        if i == body_start {
            // No body chars: `\b[A-Z]\b` — the + requires at least one.
            continue;
        }
        // Backtrack trailing hyphens: `-` is not a \w char, so the right
        // \b would require the char after `-` to be a word char, which is
        // uncommon.  Trim trailing `-` to find the natural word end.
        let mut end = i;
        while end > body_start && chars[end - 1] == '-' {
            end -= 1;
        }
        if end == body_start {
            // All body chars were hyphens — no match.
            continue;
        }
        // Check trailing \b: char before end must be word char (guaranteed
        // since we stripped trailing `-`), char at end must be non-word.
        let right_non_word = end == chars.len() || !py_word_char(chars[end]);
        if right_non_word {
            results.push(ScannerMatch::new(start, end, &chars));
            i = end; // resume after trimmed end
        }
        // If right boundary fails even after trimming, skip (i already past start).
    }
    results
}

// ---------------------------------------------------------------------------
// 9. GREETING_PREFIX_RE  (IGNORECASE, anchored to ^)
//
// Python:
//   GREETING_PREFIX_RE = re.compile(
//       r"^\s*(?:(?:hi|hello|hey|good morning|good afternoon|good evening)"
//       r"(?:\s+there)?[!,.\s]*|(?:thanks|thank you)(?:\s+so much)?[!,.\s]+)",
//       re.IGNORECASE,
//   )
//
// Only matches at position 0. The corpus has 1 match: "Hi" at s=0, e=2.
// ---------------------------------------------------------------------------

/// Scanner for GREETING_PREFIX_RE.
///
/// Python pattern: `^\s*(?:(?:hi|hello|hey|good morning|good afternoon|good evening)(?:\s+there)?[!,.\s]*|(?:thanks|thank you)(?:\s+so much)?[!,.\s]+)` (IGNORECASE)
///
/// Anchored to start of string (`^`, no MULTILINE).  Matches common
/// greeting and thanks phrases.  On the 509-row corpus this matches
/// exactly once: "Hi" at position 0-2.
///
/// No capturing groups.
pub fn scan_greeting_prefix_re(text: &str) -> Vec<ScannerMatch> {
    let chars = to_chars(text);
    if chars.is_empty() {
        return Vec::new();
    }
    let mut pos = 0;
    // \s*
    while pos < chars.len() && is_python_whitespace(chars[pos]) {
        pos += 1;
    }
    if pos >= chars.len() {
        return Vec::new();
    }

    // Try "thanks" / "thank you" first (longer, more specific)
    let thanks_phrases = ["thank you", "thanks"];
    let greeting_phrases = [
        "good morning",
        "good afternoon",
        "good evening",
        "hello",
        "hey",
        "hi",
    ];

    // Try thanks group
    for phrase in &thanks_phrases {
        if case_insensitive_match(&chars, pos, phrase) {
            let mut end = pos + phrase.chars().count();
            // Optional "\s+so much"
            let saved = end;
            if end < chars.len() && is_python_whitespace(chars[end]) {
                let mut ws_end = end;
                while ws_end < chars.len() && is_python_whitespace(chars[ws_end]) {
                    ws_end += 1;
                }
                if case_insensitive_match(&chars, ws_end, "so much") {
                    end = ws_end + 7;
                } else {
                    end = saved;
                }
            }
            // [!,.\s]+ (at least one for thanks)
            let trail_start = end;
            while end < chars.len()
                && (chars[end] == '!'
                    || chars[end] == ','
                    || chars[end] == '.'
                    || is_python_whitespace(chars[end]))
            {
                end += 1;
            }
            if end > trail_start {
                return vec![ScannerMatch::new(0, end, &chars)];
            }
            // If no trailing char, thanks alone doesn't match (needs [!,.\s]+)
        }
    }

    // Try greeting group
    for phrase in &greeting_phrases {
        if case_insensitive_match(&chars, pos, phrase) {
            let mut end = pos + phrase.chars().count();
            // Optional "\s+there"
            let saved = end;
            if end < chars.len() && is_python_whitespace(chars[end]) {
                let mut ws_end = end;
                while ws_end < chars.len() && is_python_whitespace(chars[ws_end]) {
                    ws_end += 1;
                }
                if case_insensitive_match(&chars, ws_end, "there") {
                    end = ws_end + 5;
                } else {
                    end = saved;
                }
            }
            // [!,.\s]* (zero or more for greetings — match is valid even without trail)
            while end < chars.len()
                && (chars[end] == '!'
                    || chars[end] == ','
                    || chars[end] == '.'
                    || is_python_whitespace(chars[end]))
            {
                end += 1;
            }
            return vec![ScannerMatch::new(0, end, &chars)];
        }
    }

    Vec::new()
}

// ---------------------------------------------------------------------------
// 10. GREETING_ONLY_RE  (IGNORECASE)
//
// Python:
//   GREETING_ONLY_RE = re.compile(
//       r"^\s*(?:hi|hello|hey|good morning|good afternoon|good evening|thanks|"
//       r"thank you|bye|goodbye)(?:\s+(?:there|for now|so much))?[!,.\s]*$",
//       re.IGNORECASE,
//   )
//
// 0 matches on the 509-row corpus.
// ---------------------------------------------------------------------------

/// Scanner for GREETING_ONLY_RE.
///
/// Python pattern: `^\s*(?:hi|hello|...)(?:\s+(?:there|for now|so much))?[!,.\s]*$` (IGNORECASE)
///
/// Matches a string that consists ONLY of a greeting (with optional
/// suffix and punctuation).  On the 509-row corpus this produces 0 matches.
///
/// No capturing groups.
pub fn scan_greeting_only_re(text: &str) -> Vec<ScannerMatch> {
    let chars = to_chars(text);
    if chars.is_empty() {
        return Vec::new();
    }
    let mut pos = 0;
    while pos < chars.len() && is_python_whitespace(chars[pos]) {
        pos += 1;
    }

    let greetings = [
        "goodbye", "thank you", "good morning", "good afternoon", "good evening",
        "hello", "thanks", "bye", "hey", "hi",
    ];
    let mut matched_end = None;
    for g in &greetings {
        if case_insensitive_match(&chars, pos, g) {
            let mut end = pos + g.chars().count();
            // Optional \s+ (there|for now|so much)
            let save = end;
            if end < chars.len() && is_python_whitespace(chars[end]) {
                let mut ws = end;
                while ws < chars.len() && is_python_whitespace(chars[ws]) { ws += 1; }
                let suffixes = ["for now", "so much", "there"];
                let mut found_suf = false;
                for suf in &suffixes {
                    if case_insensitive_match(&chars, ws, suf) {
                        end = ws + suf.chars().count();
                        found_suf = true;
                        break;
                    }
                }
                if !found_suf { end = save; }
            }
            // [!,.\s]*
            while end < chars.len()
                && (chars[end] == '!' || chars[end] == ',' || chars[end] == '.' || is_python_whitespace(chars[end]))
            {
                end += 1;
            }
            // $ — must reach end of string
            if end == chars.len() {
                matched_end = Some(end);
            }
            break;
        }
    }
    match matched_end {
        Some(end) => vec![ScannerMatch::new(0, end, &chars)],
        None => Vec::new(),
    }
}

// ---------------------------------------------------------------------------
// 11. DIALOGUE_FILLER_ONLY_RE  (IGNORECASE)  — 0 matches on corpus
// ---------------------------------------------------------------------------

/// Scanner for DIALOGUE_FILLER_ONLY_RE.
///
/// Python pattern: `^\s*(?:exactly|precisely|absolutely|sure|right|okay|ok|oh, tell me about it|that's great|...)[!.\s]*$` (IGNORECASE)
///
/// Matches dialogue filler phrases as the entire string content.
/// 0 matches on the 509-row corpus.
///
/// No capturing groups.
pub fn scan_dialogue_filler_only_re(text: &str) -> Vec<ScannerMatch> {
    // Pattern:
    // r"^\s*(?:exactly|precisely|absolutely|sure|right|okay|ok|"
    // r"oh[, ]+tell me about it|that(?:'s| is) (?:great|wonderful|lovely|"
    // r"fantastic)(?: to hear)?)[!.\s]*$"
    let chars = to_chars(text);
    if chars.is_empty() { return Vec::new(); }
    let mut pos = 0;
    while pos < chars.len() && is_python_whitespace(chars[pos]) { pos += 1; }

    // Simple fillers (order: longer first to avoid prefix shadowing)
    let simple = [
        "precisely", "absolutely", "exactly", "right", "okay", "sure", "ok",
    ];
    for s in &simple {
        if case_insensitive_match(&chars, pos, s) {
            let mut end = pos + s.chars().count();
            while end < chars.len() && (chars[end] == '!' || chars[end] == '.' || is_python_whitespace(chars[end])) { end += 1; }
            if end == chars.len() { return vec![ScannerMatch::new(0, end, &chars)]; }
        }
    }
    // "oh[, ]+tell me about it"
    if case_insensitive_match(&chars, pos, "oh") {
        let mut p = pos + 2;
        while p < chars.len() && (chars[p] == ',' || chars[p] == ' ') { p += 1; }
        if case_insensitive_match(&chars, p, "tell me about it") {
            let mut end = p + 16;
            while end < chars.len() && (chars[end] == '!' || chars[end] == '.' || is_python_whitespace(chars[end])) { end += 1; }
            if end == chars.len() { return vec![ScannerMatch::new(0, end, &chars)]; }
        }
    }
    // "that('s| is) (great|wonderful|lovely|fantastic)(?: to hear)?"
    if case_insensitive_match(&chars, pos, "that") {
        let mut p = pos + 4;
        let found = if case_insensitive_match(&chars, p, "'s") { p += 2; true }
                    else if case_insensitive_match(&chars, p, " is") { p += 3; true }
                    else { false };
        if found {
            if p < chars.len() && chars[p] == ' ' { p += 1; }
            for adj in &["wonderful", "fantastic", "lovely", "great"] {
                if case_insensitive_match(&chars, p, adj) {
                    let mut end = p + adj.chars().count();
                    if case_insensitive_match(&chars, end, " to hear") { end += 8; }
                    while end < chars.len() && (chars[end] == '!' || chars[end] == '.' || is_python_whitespace(chars[end])) { end += 1; }
                    if end == chars.len() { return vec![ScannerMatch::new(0, end, &chars)]; }
                    break;
                }
            }
        }
    }
    Vec::new()
}

// ---------------------------------------------------------------------------
// 12. REVISION_MARKER_RE  (IGNORECASE)
//
// Python:
//   REVISION_MARKER_RE = re.compile(
//       r"\b(?:revised|updated|final)\s+(?:chapter\s+)?(?:outline|draft|plan|version)\b",
//       re.IGNORECASE,
//   )
// ---------------------------------------------------------------------------

/// Scanner for REVISION_MARKER_RE.
///
/// Python pattern: `\b(?:revised|updated|final)\s+(?:chapter\s+)?(?:outline|draft|plan|version)\b` (IGNORECASE)
///
/// Matches revision-marker phrases like "revised outline", "final draft",
/// "updated version", "final chapter outline".  8 matches on the corpus.
///
/// No capturing groups.
pub fn scan_revision_marker_re(text: &str) -> Vec<ScannerMatch> {
    let chars = to_chars(text);
    let mut results = Vec::new();
    let mut i = 0;
    let lead_words = ["revised", "updated", "final"];
    let tail_words = ["outline", "draft", "plan", "version"];

    while i < chars.len() {
        if !word_boundary_at(&chars, i) {
            i += 1;
            continue;
        }
        // Try each lead word
        let mut matched = false;
        for lead in &lead_words {
            let n = lead.len(); // all ASCII
            if case_insensitive_match(&chars, i, lead)
                && word_boundary_at(&chars, i + n)
            {
                let mut pos = i + n;
                // \s+
                if pos >= chars.len() || !is_python_whitespace(chars[pos]) {
                    continue;
                }
                while pos < chars.len() && is_python_whitespace(chars[pos]) { pos += 1; }
                // Optional "chapter\s+"
                let save = pos;
                if case_insensitive_match(&chars, pos, "chapter") {
                    let cp = pos + 7;
                    if cp < chars.len() && is_python_whitespace(chars[cp]) {
                        let mut cp2 = cp;
                        while cp2 < chars.len() && is_python_whitespace(chars[cp2]) { cp2 += 1; }
                        pos = cp2;
                    } else {
                        pos = save;
                    }
                }
                // Tail word
                for tail in &tail_words {
                    let tn = tail.len();
                    if case_insensitive_match(&chars, pos, tail)
                        && word_boundary_at(&chars, pos + tn)
                    {
                        results.push(ScannerMatch::new(i, pos + tn, &chars));
                        i = pos + tn;
                        matched = true;
                        break;
                    }
                }
                if matched { break; }
            }
        }
        if !matched {
            i += 1;
        }
    }
    results
}

// ---------------------------------------------------------------------------
// 13. INITIAL_DRAFT_MARKER_RE  (IGNORECASE)  — 0 matches on corpus
// ---------------------------------------------------------------------------

/// Scanner for INITIAL_DRAFT_MARKER_RE.
///
/// Python pattern: `\b(?:first|initial|original)\s+(?:chapter\s+)?(?:outline|draft|plan|version)\b` (IGNORECASE)
///
/// Mirror of REVISION_MARKER_RE for initial-draft phrases.
/// 0 matches on the 509-row corpus.
///
/// No capturing groups.
pub fn scan_initial_draft_marker_re(text: &str) -> Vec<ScannerMatch> {
    let chars = to_chars(text);
    let mut results = Vec::new();
    let mut i = 0;
    let lead_words = ["original", "initial", "first"];
    let tail_words = ["outline", "draft", "plan", "version"];

    while i < chars.len() {
        if !word_boundary_at(&chars, i) { i += 1; continue; }
        let mut matched = false;
        for lead in &lead_words {
            let n = lead.len();
            if case_insensitive_match(&chars, i, lead) && word_boundary_at(&chars, i + n) {
                let mut pos = i + n;
                if pos >= chars.len() || !is_python_whitespace(chars[pos]) { continue; }
                while pos < chars.len() && is_python_whitespace(chars[pos]) { pos += 1; }
                let save = pos;
                if case_insensitive_match(&chars, pos, "chapter") {
                    let cp = pos + 7;
                    if cp < chars.len() && is_python_whitespace(chars[cp]) {
                        let mut cp2 = cp;
                        while cp2 < chars.len() && is_python_whitespace(chars[cp2]) { cp2 += 1; }
                        pos = cp2;
                    } else { pos = save; }
                }
                for tail in &tail_words {
                    let tn = tail.len();
                    if case_insensitive_match(&chars, pos, tail) && word_boundary_at(&chars, pos + tn) {
                        results.push(ScannerMatch::new(i, pos + tn, &chars));
                        i = pos + tn;
                        matched = true;
                        break;
                    }
                }
                if matched { break; }
            }
        }
        if !matched { i += 1; }
    }
    results
}

// ---------------------------------------------------------------------------
// 14. OPERATIVE_RE  (IGNORECASE, anchored to ^)  — 0 matches on corpus
// ---------------------------------------------------------------------------

/// Scanner for OPERATIVE_RE.
///
/// Python pattern: `^\s*(?:please\s+)?(?:amend|analyze|answer|check|compare|convert|describe|determine|edit|explain|extract|find|identify|list|review|revise|show|summarize|tell|update|verify|write)\b` (IGNORECASE)
///
/// Matches operative instructions at the start of a text.  0 matches
/// when applied to full `original` fields (the originals are diary
/// entries, not single user utterances).
///
/// No capturing groups.
pub fn scan_operative_re(text: &str) -> Vec<ScannerMatch> {
    let chars = to_chars(text);
    if chars.is_empty() { return Vec::new(); }
    let mut pos = 0;
    while pos < chars.len() && is_python_whitespace(chars[pos]) { pos += 1; }
    // Optional "please\s+"
    let save = pos;
    if case_insensitive_match(&chars, pos, "please") {
        let p = pos + 6;
        if p < chars.len() && is_python_whitespace(chars[p]) {
            let mut p2 = p;
            while p2 < chars.len() && is_python_whitespace(chars[p2]) { p2 += 1; }
            pos = p2;
        } else {
            pos = save;
        }
    }
    let verbs = [
        "summarize", "identify", "determine", "describe", "explain",
        "extract", "compare", "convert", "analyze", "analyse", "update",
        "verify", "review", "revise", "amend", "answer", "check", "write",
        "find", "list", "show", "edit", "tell",
    ];
    for verb in &verbs {
        let n = verb.chars().count();
        if case_insensitive_match(&chars, pos, verb) && word_boundary_at(&chars, pos + n) {
            return vec![ScannerMatch::new(0, pos + n, &chars)];
        }
    }
    Vec::new()
}

// ---------------------------------------------------------------------------
// 15. TURN_FILLER_RE  (IGNORECASE)  — 0 matches on corpus
// ---------------------------------------------------------------------------

/// Scanner for TURN_FILLER_RE.
///
/// Python pattern: `^\s*(?:acknowledged|noted|received|ok(?:ay)?|sure|thanks|thank you|got it|understood|sounds good|great|perfect|exactly|absolutely|you(?:'re| are) welcome)[.!\s]*$` (IGNORECASE)
///
/// 0 matches on the 509-row corpus.
///
/// No capturing groups.
pub fn scan_turn_filler_re(text: &str) -> Vec<ScannerMatch> {
    let chars = to_chars(text);
    if chars.is_empty() { return Vec::new(); }
    let mut pos = 0;
    while pos < chars.len() && is_python_whitespace(chars[pos]) { pos += 1; }
    // Ordered: longest phrases first to avoid prefix shadowing
    let phrases = [
        "acknowledged", "sounds good", "thank you", "understood", "received",
        "perfectly", "absolutely", "you're welcome", "you are welcome",
        "exactly", "got it", "perfect", "thanks", "noted", "great", "okay",
        "sure", "ok",
    ];
    for phrase in &phrases {
        let n = phrase.chars().count();
        if case_insensitive_match(&chars, pos, phrase) {
            let mut end = pos + n;
            while end < chars.len() && (chars[end] == '.' || chars[end] == '!' || is_python_whitespace(chars[end])) { end += 1; }
            if end == chars.len() { return vec![ScannerMatch::new(0, end, &chars)]; }
        }
    }
    Vec::new()
}

// ---------------------------------------------------------------------------
// 16. ASSISTANT_BOILERPLATE_RE  (IGNORECASE | DOTALL)  — 0 matches
// ---------------------------------------------------------------------------

/// Scanner for ASSISTANT_BOILERPLATE_RE.
///
/// Python pattern (multi-alternative, IGNORECASE + DOTALL):
/// `^\s*(?:certainly|sure|of course)[.!,:\s]*(?:i(?:'d| will) be happy to)?\s*$`
/// `| ^\s*i hope this helps[.!?\s]*$`
/// `| ^\s*let me know if you (?:have|need)(?: any)? (?:questions|anything(?: else)?)[.!?\s]*$`
///
/// 0 matches on the 509-row corpus.
///
/// No capturing groups.
pub fn scan_assistant_boilerplate_re(text: &str) -> Vec<ScannerMatch> {
    let chars = to_chars(text);
    if chars.is_empty() { return Vec::new(); }
    let n = chars.len();

    // Helper: strip leading whitespace, return new pos
    let skip_ws = |pos: usize, cs: &[char]| -> usize {
        let mut p = pos;
        while p < cs.len() && is_python_whitespace(cs[p]) { p += 1; }
        p
    };
    // Helper: check chars[p..] ends with only [.!?\s] or [.!,:\s] up to end
    let trail_to_end = |mut p: usize, cs: &[char], extra: &str| -> bool {
        while p < cs.len() {
            let c = cs[p];
            if c == '.' || c == '!' || c == '?' || is_python_whitespace(c) || extra.contains(c) { p += 1; }
            else { return false; }
        }
        true
    };

    let pos = skip_ws(0, &chars);

    // Alt 1: certainly|sure|of course
    for opener in &["certainly", "of course", "sure"] {
        let on = opener.chars().count();
        if case_insensitive_match(&chars, pos, opener) {
            let mut p = pos + on;
            // [.!,:\s]*
            while p < n && (chars[p] == '.' || chars[p] == '!' || chars[p] == ',' || chars[p] == ':' || is_python_whitespace(chars[p])) { p += 1; }
            // Optional: i('d| will) be happy to
            if case_insensitive_match(&chars, p, "i") {
                let p2 = p + 1;
                let has_contract = case_insensitive_match(&chars, p2, "'d be happy to") || case_insensitive_match(&chars, p2, " will be happy to");
                if has_contract {
                    let skip = if chars[p2] == '\'' { 14 } else { 16 };
                    p = p2 + skip;
                }
            }
            // \s*$
            while p < n && is_python_whitespace(chars[p]) { p += 1; }
            if p == n { return vec![ScannerMatch::new(0, n, &chars)]; }
        }
    }

    // Alt 2: i hope this helps
    if case_insensitive_match(&chars, pos, "i hope this helps") {
        let p = pos + 17;
        if trail_to_end(p, &chars, "?") { return vec![ScannerMatch::new(0, n, &chars)]; }
    }

    // Alt 3: let me know if you (have|need) (any)? (questions|anything(else)?)
    if case_insensitive_match(&chars, pos, "let me know if you ") {
        let mut p = pos + 19;
        let has_need = if case_insensitive_match(&chars, p, "have ") { p += 5; true }
                       else if case_insensitive_match(&chars, p, "need ") { p += 5; true }
                       else { false };
        if has_need {
            if case_insensitive_match(&chars, p, "any ") { p += 4; }
            let found = if case_insensitive_match(&chars, p, "questions") { p += 9; true }
                        else if case_insensitive_match(&chars, p, "anything else") { p += 13; true }
                        else if case_insensitive_match(&chars, p, "anything") { p += 8; true }
                        else { false };
            if found && trail_to_end(p, &chars, "?") {
                return vec![ScannerMatch::new(0, n, &chars)];
            }
        }
    }
    Vec::new()
}

// ---------------------------------------------------------------------------
// 17. EMBEDDED_USER_FACT_RE  (IGNORECASE)
//
// Python:
//   EMBEDDED_USER_FACT_RE = re.compile(
//       r"(?:^|\n).*?(?P<fact>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}[^\n]*?"
//       r"\s[—-]\s*user:\s*[^\n]+)",
//       re.IGNORECASE,
//   )
// Groups: [full_match, fact_group]
// ---------------------------------------------------------------------------

/// Scanner for EMBEDDED_USER_FACT_RE.
///
/// Python pattern: `(?:^|\n).*?(?P<fact>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}[^\n]*?\s[—-]\s*user:\s*[^\n]+)` (IGNORECASE)
///
/// Finds embedded user-fact annotations in diary-style entries.  Each
/// annotation is a line containing an ISO datetime, an em-dash or
/// hyphen after optional context, the literal "user:", and the user's
/// text.
///
/// The `(?:^|\n)` anchor and non-greedy `.*?` mean we find the
/// leftmost ISO datetime on each anchored line.  The `[^\n]*?` in
/// the fact group means we find the earliest `\s[—-]\s*user:` after
/// the datetime.
///
/// `groups[0]` = full match (includes leading `\n` or nothing for `^`)
/// `groups[1]` = `fact` group (ISO datetime through end of line)
pub fn scan_embedded_user_fact_re(text: &str) -> Vec<ScannerMatch> {
    let chars = to_chars(text);
    let n = chars.len();
    let mut results = Vec::new();

    // Collect all anchor positions: 0 (for ^) and each \n position.
    let mut anchors: Vec<usize> = vec![0];
    for (idx, &c) in chars.iter().enumerate() {
        if c == '\n' {
            anchors.push(idx);
        }
    }

    for &anchor in &anchors {
        // Determine where the line body starts (after \n) and ends.
        let line_body_start = if anchor == 0 { 0 } else { anchor + 1 };
        if line_body_start >= n {
            continue;
        }
        let line_end = chars[line_body_start..]
            .iter()
            .position(|&c| c == '\n')
            .map(|p| line_body_start + p)
            .unwrap_or(n);

        if line_body_start >= line_end {
            continue;
        }

        // Non-greedy .*?: try each position on the line for the ISO datetime,
        // starting from the leftmost.
        'dt_search: for dt_offset in 0..(line_end - line_body_start) {
            let dt_pos = line_body_start + dt_offset;
            // Must start with a digit for ISO datetime
            if !chars[dt_pos].is_ascii_digit() {
                continue;
            }
            let Some(dt_end) = try_iso_datetime_to_minutes(&chars, dt_pos) else {
                continue;
            };
            if dt_end > line_end {
                continue;
            }

            // Non-greedy [^\n]*?: find the FIRST \s[—-]\s*user: after dt_end.
            let mut search = dt_end;
            while search < line_end {
                // Look for \s immediately followed by [—-]
                if is_python_whitespace(chars[search]) && search + 1 < line_end && is_em_or_hyphen(chars[search + 1]) {
                    let after_dash = search + 2;
                    // \s* after dash
                    let mut p = after_dash;
                    while p < line_end && is_python_whitespace(chars[p]) {
                        p += 1;
                    }
                    // "user:" case-insensitive (5 chars)
                    if p + 5 <= line_end && case_insensitive_match(&chars, p, "user:") {
                        let after_user_colon = p + 5;
                        // \s* after user:
                        let mut body_start = after_user_colon;
                        while body_start < line_end && is_python_whitespace(chars[body_start]) {
                            body_start += 1;
                        }
                        // [^\n]+ — must have at least one non-newline char
                        if body_start < line_end {
                            // Match found — full match from anchor, fact from dt_pos to line_end
                            let match_start = anchor;
                            let match_end = line_end;
                            results.push(ScannerMatch::with_group(
                                match_start, match_end, &chars,
                                dt_pos, match_end,
                            ));
                            break 'dt_search;
                        }
                    }
                }
                search += 1;
            }
        }
    }
    results
}

// ---------------------------------------------------------------------------
// 18. FENCE_OPEN_RE  — 0 matches on corpus
//
// Python: re.compile(r"^\s*(`{3,}|~{3,})")
// Groups: [full_match, fence_chars]
// ---------------------------------------------------------------------------

/// Scanner for FENCE_OPEN_RE.
///
/// Python pattern: `` ^\s*(`{3,}|~{3,}) ``
///
/// Matches a code-fence opening line (3+ backticks or tildes, possibly
/// with leading whitespace).  Anchored to start of string.  0 matches
/// on the 509-row corpus.
///
/// `groups[0]` = full match; `groups[1]` = the fence character sequence.
pub fn scan_fence_open_re(text: &str) -> Vec<ScannerMatch> {
    let chars = to_chars(text);
    let mut pos = 0;
    while pos < chars.len() && is_python_whitespace(chars[pos]) { pos += 1; }
    let fence_char = if pos < chars.len() && (chars[pos] == '`' || chars[pos] == '~') {
        chars[pos]
    } else {
        return Vec::new();
    };
    let fence_start = pos;
    let mut count = 0;
    while pos < chars.len() && chars[pos] == fence_char {
        pos += 1;
        count += 1;
    }
    if count < 3 {
        return Vec::new();
    }
    let full_text: String = chars[0..pos].iter().collect();
    let group_text: String = chars[fence_start..pos].iter().collect();
    vec![ScannerMatch {
        start_cp: 0,
        end_cp: pos,
        groups: vec![Some(full_text), Some(group_text)],
    }]
}

// ---------------------------------------------------------------------------
// 19. MARKDOWN_HEADING_RE  — 0 matches on corpus
//
// Python: re.compile(r"^(?P<marks>#{1,6})\s+\S")
// Groups: [full_match, marks]
// ---------------------------------------------------------------------------

/// Scanner for MARKDOWN_HEADING_RE.
///
/// Python pattern: `^(?P<marks>#{1,6})\s+\S`
///
/// Matches a Markdown heading line starting with 1-6 `#` chars followed
/// by whitespace and at least one non-whitespace char.  Anchored to
/// start of string.  0 matches on the 509-row corpus.
///
/// `groups[0]` = full match; `groups[1]` = `marks` (the `#` chars).
pub fn scan_markdown_heading_re(text: &str) -> Vec<ScannerMatch> {
    let chars = to_chars(text);
    let mut pos = 0;
    // `^` — must be at position 0
    let mark_start = pos;
    let mut count = 0;
    while pos < chars.len() && chars[pos] == '#' && count < 6 {
        pos += 1;
        count += 1;
    }
    if count == 0 { return Vec::new(); }
    // \s+ (at least one)
    if pos >= chars.len() || !is_python_whitespace(chars[pos]) { return Vec::new(); }
    while pos < chars.len() && is_python_whitespace(chars[pos]) { pos += 1; }
    // \S (at least one non-whitespace)
    if pos >= chars.len() || is_python_whitespace(chars[pos]) { return Vec::new(); }
    pos += 1; // consume the \S char
    let full_text: String = chars[0..pos].iter().collect();
    let marks_text: String = chars[mark_start..count].iter().collect();
    vec![ScannerMatch {
        start_cp: 0,
        end_cp: pos,
        groups: vec![Some(full_text), Some(marks_text)],
    }]
}

// ---------------------------------------------------------------------------
// 20. BOLD_HEADING_RE  — 0 matches on corpus
//
// Python: re.compile(r"^\s*\*\*[^*\n]{1,120}\*\*\s*:?[ \t]*$")
// ---------------------------------------------------------------------------

/// Scanner for BOLD_HEADING_RE.
///
/// Python pattern: `^\s*\*\*[^*\n]{1,120}\*\*\s*:?[ \t]*$`
///
/// Matches a bold Markdown heading occupying an entire line.
/// 0 matches on the 509-row corpus.
///
/// No capturing groups.
pub fn scan_bold_heading_re(text: &str) -> Vec<ScannerMatch> {
    let chars = to_chars(text);
    let n = chars.len();
    let mut pos = 0;
    // \s*
    while pos < n && is_python_whitespace(chars[pos]) && chars[pos] != '\n' { pos += 1; }
    // **
    if pos + 1 >= n || chars[pos] != '*' || chars[pos + 1] != '*' { return Vec::new(); }
    pos += 2;
    // [^*\n]{1,120}
    let content_start = pos;
    let mut count = 0;
    while pos < n && chars[pos] != '*' && chars[pos] != '\n' && count < 120 {
        pos += 1; count += 1;
    }
    if count < 1 { return Vec::new(); }
    // **
    if pos + 1 >= n || chars[pos] != '*' || chars[pos + 1] != '*' { return Vec::new(); }
    pos += 2;
    // \s*
    while pos < n && is_python_whitespace(chars[pos]) && chars[pos] != '\n' { pos += 1; }
    // :?
    if pos < n && chars[pos] == ':' { pos += 1; }
    // [ \t]*
    while pos < n && (chars[pos] == ' ' || chars[pos] == '\t') { pos += 1; }
    // $ — end of string (no newline within content)
    if pos != n { return Vec::new(); }
    // Verify no \n in content
    if chars[content_start..pos].iter().any(|&c| c == '\n') { return Vec::new(); }
    vec![ScannerMatch::new(0, n, &chars)]
}

// ---------------------------------------------------------------------------
// 21. FIELD_LINE_RE
//
// Python:
//   FIELD_LINE_RE = re.compile(
//       r"^\s*[A-Za-z][A-Za-z0-9 _./()-]{0,80}:\s*\S"
//   )
//
// Anchored to ^; 329 matches on the corpus (many originals start with
// "assistant: ..." or "user: ...").
// ---------------------------------------------------------------------------

/// Scanner for FIELD_LINE_RE.
///
/// Python pattern: `^\s*[A-Za-z][A-Za-z0-9 _./()-]{0,80}:\s*\S`
///
/// Matches a field label followed by content at the start of the string.
/// 329 matches on the corpus (transcripts beginning with `assistant:`,
/// `user:`, etc.).
///
/// No capturing groups.
pub fn scan_field_line_re(text: &str) -> Vec<ScannerMatch> {
    let chars = to_chars(text);
    let n = chars.len();
    let mut pos = 0;
    // \s*
    while pos < n && is_python_whitespace(chars[pos]) { pos += 1; }
    // [A-Za-z]
    if pos >= n || !chars[pos].is_ascii_alphabetic() { return Vec::new(); }
    pos += 1;
    // [A-Za-z0-9 _./()-]{0,80}
    let mut count = 0;
    while pos < n && count < 80 && is_field_label_body(chars[pos]) {
        pos += 1;
        count += 1;
    }
    // :
    if pos >= n || chars[pos] != ':' { return Vec::new(); }
    pos += 1;
    // \s*
    while pos < n && is_python_whitespace(chars[pos]) { pos += 1; }
    // \S
    if pos >= n || is_python_whitespace(chars[pos]) { return Vec::new(); }
    pos += 1;
    vec![ScannerMatch::new(0, pos, &chars)]
}

/// True if `c` is in `[A-Za-z0-9 _./()-]` (FIELD_LINE_RE label body class).
#[inline]
fn is_field_label_body(c: char) -> bool {
    c.is_ascii_alphanumeric()
        || c == ' '
        || c == '_'
        || c == '.'
        || c == '/'
        || c == '('
        || c == ')'
        || c == '-'
}

// ---------------------------------------------------------------------------
// 22. TABLE_SEPARATOR_RE  — 0 matches on corpus
//
// Python:
//   TABLE_SEPARATOR_RE = re.compile(
//       r"^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$"
//   )
// ---------------------------------------------------------------------------

/// Scanner for TABLE_SEPARATOR_RE.
///
/// Python pattern: `^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$`
///
/// Matches a Markdown table separator row like `|---|---|`.
/// 0 matches on the 509-row corpus.
///
/// No capturing groups.
pub fn scan_table_separator_re(text: &str) -> Vec<ScannerMatch> {
    let chars = to_chars(text);
    let n = chars.len();
    let mut pos = 0;
    // \s*
    while pos < n && is_python_whitespace(chars[pos]) { pos += 1; }
    // \|?
    if pos < n && chars[pos] == '|' { pos += 1; }
    // Helper: match :?-{3,}:?\s*
    let try_cell = |mut p: usize| -> Option<usize> {
        if p < n && chars[p] == ':' { p += 1; }
        let dash_start = p;
        while p < n && chars[p] == '-' { p += 1; }
        if p - dash_start < 3 { return None; }
        if p < n && chars[p] == ':' { p += 1; }
        while p < n && is_python_whitespace(chars[p]) { p += 1; }
        Some(p)
    };
    // First cell
    while pos < n && is_python_whitespace(chars[pos]) { pos += 1; }
    pos = match try_cell(pos) { Some(p) => p, None => return Vec::new() };
    // (?:\|\s*:?-{3,}:?\s*)+ — at least one more
    let mut count = 0;
    while pos < n && chars[pos] == '|' {
        pos += 1;
        while pos < n && is_python_whitespace(chars[pos]) { pos += 1; }
        pos = match try_cell(pos) { Some(p) => p, None => return Vec::new() };
        count += 1;
    }
    if count < 1 { return Vec::new(); }
    // \|?
    if pos < n && chars[pos] == '|' { pos += 1; }
    // \s*$
    while pos < n && is_python_whitespace(chars[pos]) { pos += 1; }
    if pos != n { return Vec::new(); }
    vec![ScannerMatch::new(0, n, &chars)]
}

// ---------------------------------------------------------------------------
// 23. DIAGRAM_RE
//
// Python: re.compile(r"[─-╿]|(?:--?>|==>|<--?)")
//
// 7 matches on the corpus: all `->` in one row.
// ---------------------------------------------------------------------------

/// Scanner for DIAGRAM_RE.
///
/// Python pattern: `[─-╿]|(?:--?>|==>|<--?)`
///
/// Two alternatives:
/// 1. Box-drawing characters U+2500–U+257F.
/// 2. ASCII arrow sequences: `->`, `-->`, `==>`, `<-`, `<--`.
///
/// Note: `--?>` = `-` + `-?` + `>` = `->` or `-->`.
/// `<--?` = `<` + `--?` = `<-` or `<--`.
///
/// No capturing groups.
pub fn scan_diagram_re(text: &str) -> Vec<ScannerMatch> {
    let chars = to_chars(text);
    let mut results = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        // Alternative 1: box-drawing U+2500–U+257F
        if c >= '\u{2500}' && c <= '\u{257f}' {
            results.push(ScannerMatch::new(i, i + 1, &chars));
            i += 1;
            continue;
        }
        // Alternative 2: arrow sequences
        // `->` or `-->`
        if c == '-' {
            if i + 1 < chars.len() && chars[i + 1] == '>' {
                results.push(ScannerMatch::new(i, i + 2, &chars));
                i += 2;
                continue;
            }
            if i + 2 < chars.len() && chars[i + 1] == '-' && chars[i + 2] == '>' {
                results.push(ScannerMatch::new(i, i + 3, &chars));
                i += 3;
                continue;
            }
        }
        // `==>`
        if c == '=' && i + 2 < chars.len() && chars[i + 1] == '=' && chars[i + 2] == '>' {
            results.push(ScannerMatch::new(i, i + 3, &chars));
            i += 3;
            continue;
        }
        // `<-` or `<--`
        if c == '<' {
            if i + 1 < chars.len() && chars[i + 1] == '-' {
                if i + 2 < chars.len() && chars[i + 2] == '-' {
                    results.push(ScannerMatch::new(i, i + 3, &chars));
                    i += 3;
                } else {
                    results.push(ScannerMatch::new(i, i + 2, &chars));
                    i += 2;
                }
                continue;
            }
        }
        i += 1;
    }
    results
}

// ---------------------------------------------------------------------------
// 24. POLARITY_ONLY_RE  (IGNORECASE)  — 0 matches on corpus
//
// Python: re.compile(r"^\s*(?:yes|no)\b[.!?\s]*$", re.IGNORECASE)
// ---------------------------------------------------------------------------

/// Scanner for POLARITY_ONLY_RE.
///
/// Python pattern: `^\s*(?:yes|no)\b[.!?\s]*$` (IGNORECASE)
///
/// Matches strings that are only "yes" or "no" (with optional punctuation).
/// 0 matches on the 509-row corpus.
///
/// No capturing groups.
pub fn scan_polarity_only_re(text: &str) -> Vec<ScannerMatch> {
    let chars = to_chars(text);
    let n = chars.len();
    let mut pos = 0;
    while pos < n && is_python_whitespace(chars[pos]) { pos += 1; }
    let word_len = if case_insensitive_match(&chars, pos, "yes") { 3 }
                   else if case_insensitive_match(&chars, pos, "no") { 2 }
                   else { return Vec::new(); };
    let word_end = pos + word_len;
    // \b after "yes"/"no"
    if !word_boundary_at(&chars, word_end) { return Vec::new(); }
    let mut end = word_end;
    while end < n && (chars[end] == '.' || chars[end] == '!' || chars[end] == '?' || is_python_whitespace(chars[end])) {
        end += 1;
    }
    if end != n { return Vec::new(); }
    vec![ScannerMatch::new(0, n, &chars)]
}

// ---------------------------------------------------------------------------
// 25. TRANSFORM_FOLLOWUP_RE  (IGNORECASE)
//
// Python:
//   TRANSFORM_FOLLOWUP_RE = re.compile(
//       r"\b(?:adapt|convert|make|port|rewrite|translate|turn)\b[^\n]{0,120}"
//       r"\b(?:answer|code|example|function|it|that|this)\b|"
//       r"\b(?:answer|code|example|function|it|that|this)\b[^\n]{0,120}"
//       r"\b(?:adapt|convert|make|port|rewrite|translate|turn)\b",
//       re.IGNORECASE,
//   )
// ---------------------------------------------------------------------------

/// Scanner for TRANSFORM_FOLLOWUP_RE.
///
/// Python pattern (alternation, IGNORECASE):
/// Alt 1: `\b(transform_word)\b[^\n]{0,120}\b(target_word)\b`
/// Alt 2: `\b(target_word)\b[^\n]{0,120}\b(transform_word)\b`
///
/// Matches text where a "transform" verb (adapt, convert, make, port,
/// rewrite, translate, turn) and a "target" noun (answer, code, example,
/// function, it, that, this) appear within 120 non-newline characters of
/// each other.
///
/// Python tries Alt 1 first at each position; if it fails, tries Alt 2.
/// Non-overlapping finditer advances past each match.
///
/// 506 matches across 240 rows in the corpus.
///
/// No capturing groups.
pub fn scan_transform_followup_re(text: &str) -> Vec<ScannerMatch> {
    const TRANSFORM_WORDS: &[&str] = &[
        "translate", "rewrite", "convert", "adapt", "turn", "make", "port",
    ];
    const TARGET_WORDS: &[&str] = &[
        "function", "example", "answer", "that", "code", "this", "it",
    ];

    let chars = to_chars(text);
    let n = chars.len();
    let mut results = Vec::new();
    let mut pos = 0;

    while pos < n {
        // Alt 1: transform word at pos → ≤120 non-newline chars → target word
        if let Some(m) = try_transform_pair(&chars, pos, TRANSFORM_WORDS, TARGET_WORDS) {
            results.push(m);
            pos = results.last().unwrap().end_cp;
            continue;
        }
        // Alt 2: target word at pos → ≤120 non-newline chars → transform word
        if let Some(m) = try_transform_pair(&chars, pos, TARGET_WORDS, TRANSFORM_WORDS) {
            results.push(m);
            pos = results.last().unwrap().end_cp;
            continue;
        }
        pos += 1;
    }
    results
}

/// Try to match `\b(word_a)\b[^\n]{0,120}\b(word_b)\b` starting at `pos`.
///
/// Returns the ScannerMatch if `chars[pos..]` starts with a word in
/// `set_a` at a word boundary and a word in `set_b` is found within 120
/// non-newline characters after set_a's end (also at a word boundary).
fn try_transform_pair(
    chars: &[char],
    pos: usize,
    set_a: &[&str],
    set_b: &[&str],
) -> Option<ScannerMatch> {
    // \b before pos
    if !word_boundary_at(chars, pos) {
        return None;
    }
    // Match one word from set_a at pos
    let a_word = set_a.iter().find(|&&w| {
        case_insensitive_match(chars, pos, w)
            && word_boundary_at(chars, pos + w.chars().count())
    })?;
    let a_end = pos + a_word.chars().count();

    // Scan [^\n]{0,120} for ALL words from set_b; pick the RIGHTMOST one.
    // Python's greedy `[^\n]{0,120}` means the engine tries to consume 120
    // chars first, then backtracks — so the winning set_b word is the LAST
    // one within the 120-char non-newline window.
    // [^\n]{0,120} allows up to 120 chars BETWEEN the two keywords.
    // scan checks from a_end (0 middle chars) through a_end+120 (120 middle chars),
    // so we need scan to reach a_end+120 — which requires max_scan = a_end+121.
    let max_scan = (a_end + 121).min(chars.len());
    let mut last_match: Option<ScannerMatch> = None;
    let mut scan = a_end;
    while scan < max_scan {
        if chars[scan] == '\n' {
            break; // [^\n] — newline terminates the window
        }
        if word_boundary_at(chars, scan) {
            for &b_word in set_b {
                let b_len = b_word.chars().count();
                if scan + b_len <= chars.len()
                    && case_insensitive_match(chars, scan, b_word)
                    && word_boundary_at(chars, scan + b_len)
                {
                    let match_end = scan + b_len;
                    let matched: String = chars[pos..match_end].iter().collect();
                    // Keep going — rightmost candidate wins (greedy semantics).
                    last_match = Some(ScannerMatch {
                        start_cp: pos,
                        end_cp: match_end,
                        groups: vec![Some(matched)],
                    });
                }
            }
        }
        scan += 1;
    }
    last_match
}

// ---------------------------------------------------------------------------
// 26. QUANTITY_VALUE_RE  — 0 matches on corpus
//
// Python:
//   QUANTITY_VALUE_RE = re.compile(
//       r"^[€£$]?\d+(?:[.,]\d+)?(?:\s+[A-Za-z%][A-Za-z0-9%._/-]*){0,3}$"
//   )
// ---------------------------------------------------------------------------

/// Scanner for QUANTITY_VALUE_RE.
///
/// Python pattern: `^[€£$]?\d+(?:[.,]\d+)?(?:\s+[A-Za-z%][A-Za-z0-9%._/-]*){0,3}$`
///
/// Matches a quantity-value string like "42", "$3.50", "100 USD", "5 kg/m2".
/// Anchored to full string (`^...$`).  0 matches on the 509-row corpus.
///
/// No capturing groups.
pub fn scan_quantity_value_re(text: &str) -> Vec<ScannerMatch> {
    let chars = to_chars(text);
    let n = chars.len();
    if n == 0 { return Vec::new(); }
    let mut pos = 0;
    // [€£$]?
    if chars[pos] == '\u{20AC}' || chars[pos] == '\u{00A3}' || chars[pos] == '$' {
        pos += 1;
    }
    // \d+ (at least one)
    if pos >= n || !chars[pos].is_ascii_digit() { return Vec::new(); }
    while pos < n && chars[pos].is_ascii_digit() { pos += 1; }
    // (?:[.,]\d+)?
    if pos < n && (chars[pos] == ',' || chars[pos] == '.') {
        if pos + 1 < n && chars[pos + 1].is_ascii_digit() {
            pos += 1;
            while pos < n && chars[pos].is_ascii_digit() { pos += 1; }
        }
    }
    // (?:\s+[A-Za-z%][A-Za-z0-9%._/-]*){0,3}
    for _ in 0..3 {
        if pos >= n || !is_python_whitespace(chars[pos]) { break; }
        let ws_start = pos;
        while pos < n && is_python_whitespace(chars[pos]) { pos += 1; }
        // [A-Za-z%]
        if pos >= n || (!chars[pos].is_ascii_alphabetic() && chars[pos] != '%') {
            pos = ws_start; // revert
            break;
        }
        pos += 1;
        // [A-Za-z0-9%._/-]*
        while pos < n && is_unit_body(chars[pos]) { pos += 1; }
    }
    // $
    if pos != n { return Vec::new(); }
    vec![ScannerMatch::new(0, n, &chars)]
}

/// True if `c` is in `[A-Za-z0-9%._/-]` (QUANTITY_VALUE_RE unit body).
#[inline]
fn is_unit_body(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '%' || c == '.' || c == '_' || c == '/' || c == '-'
}

// ---------------------------------------------------------------------------
// Convenience: dispatch by pattern name
// ---------------------------------------------------------------------------

/// Run the scanner for the named pattern and return all matches.
///
/// `name` must be one of the 26 pattern constants from
/// `distill_plus_converter.py`.  Returns `None` if the name is
/// unrecognised.
pub fn scan_by_name(name: &str, text: &str) -> Option<Vec<ScannerMatch>> {
    Some(match name {
        "TRAILER_RE"               => scan_trailer_re(text),
        "PIPE_SPLIT_RE"            => scan_pipe_split_re(text),
        "INLINE_NUMBERED_RE"       => scan_inline_numbered_re(text),
        "LIST_MARKER_RE"           => scan_list_marker_re(text),
        "WORD_RE"                  => scan_word_re(text),
        "NUMBER_RE"                => scan_number_re(text),
        "DATE_RE"                  => scan_date_re(text),
        "CAPITALIZED_RE"           => scan_capitalized_re(text),
        "GREETING_PREFIX_RE"       => scan_greeting_prefix_re(text),
        "GREETING_ONLY_RE"         => scan_greeting_only_re(text),
        "DIALOGUE_FILLER_ONLY_RE"  => scan_dialogue_filler_only_re(text),
        "REVISION_MARKER_RE"       => scan_revision_marker_re(text),
        "INITIAL_DRAFT_MARKER_RE"  => scan_initial_draft_marker_re(text),
        "OPERATIVE_RE"             => scan_operative_re(text),
        "TURN_FILLER_RE"           => scan_turn_filler_re(text),
        "ASSISTANT_BOILERPLATE_RE" => scan_assistant_boilerplate_re(text),
        "EMBEDDED_USER_FACT_RE"    => scan_embedded_user_fact_re(text),
        "FENCE_OPEN_RE"            => scan_fence_open_re(text),
        "MARKDOWN_HEADING_RE"      => scan_markdown_heading_re(text),
        "BOLD_HEADING_RE"          => scan_bold_heading_re(text),
        "FIELD_LINE_RE"            => scan_field_line_re(text),
        "TABLE_SEPARATOR_RE"       => scan_table_separator_re(text),
        "DIAGRAM_RE"               => scan_diagram_re(text),
        "POLARITY_ONLY_RE"         => scan_polarity_only_re(text),
        "TRANSFORM_FOLLOWUP_RE"    => scan_transform_followup_re(text),
        "QUANTITY_VALUE_RE"        => scan_quantity_value_re(text),
        _                          => return None,
    })
}
