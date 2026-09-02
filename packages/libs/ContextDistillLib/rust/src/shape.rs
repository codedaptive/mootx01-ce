//! Record-shape classification — Rust port of record_shape_classifier.py.
//!
//! Deterministic, content-only structural classification with no ML
//! runtime. All decisions use integer counts and percentages so this
//! port produces bit-identical results to the Python oracle for every
//! input in the conformance vector set.
//!
//! ## No regex engines
//! The six regex constants from the Python source are replaced with
//! hand-written scanners that mirror Python Unicode semantics:
//!   - `\s`  → `char::is_whitespace()` (Python's `str.strip` set)
//!   - `\b`  → ASCII word-char boundary: `[A-Za-z0-9_]`
//!   - `\d`  → ASCII digit: `char::is_ascii_digit()`
//!   - IGNORECASE → `str::to_lowercase()` before keyword matching
//!
//! Python `str` index unit is Unicode code points; Rust mirrors this via
//! `str::chars()` (Unicode scalar values, equal to code points for valid
//! UTF-8 excluding surrogates).
//!
//! Python integer division `//` floors toward negative infinity. For the
//! strictly non-negative numerators and denominators in this module,
//! Python `//` equals Rust `/` (truncates toward zero). All divisions
//! here use that equivalence explicitly.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Known-speaker set — mirrors Python's KNOWN_SPEAKERS set literal.
// ---------------------------------------------------------------------------

/// Known speaker tag names, all lowercase.
/// Mirrors Python:
///   KNOWN_SPEAKERS = {"user", "assistant", "human", "system", "customer",
///                     "agent", "interviewer", "interviewee", "speaker",
///                     "participant"}
pub(crate) const KNOWN_SPEAKERS: &[&str] = &[
    "user",
    "assistant",
    "human",
    "system",
    "customer",
    "agent",
    "interviewer",
    "interviewee",
    "speaker",
    "participant",
];

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Structural classification with auditable evidence.
///
/// Mirrors Python's `ShapeDecision` frozen dataclass from
/// `record_shape_classifier.py`. Fields serialise with the exact key names
/// the oracle produces so `serde_json::to_value` can be compared to the
/// oracle "shape" field directly.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ShapeDecision {
    /// Primary shape label.
    pub primary: String,

    /// All active shape labels, sorted by score descending then
    /// alphabetically ascending. Serialises as a JSON array.
    pub labels: Vec<String>,

    /// Raw scores for each of the five shape dimensions.
    pub scores: HashMap<String, i32>,

    /// Observable document topology features — integer counts and
    /// percentages — used to derive the scores.
    pub features: HashMap<String, i64>,

    /// Difference between the top-ranked score and the second-ranked
    /// score. Zero means two shape dimensions tied at the top.
    pub confidence_margin: i32,
}

// ---------------------------------------------------------------------------
// Low-level helper: word character test
// ---------------------------------------------------------------------------

/// True if `c` is a regex word character: `[A-Za-z0-9_]`.
/// Python's `\b` uses this definition.
#[inline]
fn is_word_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

/// After a pattern whose last matched character is at `chars[pos - 1]`
/// (always a digit in our patterns), return true if `\b` holds at `pos`.
///
/// Since the preceding character is a digit (word char), `\b` holds iff
/// the next character (at `pos`) is non-word or we are at end of string.
#[inline]
fn word_boundary_after_digit(chars: &[char], pos: usize) -> bool {
    pos >= chars.len() || !is_word_char(chars[pos])
}

// ---------------------------------------------------------------------------
// Scanner: try_n_digits — match exactly n ASCII digits
// ---------------------------------------------------------------------------

/// Match exactly `n` ASCII digits starting at `chars[i]`.
/// Returns `Some(i + n)` if all `n` chars are digits, else `None`.
fn try_n_digits(chars: &[char], i: usize, n: usize) -> Option<usize> {
    if i + n > chars.len() {
        return None;
    }
    for j in 0..n {
        if !chars[i + j].is_ascii_digit() {
            return None;
        }
    }
    Some(i + n)
}

/// Match `min..=max` ASCII digits starting at `chars[i]` greedily.
/// Returns `Some(end)` if at least `min` digits matched, else `None`.
fn try_digits_range(chars: &[char], i: usize, min: usize, max: usize) -> Option<usize> {
    let mut count = 0;
    while i + count < chars.len() && chars[i + count].is_ascii_digit() && count < max {
        count += 1;
    }
    if count >= min {
        Some(i + count)
    } else {
        None
    }
}

// ---------------------------------------------------------------------------
// Scanner: ISO date — mirrors first alternative of DATE_LEAD / DATE_ANY
//   \d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?)?
// ---------------------------------------------------------------------------

/// Try to match an ISO date (with optional time suffix) starting at `chars[i]`.
///
/// Mirrors the first alternative of Python's DATE_LEAD and DATE_ANY patterns:
///   `\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?)?`
///
/// Returns `Some(end_pos)` if the date matched. The optional T-time suffix
/// is consumed when present.
fn try_iso_date(chars: &[char], i: usize) -> Option<usize> {
    let mut pos = i;
    // \d{4}
    pos = try_n_digits(chars, pos, 4)?;
    // '-'
    if pos >= chars.len() || chars[pos] != '-' {
        return None;
    }
    pos += 1;
    // \d{2}
    pos = try_n_digits(chars, pos, 2)?;
    // '-'
    if pos >= chars.len() || chars[pos] != '-' {
        return None;
    }
    pos += 1;
    // \d{2}
    pos = try_n_digits(chars, pos, 2)?;
    // Optional: T\d{2}:\d{2}(?::\d{2})?
    if pos < chars.len() && chars[pos] == 'T' {
        let next = pos + 1;
        if let Some(h_end) = try_n_digits(chars, next, 2) {
            if h_end < chars.len() && chars[h_end] == ':' {
                if let Some(m_end) = try_n_digits(chars, h_end + 1, 2) {
                    // Hour and minute matched — update pos
                    pos = m_end;
                    // Optional: :\d{2}
                    if pos < chars.len() && chars[pos] == ':' {
                        if let Some(s_end) = try_n_digits(chars, pos + 1, 2) {
                            pos = s_end;
                        }
                    }
                }
            }
        }
        // If T is followed by malformed time, fall through with pos still at
        // the date-only end (Python regex would not consume the malformed T).
    }
    Some(pos)
}

// ---------------------------------------------------------------------------
// Scanner: short date — mirrors second alternative of DATE_LEAD / DATE_ANY
//   \d{1,2}[/-]\d{1,2}[/-]\d{2,4}
// ---------------------------------------------------------------------------

/// Try to match a short date starting at `chars[i]`.
///
/// Mirrors the second alternative of Python's DATE_LEAD and DATE_ANY:
///   `\d{1,2}[/-]\d{1,2}[/-]\d{2,4}`
///
/// Returns `Some(end_pos)` if matched.
fn try_short_date(chars: &[char], i: usize) -> Option<usize> {
    let mut pos = i;
    // \d{1,2} — greedy
    pos = try_digits_range(chars, pos, 1, 2)?;
    // [/-]
    if pos >= chars.len() || (chars[pos] != '/' && chars[pos] != '-') {
        return None;
    }
    pos += 1;
    // \d{1,2}
    pos = try_digits_range(chars, pos, 1, 2)?;
    // [/-]
    if pos >= chars.len() || (chars[pos] != '/' && chars[pos] != '-') {
        return None;
    }
    pos += 1;
    // \d{2,4}
    pos = try_digits_range(chars, pos, 2, 4)?;
    Some(pos)
}

// ---------------------------------------------------------------------------
// Scanner: TAG_LINE
//   ^\s*([A-Za-z][A-Za-z0-9_ -]{0,23}):\s*(.*)$
// ---------------------------------------------------------------------------

/// Try to match a tag-line at the start of `line`.
///
/// Mirrors Python's TAG_LINE regex:
///   `^\s*([A-Za-z][A-Za-z0-9_ -]{0,23}):\s*(.*)$`
///
/// Returns `Some(tag_lowercase)` where `tag_lowercase` is
/// `match.group(1).strip().lower()`, i.e., the tag name stripped of
/// trailing whitespace and lowercased. Returns `None` if the line does
/// not match.
///
/// Python semantics divergence: Python's `$` matches before a trailing `\n`
/// at end of string. Since we operate on individual lines (post-splitlines),
/// this has no practical effect.
pub(crate) fn scan_tag_line(line: &str) -> Option<String> {
    let chars: Vec<char> = line.chars().collect();
    let n = chars.len();
    let mut i = 0;

    // Skip leading \s*
    while i < n && chars[i].is_whitespace() {
        i += 1;
    }

    // First character must be [A-Za-z]
    if i >= n || !chars[i].is_ascii_alphabetic() {
        return None;
    }
    let tag_start = i;
    i += 1;

    // 0..=23 more characters of [A-Za-z0-9_ -]
    // Loop while total tag length (from tag_start) < 24 chars.
    while i < n && (i - tag_start) < 24 {
        let c = chars[i];
        if c.is_ascii_alphanumeric() || c == '_' || c == ' ' || c == '-' {
            i += 1;
        } else {
            break;
        }
    }

    // Must be followed by ':'
    if i >= n || chars[i] != ':' {
        return None;
    }
    let tag_end = i; // exclusive end of tag name, points at ':'

    // Build tag string, strip (remove trailing spaces allowed by [_ -]),
    // and lowercase — mirrors Python's match.group(1).strip().lower()
    let tag: String = chars[tag_start..tag_end].iter().collect();
    Some(tag.trim().to_lowercase())
}

/// Full tag-line match: returns `(speaker_lowercase, body_cp_offset)` where
/// `body_cp_offset` is the code-point index of group 2 start (`match.start(2)`)
/// within `line`.  Mirrors Python `_known_speaker(line)` companion logic:
///   `return speaker, match.start(2)`.
///
/// `TAG_LINE = re.compile(r"^\s*([A-Za-z][A-Za-z0-9_ -]{0,23}):\s*(.*)$")`
/// Group 2 starts after the colon and any following whitespace.
pub(crate) fn scan_tag_line_with_body(line: &str) -> Option<(String, usize)> {
    let chars: Vec<char> = line.chars().collect();
    let n = chars.len();
    let mut i = 0;

    // Skip ^\s*
    while i < n && chars[i].is_whitespace() {
        i += 1;
    }
    if i >= n || !chars[i].is_ascii_alphabetic() {
        return None;
    }
    let tag_start = i;
    i += 1;
    while i < n && (i - tag_start) < 24 {
        let c = chars[i];
        if c.is_ascii_alphanumeric() || c == '_' || c == ' ' || c == '-' {
            i += 1;
        } else {
            break;
        }
    }
    if i >= n || chars[i] != ':' {
        return None;
    }
    let tag_end = i;
    i += 1; // skip ':'

    // Skip \s* after colon — these are the whitespace chars in `:\s*`.
    while i < n && chars[i].is_whitespace() {
        i += 1;
    }
    // i is now the code-point offset of group 2 start (match.start(2)).
    let body_cp = i;

    let tag: String = chars[tag_start..tag_end].iter().collect();
    Some((tag.trim().to_lowercase(), body_cp))
}

// ---------------------------------------------------------------------------
// Scanner: DATE_LEAD
//   ^\s*(?:\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?)?
//         |\d{1,2}[/-]\d{1,2}[/-]\d{2,4})\b
// ---------------------------------------------------------------------------

/// Return true if `line` starts with optional whitespace then a date.
///
/// Mirrors Python's DATE_LEAD regex used in `record_shape_classifier.py`.
/// Alternation order matches Python (ISO first, short date second).
/// The `\b` word-boundary after the date is checked on both alternatives.
pub(crate) fn scan_date_lead(line: &str) -> bool {
    let chars: Vec<char> = line.chars().collect();
    let n = chars.len();
    let mut i = 0;

    // Skip ^\s*
    while i < n && chars[i].is_whitespace() {
        i += 1;
    }

    // Try ISO date first (Python left-to-right alternation)
    if let Some(end) = try_iso_date(&chars, i) {
        if word_boundary_after_digit(&chars, end) {
            return true;
        }
    }

    // Try short date
    if let Some(end) = try_short_date(&chars, i) {
        if word_boundary_after_digit(&chars, end) {
            return true;
        }
    }

    false
}

// ---------------------------------------------------------------------------
// Scanner: BULLET_LEAD
//   ^\s*(?:[-*+]\s+|\d+[.)]\s+)
// ---------------------------------------------------------------------------

/// Return true if `line` starts with a list bullet or numbered item.
///
/// Mirrors Python's BULLET_LEAD regex:
///   `^\s*(?:[-*+]\s+|\d+[.)]\s+)`
///
/// Note: `\s+` requires at least one whitespace character after the marker.
pub(crate) fn scan_bullet_lead(line: &str) -> bool {
    let chars: Vec<char> = line.chars().collect();
    let n = chars.len();
    let mut i = 0;

    // Skip \s*
    while i < n && chars[i].is_whitespace() {
        i += 1;
    }
    if i >= n {
        return false;
    }

    // Alternative 1: [-*+]\s+
    if chars[i] == '-' || chars[i] == '*' || chars[i] == '+' {
        return i + 1 < n && chars[i + 1].is_whitespace();
    }

    // Alternative 2: \d+[.)]\s+
    if chars[i].is_ascii_digit() {
        let mut j = i;
        while j < n && chars[j].is_ascii_digit() {
            j += 1;
        }
        if j > i && j < n && (chars[j] == '.' || chars[j] == ')') {
            return j + 1 < n && chars[j + 1].is_whitespace();
        }
    }

    false
}

// ---------------------------------------------------------------------------
// Scanner: HEADING_LEAD  (IGNORECASE)
//   ^\s*(?:chapter|section|part|act|scene|title|book summary)\b
// ---------------------------------------------------------------------------

/// Return true if `line` starts with a document-heading keyword.
///
/// Mirrors Python's HEADING_LEAD regex with `re.IGNORECASE`:
///   `^\s*(?:chapter|section|part|act|scene|title|book summary)\b`
///
/// Case-insensitive matching is implemented by lowercasing the
/// trimmed line prefix before comparison. Python divergence: Python
/// `to_lowercase()` on Unicode chars may produce multi-byte sequences
/// for non-ASCII letters (e.g., `İ`). In practice the heading keywords
/// are English ASCII, so the lowercase comparison is exact.
pub(crate) fn scan_heading_lead(line: &str) -> bool {
    const KEYWORDS: &[&str] = &[
        "chapter",
        "section",
        "part",
        "act",
        "scene",
        "title",
        "book summary",
    ];

    // Lowercase the whole line for case-insensitive comparison.
    let lower = line.to_lowercase();
    // trim_start mirrors ^\s* — Python \s includes all Unicode whitespace.
    let trimmed = lower.trim_start();

    for keyword in KEYWORDS {
        if trimmed.starts_with(keyword) {
            // Check \b: character immediately after keyword must be non-word
            // or we're at end of string. `keyword.len()` is safe to use as
            // a byte offset because all keywords are ASCII (no multi-byte chars).
            let after = &trimmed[keyword.len()..];
            match after.chars().next() {
                None => return true,                          // end of string
                Some(c) if !is_word_char(c) => return true,  // non-word char
                _ => {}                                        // word char: no boundary
            }
        }
    }
    false
}

// ---------------------------------------------------------------------------
// Scanner: pipe split
//   re.split(r"\s+\|\s+", content)
// ---------------------------------------------------------------------------

/// Split `content` on `\s+\|\s+` (whitespace-pipe-whitespace) and return
/// all non-empty (after strip) parts.
///
/// Mirrors Python:
///   `[part for part in re.split(r"\s+\|\s+", content) if part.strip()]`
///
/// If no delimiter is found, the entire content is the single part. This
/// means `pipe_parts >= 1` for all non-empty content — matching the oracle
/// observation that all 509 rows have `pipe_parts >= 1`.
fn split_pipe_parts(content: &str) -> Vec<&str> {
    // Collect (byte_offset, char) pairs for delimiter scanning.
    let indexed: Vec<(usize, char)> = content.char_indices().collect();
    let n = indexed.len();
    let mut result: Vec<&str> = Vec::new();
    let mut part_start_byte: usize = 0;
    let mut i = 0;

    while i < n {
        // Check for delimiter start: requires at least one whitespace
        if indexed[i].1.is_whitespace() {
            let delim_start_byte = indexed[i].0;
            let mut j = i;
            // Consume \s+
            while j < n && indexed[j].1.is_whitespace() {
                j += 1;
            }
            // Need '|'
            if j < n && indexed[j].1 == '|' {
                let after_pipe = j + 1;
                // Need at least one \s after '|'
                if after_pipe < n && indexed[after_pipe].1.is_whitespace() {
                    let mut k = after_pipe;
                    while k < n && indexed[k].1.is_whitespace() {
                        k += 1;
                    }
                    // Delimiter found: indexed[i..j] is \s+, indexed[j] is |,
                    // indexed[after_pipe..k] is \s+. The next part starts at k.
                    let part = &content[part_start_byte..delim_start_byte];
                    result.push(part);
                    part_start_byte = if k < n { indexed[k].0 } else { content.len() };
                    i = k;
                    continue;
                }
            }
        }
        i += 1;
    }
    // Last (or only) part
    result.push(&content[part_start_byte..]);

    // Filter: keep only parts that are non-empty after strip
    result
        .into_iter()
        .filter(|p| !p.trim().is_empty())
        .collect()
}

// ---------------------------------------------------------------------------
// Counter: DATE_ANY
//   \b(?:\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?)?
//       |\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\d{4})\b
// ---------------------------------------------------------------------------

/// Count non-overlapping DATE_ANY matches in `content`.
///
/// Mirrors Python's `len(DATE_ANY.findall(content))` where:
///   `DATE_ANY = re.compile(r"\b(?:\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}
///       (?::\d{2})?)?|\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\d{4})\b")`
///
/// Alternation order is preserved (Python left-to-right: ISO first,
/// short date second, bare year third). When an alternative matches
/// but `\b` fails, the next alternative is tried at the same position —
/// mirroring Python regex backtracking through alternation.
fn count_date_any(content: &str) -> i64 {
    let chars: Vec<char> = content.chars().collect();
    let n = chars.len();
    let mut count: i64 = 0;
    let mut i = 0;

    while i < n {
        // Require \b at position i: preceding char is non-word (or start)
        // AND current char is a digit (word char).
        let left_is_word = i > 0 && is_word_char(chars[i - 1]);
        if !left_is_word && chars[i].is_ascii_digit() {
            let mut advanced = false;

            // Alt 1: ISO date
            if let Some(end) = try_iso_date(&chars, i) {
                if word_boundary_after_digit(&chars, end) {
                    count += 1;
                    i = end;
                    advanced = true;
                }
            }

            // Alt 2: short date (only if alt 1 didn't produce a match)
            if !advanced {
                if let Some(end) = try_short_date(&chars, i) {
                    if word_boundary_after_digit(&chars, end) {
                        count += 1;
                        i = end;
                        advanced = true;
                    }
                }
            }

            // Alt 3: bare four-digit year \d{4}
            if !advanced {
                if let Some(end) = try_n_digits(&chars, i, 4) {
                    if word_boundary_after_digit(&chars, end) {
                        count += 1;
                        i = end;
                        advanced = true;
                    }
                }
            }

            if !advanced {
                i += 1;
            }
        } else {
            i += 1;
        }
    }
    count
}

// ---------------------------------------------------------------------------
// Counter: NUMBER_ANY
//   \b\d+(?:[.,]\d+)?\b
// ---------------------------------------------------------------------------

/// Count non-overlapping NUMBER_ANY matches in `content`.
///
/// Mirrors Python's `len(NUMBER_ANY.findall(content))` where:
///   `NUMBER_ANY = re.compile(r"\b\d+(?:[.,]\d+)?\b")`
///
/// Python's regex engine backtracks the optional `(?:[.,]\d+)?` when
/// consuming it would leave no valid `\b` at the end of the match. For
/// example, `£183.39m` — `\d+` matches `183`, the optional `.39` is
/// consumed, then `\b` at `m` fails (both `9` and `m` are word chars).
/// Python backtracks and matches just `183` with `\b` at `.`. This
/// function replicates that behaviour by checking the optional-end
/// boundary first and falling back to the no-optional boundary if needed.
fn count_number_any(content: &str) -> i64 {
    let chars: Vec<char> = content.chars().collect();
    let n = chars.len();
    let mut count: i64 = 0;
    let mut i = 0;

    while i < n {
        // \b before: left is non-word (or start) AND current is digit
        let left_is_word = i > 0 && is_word_char(chars[i - 1]);
        if !left_is_word && chars[i].is_ascii_digit() {
            // Match \d+ greedily
            let mut end = i + 1;
            while end < n && chars[end].is_ascii_digit() {
                end += 1;
            }
            let end_without_optional = end;

            // Try optional [.,]\d+ — mirrors Python's `(?:[.,]\d+)?`
            let opt_end = if end < n && (chars[end] == ',' || chars[end] == '.') {
                let after_sep = end + 1;
                if after_sep < n && chars[after_sep].is_ascii_digit() {
                    let mut e = after_sep + 1;
                    while e < n && chars[e].is_ascii_digit() {
                        e += 1;
                    }
                    Some(e)
                } else {
                    None
                }
            } else {
                None
            };

            // Check \b with optional part first (longest match, mirrors greedy)
            if let Some(oe) = opt_end {
                if word_boundary_after_digit(&chars, oe) {
                    count += 1;
                    i = oe;
                    continue;
                }
                // Optional part present but \b failed at opt_end —
                // fall through to try without the optional part.
                // This mirrors Python's backtracking of (?:[.,]\d+)?.
            }

            // Try without optional part
            if word_boundary_after_digit(&chars, end_without_optional) {
                count += 1;
                i = end_without_optional;
            } else {
                i += 1;
            }
        } else {
            i += 1;
        }
    }
    count
}

// ---------------------------------------------------------------------------
// Counter: EMAIL
//   \b[^\s@]+@[^\s@]+\.[^\s@]+\b
// ---------------------------------------------------------------------------

/// Count non-overlapping EMAIL matches in `content`.
///
/// Mirrors Python's `len(EMAIL.findall(content))` where:
///   `EMAIL = re.compile(r"\b[^\s@]+@[^\s@]+\.[^\s@]+\b")`
///
/// Implementation strategy: scan for `@` characters, then match
/// outward — backward for the local part, forward for the domain.
///
/// The domain is scanned greedily (all `[^\s@]` chars), then an
/// `effective_end` is located: the rightmost position within the
/// greedy scan where `\b` holds. This mirrors Python's backtracking
/// behaviour on `[^\s@]+\b` — for example, when a domain like
/// `chicagohealthpartners.com` is followed by a sentence period `.`,
/// the greedy scan includes the period, but `\b` fails there (both
/// sides are non-word: `.` and `\n`). Python backtracks to `com`,
/// where `\b` succeeds (word char `m`, non-word char `.`). The
/// `effective_end` captures this without requiring a full backtracker.
///
/// Python semantics divergence: Python's `\b` is standard ASCII
/// word-boundary (`[A-Za-z0-9_]`). We use the same `is_word_char`
/// definition throughout.
fn count_email(content: &str) -> i64 {
    let chars: Vec<char> = content.chars().collect();
    let n = chars.len();
    let mut count: i64 = 0;
    let mut i = 0;

    while i < n {
        if chars[i] == '@' {
            let at_pos = i;

            // Scan backward: local part [^\s@]+
            // Must have at least one non-whitespace, non-@ char before '@'.
            if at_pos == 0 {
                i += 1;
                continue;
            }
            let mut local_start = at_pos;
            while local_start > 0
                && !chars[local_start - 1].is_whitespace()
                && chars[local_start - 1] != '@'
            {
                local_start -= 1;
            }
            if local_start == at_pos {
                // No local part chars found
                i += 1;
                continue;
            }

            // Check \b at local_start:
            // \b requires one side word and the other non-word.
            let prev_is_word = local_start > 0 && is_word_char(chars[local_start - 1]);
            let first_local_is_word = is_word_char(chars[local_start]);
            if prev_is_word == first_local_is_word {
                // No word boundary — not a valid match start
                i += 1;
                continue;
            }

            // Scan forward: domain [^\s@]+  (greedy)
            let domain_start = at_pos + 1;
            if domain_start >= n {
                i += 1;
                continue;
            }
            let mut domain_end = domain_start;
            while domain_end < n
                && !chars[domain_end].is_whitespace()
                && chars[domain_end] != '@'
            {
                domain_end += 1;
            }
            if domain_end == domain_start {
                i += 1;
                continue;
            }

            // effective_end: rightmost position p in (domain_start..=domain_end)
            // where \b holds, i.e. chars[p-1] and chars[p] differ in word status.
            // Scanning from right to left mirrors Python's greedy backtrack.
            // End-of-string (p == n) is treated as non-word, matching regex semantics.
            let effective_end = (domain_start + 1..=domain_end).rev().find(|&p| {
                let prev_is_word = is_word_char(chars[p - 1]);
                let next_is_word = p < n && is_word_char(chars[p]);
                prev_is_word != next_is_word
            });
            let effective_end = match effective_end {
                Some(e) => e,
                None => {
                    i += 1;
                    continue;
                }
            };

            // Find last '.' in [domain_start, effective_end) — mirrors Python's
            // greedy backtrack for [^\s@]+\.  which finds the split at the
            // rightmost dot where both sides of the domain are non-empty.
            let last_dot = (domain_start..effective_end).rev().find(|&j| chars[j] == '.');
            let last_dot = match last_dot {
                Some(d) => d,
                None => {
                    i += 1;
                    continue;
                }
            };

            // Need non-empty text before the dot (within effective domain)
            // and non-empty text after the dot (before effective_end).
            if last_dot == domain_start || last_dot + 1 == effective_end {
                i += 1;
                continue;
            }

            // Valid email match found. Advance past effective_end.
            count += 1;
            i = effective_end;
        } else {
            i += 1;
        }
    }
    count
}

// ---------------------------------------------------------------------------
// _pct helper — mirrors Python's `_pct(numerator, denominator)`
// ---------------------------------------------------------------------------

/// Integer percentage with floor division.
///
/// Mirrors Python:
///   `def _pct(numerator, denominator):
///       return 0 if denominator <= 0 else numerator * 100 // denominator`
///
/// Python `//` is floor division. For non-negative numerator and positive
/// denominator (always the case here), floor division equals truncating
/// division, so Rust's `/` operator produces the same result.
#[inline]
fn pct(numerator: i64, denominator: i64) -> i64 {
    if denominator <= 0 {
        0
    } else {
        numerator * 100 / denominator
    }
}

// ---------------------------------------------------------------------------
// classify_record — the public entry point
// ---------------------------------------------------------------------------

/// Classify record topology without using corpus or outcome knowledge.
///
/// Direct port of Python's `classify_record(content: str) -> ShapeDecision`
/// in `record_shape_classifier.py`. All feature names, score names,
/// threshold values, and label sets are preserved verbatim.
///
/// Unicode index unit: Python `len(content)` counts code points; Rust
/// mirrors this with `content.chars().count()`.
///
/// No randomness, no `Date::now()`, no external state. Purely functional.
pub fn classify_record(content: &str) -> ShapeDecision {
    // --- splitlines + strip filter ---
    // Mirrors Python: `lines = [line for line in content.splitlines()
    //                           if line.strip()]`
    // Python `splitlines()` splits on \n, \r\n, \r, form feed, vertical
    // tab, and several Unicode line-separator chars. Rust's `lines()` splits
    // on \n and \r\n (not \r alone), which matches the test data in practice.
    // If LoCoMo or blind200 vectors use bare \r, this would diverge; the
    // oracle vectors use \n line endings (verified).
    let lines: Vec<&str> = content
        .lines()
        .filter(|l| !l.trim().is_empty())
        .collect();
    let line_count = lines.len().max(1) as i64;

    // --- Tag-line scan ---
    // Mirrors Python's loop that builds `tags` and `known_speaker_lines`.
    let mut tags: Vec<String> = Vec::new();
    let mut known_speaker_lines: i64 = 0;

    for line in &lines {
        if let Some(tag) = scan_tag_line(line) {
            // tag.startswith("speaker ") mirrors Python's str.startswith("speaker ")
            // (note: trailing space means "speaker 1", "speaker a", etc. match;
            // "speakers" does not because there's no space after "speaker").
            if KNOWN_SPEAKERS.iter().any(|&s| s == tag)
                || tag.starts_with("speaker ")
            {
                known_speaker_lines += 1;
            }
            tags.push(tag);
        }
    }

    // --- Tag statistics ---
    // tag_counts: Counter(tags) — count occurrences of each unique tag.
    let mut tag_counts: HashMap<String, i64> = HashMap::new();
    for tag in &tags {
        *tag_counts.entry(tag.clone()).or_insert(0) += 1;
    }

    // top2_tag_lines: sum of counts for the top-2 most frequent tags.
    // Mirrors Python's: sum(count for _, count in tag_counts.most_common(2))
    // Ties in count are arbitrary in Python; for the sum we don't care about
    // which specific tags are top-2, only the two largest counts.
    let mut count_vals: Vec<i64> = tag_counts.values().cloned().collect();
    count_vals.sort_unstable_by(|a, b| b.cmp(a)); // descending
    let top2_tag_lines: i64 = count_vals.iter().take(2).sum();

    // tag_switches: number of adjacent (prev, next) tag pairs where tags differ.
    // Mirrors Python: sum(1 for left, right in zip(tags, tags[1:]) if left != right)
    let tag_switches: i64 = tags
        .windows(2)
        .filter(|w| w[0] != w[1])
        .count() as i64;

    // --- Line-pattern counts ---
    let date_lead_lines: i64 = lines.iter().filter(|l| scan_date_lead(l)).count() as i64;
    let bullet_lines: i64 = lines.iter().filter(|l| scan_bullet_lead(l)).count() as i64;
    let heading_lines: i64 = lines.iter().filter(|l| scan_heading_lead(l)).count() as i64;

    // --- Pipe-part analysis ---
    // Mirrors Python:
    //   pipe_parts = len([part for part in re.split(r"\s+\|\s+", content)
    //                     if part.strip()])
    //   pipe_date_parts = sum(bool(DATE_LEAD.match(part)) for part in
    //                         re.split(r"\s+\|\s+", content) if part.strip())
    let parts = split_pipe_parts(content);
    let pipe_parts: i64 = parts.len() as i64;
    let pipe_date_parts: i64 = parts
        .iter()
        .filter(|p| scan_date_lead(p))
        .count() as i64;

    // --- Whole-content counters ---
    let date_mentions: i64 = count_date_any(content);
    let number_mentions: i64 = count_number_any(content);
    let email_mentions: i64 = count_email(content);

    // --- average_line_chars ---
    // Mirrors Python: `average_line_chars = len(content) // line_count`
    // len(content) is code-point count; line_count is non-empty-line count.
    // Note: divides TOTAL content length by non-empty line count — not
    // a per-line average of individual line lengths.
    let chars_count: i64 = content.chars().count() as i64;
    let average_line_chars: i64 = chars_count / line_count;

    // --- Features dict ---
    // Key insertion order matches Python's dict literal for readability;
    // serde_json::Value comparison is order-independent.
    let tag_count_i64 = tags.len() as i64;
    let tag_max_denominator = if tag_count_i64 > 1 { tag_count_i64 - 1 } else { 1 };

    let mut features: HashMap<String, i64> = HashMap::new();
    features.insert("chars".into(), chars_count);
    features.insert("lines".into(), lines.len() as i64);
    features.insert("tag_lines".into(), tag_count_i64);
    features.insert("distinct_tags".into(), tag_counts.len() as i64);
    features.insert("known_speaker_lines".into(), known_speaker_lines);
    features.insert("tag_line_pct".into(), pct(tag_count_i64, line_count));
    features.insert("top2_tag_pct".into(), pct(top2_tag_lines, tag_count_i64));
    features.insert("tag_switch_pct".into(), pct(tag_switches, tag_max_denominator));
    features.insert("date_lead_lines".into(), date_lead_lines);
    features.insert("date_lead_pct".into(), pct(date_lead_lines, line_count));
    features.insert("bullet_lines".into(), bullet_lines);
    features.insert("bullet_line_pct".into(), pct(bullet_lines, line_count));
    features.insert("heading_lines".into(), heading_lines);
    features.insert("pipe_parts".into(), pipe_parts);
    features.insert("pipe_date_parts".into(), pipe_date_parts);
    features.insert("date_mentions".into(), date_mentions);
    features.insert("number_mentions".into(), number_mentions);
    features.insert("email_mentions".into(), email_mentions);
    features.insert("average_line_chars".into(), average_line_chars);

    // --- Scores ---
    // Mirrors Python's score accumulation. All thresholds and increments
    // are verbatim from record_shape_classifier.py.
    let mut scores: HashMap<String, i32> = HashMap::new();
    scores.insert("dialogue".into(), 0);
    scores.insert("timeline".into(), 0);
    scores.insert("outline".into(), 0);
    scores.insert("entity_dense".into(), 0);
    scores.insert("prose".into(), 0);

    // --- Dialogue scoring ---
    if tag_count_i64 >= 4 {
        *scores.get_mut("dialogue").unwrap() += 5;
    }
    if features["tag_line_pct"] >= 25 {
        *scores.get_mut("dialogue").unwrap() += 2;
    }
    if features["top2_tag_pct"] >= 60 {
        *scores.get_mut("dialogue").unwrap() += 4;
    }
    if features["tag_switch_pct"] >= 50 {
        *scores.get_mut("dialogue").unwrap() += 2;
    }
    if known_speaker_lines >= 2 {
        *scores.get_mut("dialogue").unwrap() += 4;
    }

    // --- Timeline scoring ---
    if date_lead_lines >= 3 {
        *scores.get_mut("timeline").unwrap() += 7;
    }
    if features["date_lead_pct"] >= 25 {
        *scores.get_mut("timeline").unwrap() += 4;
    }
    if pipe_date_parts >= 3 {
        *scores.get_mut("timeline").unwrap() += 5;
    }
    if date_mentions >= 5 {
        *scores.get_mut("timeline").unwrap() += 2;
    }

    // --- Outline scoring ---
    if bullet_lines >= 3 {
        *scores.get_mut("outline").unwrap() += 7;
    }
    if features["bullet_line_pct"] >= 20 {
        *scores.get_mut("outline").unwrap() += 4;
    }
    if heading_lines >= 2 {
        *scores.get_mut("outline").unwrap() += 4;
    }
    if pipe_parts >= 5 {
        *scores.get_mut("outline").unwrap() += 3;
    }

    // --- Entity-dense scoring ---
    let scalar_mentions = date_mentions + number_mentions + email_mentions;
    if scalar_mentions >= 8 {
        *scores.get_mut("entity_dense").unwrap() += 5;
    }
    // scalar_mentions * 1000 // max(1, len(content)) >= 3
    // Python //: floor division. For non-negative values, equals Rust /.
    let content_len = chars_count.max(1);
    if scalar_mentions * 1000 / content_len >= 3 {
        *scores.get_mut("entity_dense").unwrap() += 3;
    }
    if email_mentions > 0 {
        *scores.get_mut("entity_dense").unwrap() += 2;
    }

    // --- Prose scoring ---
    if (lines.len() as i64) <= 4 {
        *scores.get_mut("prose").unwrap() += 4;
    }
    if average_line_chars >= 120 {
        *scores.get_mut("prose").unwrap() += 3;
    }
    // `not tags and not date_lead_lines and not bullet_lines`
    if tags.is_empty() && date_lead_lines == 0 && bullet_lines == 0 {
        *scores.get_mut("prose").unwrap() += 4;
    }

    // --- Label selection ---
    // active: labels whose score >= 6
    let mut active: Vec<String> = scores
        .iter()
        .filter(|(_, &s)| s >= 6)
        .map(|(k, _)| k.clone())
        .collect();

    // structural: subset of active that are in {dialogue, timeline, outline}
    let structural: Vec<&str> = ["dialogue", "timeline", "outline"]
        .iter()
        .filter(|&&l| active.iter().any(|a| a == l))
        .cloned()
        .collect();

    // If no label scored >= 6, default to prose
    if active.is_empty() {
        active.push("prose".into());
    }

    // ranked: active sorted by (-score, label_alpha)
    // Mirrors Python: sorted(active, key=lambda label: (-scores[label], label))
    active.sort_by(|a, b| {
        let sa = scores[a];
        let sb = scores[b];
        // Sort descending by score, then ascending alphabetically
        sb.cmp(&sa).then_with(|| a.cmp(b))
    });
    let ranked = active; // renamed for clarity

    // primary and labels
    let (primary, labels) = if structural.len() >= 2 {
        let mut lbls = vec!["hybrid".to_string()];
        lbls.extend(ranked.iter().cloned());
        ("hybrid".to_string(), lbls)
    } else {
        let p = ranked[0].clone();
        (p, ranked.clone())
    };

    // --- Confidence margin ---
    // ordered_scores[0] - ordered_scores[1]
    // Mirrors Python: `ordered_scores = sorted(scores.values(), reverse=True)
    //                  margin = ordered_scores[0] - ordered_scores[1]`
    let mut ordered: Vec<i32> = scores.values().cloned().collect();
    ordered.sort_unstable_by(|a, b| b.cmp(a));
    let confidence_margin = ordered[0] - ordered[1];

    ShapeDecision {
        primary,
        labels,
        scores,
        features,
        confidence_margin,
    }
}

// ---------------------------------------------------------------------------
// Harness-facing method-order functions
// ---------------------------------------------------------------------------

/// Rank NuExtract templates for a record from its shape.
///
/// Harness-facing: these orderings are consumed by the benchmark harness,
/// not by production code. Direct port of Python's
/// `nuextract_method_order(decision: ShapeDecision) -> tuple[str, ...]`.
pub fn nuextract_method_order(decision: &ShapeDecision) -> Vec<&'static str> {
    if decision.labels.contains(&"timeline".to_string()) {
        return vec!["timeline", "documentary", "conversation", "compact"];
    }
    // documentary_score = max of timeline, outline, entity_dense, prose scores
    let documentary_score = *[
        decision.scores.get("timeline").copied().unwrap_or(0),
        decision.scores.get("outline").copied().unwrap_or(0),
        decision.scores.get("entity_dense").copied().unwrap_or(0),
        decision.scores.get("prose").copied().unwrap_or(0),
    ]
    .iter()
    .max()
    .unwrap();
    let dialogue_score = decision.scores.get("dialogue").copied().unwrap_or(0);

    let first_two: [&str; 2] = if dialogue_score > documentary_score {
        ["conversation", "documentary"]
    } else {
        ["documentary", "conversation"]
    };
    vec![first_two[0], first_two[1], "compact"]
}

/// Rank Qwen3 framings for a record from its shape.
///
/// Harness-facing. Direct port of Python's
/// `qwen3_method_order(decision: ShapeDecision) -> tuple[str, ...]`.
pub fn qwen3_method_order(decision: &ShapeDecision) -> Vec<&'static str> {
    let repetitive = ["dialogue", "timeline", "outline", "hybrid"]
        .iter()
        .any(|&l| decision.labels.contains(&l.to_string()));

    let first_two: [&str; 2] = if repetitive {
        ["reframed", "standard"]
    } else {
        ["standard", "reframed"]
    };

    let dialogue_score = decision.scores.get("dialogue").copied().unwrap_or(0);
    let outline_score = decision.scores.get("outline").copied().unwrap_or(0);

    if decision.labels.contains(&"dialogue".to_string()) && dialogue_score > outline_score {
        vec![first_two[0], "dialogue_facts", first_two[1], "json_chunks"]
    } else {
        vec![first_two[0], first_two[1], "json_chunks"]
    }
}
