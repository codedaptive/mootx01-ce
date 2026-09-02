//! Atom layer — Rust port of the `intent-span` atom primitives from
//! `distill_plus_converter.py`.
//!
//! # What this module provides
//!
//! The "atom layer" produces non-overlapping, exact source spans that the
//! intent-span selector uses as indivisible units.  Every atom stores its
//! code-point `[start, end)` range, kind string, optional speaker, dependency
//! chain, and hard-required flag.
//!
//! ## Index unit
//!
//! All `start` / `end` fields are **Unicode code-point indices** — identical to
//! Python `str` indices.  Rust `char` is a Unicode scalar value (same thing for
//! valid UTF-8 without surrogates), so all code-point arithmetic uses `Vec<char>`
//! slices internally.
//!
//! ## No regex
//!
//! Every pattern is delegated to an already-ported scanner in
//! `crate::scanners` or `crate::shape`.  Zero use of the `regex` crate.
//!
//! ## Python function mirrors
//!
//! | Rust function          | Python original               |
//! |------------------------|-------------------------------|
//! | `physical_lines`       | `_physical_lines`             |
//! | `known_speaker`        | `_known_speaker`              |
//! | `speaker_turns`        | `_speaker_turns`              |
//! | `heading_level`        | `_heading_level`              |
//! | `is_list_line`         | `_is_list_line`               |
//! | `indent_width`         | `_indent_width`               |
//! | `append_exact_atom`    | `_append_exact_atom`          |
//! | `structured_atoms`     | `_structured_atoms`           |
//! | `reindex_atoms`        | `_reindex_atoms`              |
//! | `intent_atoms`         | `_intent_atoms`               |
//! | (see terms module)     | `_normalized_terms`           |

use std::collections::{HashMap, HashSet};

use serde_json::{json, Map, Value};

use crate::scanners::{
    scan_bold_heading_re, scan_diagram_re, scan_embedded_user_fact_re,
    scan_fence_open_re, scan_field_line_re, scan_list_marker_re,
    scan_markdown_heading_re, scan_date_re, scan_number_re,
    scan_operative_re, scan_pipe_split_re, scan_polarity_only_re,
    scan_table_separator_re, scan_transform_followup_re, scan_turn_filler_re,
};
use crate::shape::{
    scan_bullet_lead, scan_date_lead, scan_heading_lead, scan_tag_line_with_body,
    KNOWN_SPEAKERS,
};
use crate::terms::{normalized_terms, query_terms};

// ---------------------------------------------------------------------------
// Known speaker subsets
// ---------------------------------------------------------------------------

/// Speaker names that represent the user side of a conversation.
///
/// Mirrors Python `KNOWN_USER_SPEAKERS = frozenset({"user", "human",
/// "customer", "interviewer"})`.
const KNOWN_USER_SPEAKERS: &[&str] = &["user", "human", "customer", "interviewer"];

/// Speaker names that represent the answer/assistant side.
///
/// Mirrors Python `KNOWN_ANSWER_SPEAKERS = frozenset({"assistant", "agent",
/// "system", "interviewee"})`.
const KNOWN_ANSWER_SPEAKERS: &[&str] = &["assistant", "agent", "system", "interviewee"];

/// Abbreviation set used by `_period_is_abbreviation`.
///
/// Mirrors Python `ABBREVIATIONS = frozenset({"dr", "e.g", "i.e", "jr",
/// "mr", "mrs", "ms", "prof", "sr", "u.s", "u.k", "vs"})`.
const ABBREVIATIONS: &[&str] = &[
    "dr", "e.g", "i.e", "jr", "mr", "mrs", "ms", "prof", "sr", "u.s", "u.k", "vs",
];

/// Action words used by `_intent_relevance`.
///
/// Mirrors Python `ACTION_WORDS` frozenset.
const ACTION_WORDS: &[&str] = &[
    "agreed", "approved", "assigned", "build", "built", "cancel", "changed",
    "choose", "decided", "deliver", "due", "failed", "fixed", "launch",
    "must", "need", "planned", "prefer", "preferred", "prefers",
    "preference", "favorite", "routine", "regularly", "usually", "required",
    "ship", "shipped", "should", "started", "stop", "will", "won't",
];

/// Action stems derived from ACTION_WORDS via `_normalized_terms`.
/// Computed lazily via `action_stems()`.
fn action_stems() -> HashSet<String> {
    let mut stems = HashSet::new();
    for word in ACTION_WORDS {
        for term in normalized_terms(word) {
            stems.insert(term);
        }
    }
    stems
}

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// An indivisible, exact source span used by intent-span selection.
///
/// Mirrors Python `IntentAtom` frozen dataclass from
/// `distill_plus_converter.py`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IntentAtom {
    /// Sequential index within the atom list.
    pub atom_id: usize,
    /// Code-point start (inclusive) within the full source string.
    pub start: usize,
    /// Code-point end (exclusive) within the full source string.
    pub end: usize,
    /// Verbatim text extracted from `source[start..end]`.
    pub text: String,
    /// Structural kind label (e.g. "sentence-or-entry", "heading").
    pub kind: String,
    /// Lowercased speaker tag if the atom is inside a dialogue turn.
    pub speaker: Option<String>,
    /// Atom IDs this atom depends on (must be selected together).
    pub dependencies: Vec<usize>,
    /// True when this atom must be included regardless of budget.
    pub hard_required: bool,
}

/// One dialogue speaker turn.
///
/// Mirrors Python `SpeakerTurn` frozen dataclass.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpeakerTurn {
    /// Code-point start of the speaker-label line (inclusive).
    pub start: usize,
    /// Code-point end of the turn (exclusive; start of next turn or EOF).
    pub end: usize,
    /// Code-point end of the first (speaker-label) line (exclusive).
    pub first_line_end: usize,
    /// Code-point start of the turn body (after speaker label + whitespace).
    pub body_start: usize,
    /// Lowercased, casefolded speaker name.
    pub speaker: String,
}

// ---------------------------------------------------------------------------
// §1 — physical_lines
// ---------------------------------------------------------------------------

/// Split `source` into physical lines with exact code-point spans.
///
/// Mirrors Python `_physical_lines(source, start=0, end=None)`:
/// ```python
/// stop = len(source) if end is None else end
/// while cursor < stop:
///     newline = source.find("\n", cursor, stop)
///     line_end = stop if newline < 0 else newline + 1
///     raw = source[cursor:line_end]
///     lines.append((cursor, line_end, raw.rstrip("\r\n")))
///     cursor = line_end
/// ```
///
/// Returns `(start_cp, end_cp, visible)` triples where `visible` has the
/// trailing `\r\n` stripped (like Python `str.rstrip("\r\n")`).
/// `end_cp` includes the newline character, if any.
pub fn physical_lines(source_chars: &[char], start: usize, stop: usize) -> Vec<(usize, usize, String)> {
    let mut lines = Vec::new();
    let mut cursor = start;
    while cursor < stop {
        // Find next '\n' in [cursor, stop).
        let newline = source_chars[cursor..stop]
            .iter()
            .position(|&c| c == '\n')
            .map(|rel| cursor + rel);
        let line_end = match newline {
            Some(idx) => idx + 1, // include the '\n'
            None => stop,
        };
        let raw: String = source_chars[cursor..line_end].iter().collect();
        // rstrip("\r\n") — remove trailing CR and LF.
        let visible: String = raw.trim_end_matches(|c| c == '\r' || c == '\n').to_string();
        lines.push((cursor, line_end, visible));
        cursor = line_end;
    }
    lines
}

// ---------------------------------------------------------------------------
// §2 — known_speaker
// ---------------------------------------------------------------------------

/// Try to parse a speaker-label line.
///
/// Mirrors Python `_known_speaker(line) -> tuple[str, int] | None`:
/// ```python
/// match = TAG_LINE.match(line)
/// speaker = match.group(1).strip().casefold()
/// if speaker not in KNOWN_SPEAKERS and not speaker.startswith("speaker "):
///     return None
/// return speaker, match.start(2)
/// ```
///
/// Returns `(speaker, body_cp_offset)` where `body_cp_offset` is the
/// code-point index of the body start within `line`.
pub fn known_speaker(line: &str) -> Option<(String, usize)> {
    let (tag, body_cp) = scan_tag_line_with_body(line)?;
    // Check KNOWN_SPEAKERS or "speaker " prefix.
    let valid = KNOWN_SPEAKERS.contains(&tag.as_str())
        || tag.starts_with("speaker ");
    if !valid {
        return None;
    }
    Some((tag, body_cp))
}

// ---------------------------------------------------------------------------
// §3 — speaker_turns
// ---------------------------------------------------------------------------

/// Parse speaker turns from a source document.
///
/// Mirrors Python `_speaker_turns(source)`:
/// - Skips lines inside fenced-code blocks.
/// - Collects `(line_start, line_end, body_start, speaker)` markers.
/// - Builds `SpeakerTurn` instances from consecutive markers.
///
/// Code-point offsets throughout.
pub fn speaker_turns(source_chars: &[char]) -> Vec<SpeakerTurn> {
    let stop = source_chars.len();
    let lines = physical_lines(source_chars, 0, stop);

    let mut markers: Vec<(usize, usize, usize, String)> = Vec::new();
    let mut fence_char: Option<char> = None;

    for (line_start, line_end, visible) in &lines {
        // Fence detection — mirrors `FENCE_OPEN_RE.match(visible)`.
        let fence_matches = scan_fence_open_re(visible);
        if let Some(fm) = fence_matches.first() {
            let token = fm.groups.first().and_then(|g| g.as_ref())
                .map(|s| s.as_str()).unwrap_or("");
            let marker_char = token.chars().next().unwrap_or('`');
            if fence_char.is_none() {
                fence_char = Some(marker_char);
            } else if fence_char == Some(marker_char) {
                fence_char = None;
            }
            continue;
        }
        if fence_char.is_some() {
            continue;
        }

        // Try to parse as a known speaker label.
        if let Some((speaker, body_offset)) = known_speaker(visible) {
            // body_offset is relative to `visible`; `line_start` is the
            // global code-point offset.  body_start = line_start + body_offset.
            markers.push((*line_start, *line_end, line_start + body_offset, speaker));
        }
    }

    // Build SpeakerTurn instances.
    let total_len = source_chars.len();
    let mut turns: Vec<SpeakerTurn> = Vec::new();
    for (index, &(start, first_end, body_start, ref speaker)) in markers.iter().enumerate() {
        let end = if index + 1 < markers.len() {
            markers[index + 1].0 // start of next marker's line
        } else {
            total_len
        };
        turns.push(SpeakerTurn {
            start,
            end,
            first_line_end: first_end,
            body_start,
            speaker: speaker.clone(),
        });
    }
    turns
}

// ---------------------------------------------------------------------------
// §4 — heading_level
// ---------------------------------------------------------------------------

/// Return the heading level of `line` (1–7), or `None` if not a heading.
///
/// Mirrors Python `_heading_level(line)`:
/// - Markdown `#` headings: level = number of `#` characters (1–6).
/// - Bold headings `**...**`: level 7.
/// - HEADING_LEAD keyword lines: level 1.
pub fn heading_level(line: &str) -> Option<usize> {
    // Try MARKDOWN_HEADING_RE first (Python order matches left-to-right).
    let md_matches = scan_markdown_heading_re(line);
    if let Some(m) = md_matches.first() {
        // group 1 = "marks" = the run of '#' characters.
        let marks = m.groups.get(1).and_then(|g| g.as_ref()).map(|s| s.len()).unwrap_or(0);
        if marks >= 1 {
            return Some(marks);
        }
    }
    // Bold heading: `^\s*\*\*[^*\n]{1,120}\*\*\s*:?[ \t]*$`
    if !scan_bold_heading_re(line).is_empty() {
        return Some(7);
    }
    // HEADING_LEAD: keyword-led section titles.
    if scan_heading_lead(line) {
        return Some(1);
    }
    None
}

// ---------------------------------------------------------------------------
// §5 — is_list_line
// ---------------------------------------------------------------------------

/// Return true if `line` starts with a list bullet or numbered item.
///
/// Mirrors Python `_is_list_line(line) = bool(BULLET_LEAD.match(line))`.
pub fn is_list_line(line: &str) -> bool {
    scan_bullet_lead(line)
}

// ---------------------------------------------------------------------------
// §6 — indent_width
// ---------------------------------------------------------------------------

/// Compute the leading indent width of `line` in spaces (tab = 4 spaces).
///
/// Mirrors Python:
/// ```python
/// prefix = line[:len(line) - len(line.lstrip(" \t"))]
/// return sum(4 if char == "\t" else 1 for char in prefix)
/// ```
pub fn indent_width(line: &str) -> usize {
    let stripped = line.trim_start_matches(|c| c == ' ' || c == '\t');
    let prefix_len = line.len() - stripped.len();
    let prefix = &line[..prefix_len];
    prefix.chars().map(|c| if c == '\t' { 4 } else { 1 }).sum()
}

// ---------------------------------------------------------------------------
// §7 — append_exact_atom
// ---------------------------------------------------------------------------

/// Append a new atom to `atoms` and return a reference-counted copy.
///
/// Mirrors Python `_append_exact_atom(atoms, source, start, end, kind,
/// speaker=None, dependencies=(), hard_required=False)`.
///
/// The `text` field is extracted from `source_chars[start..end]`.
pub fn append_exact_atom(
    atoms: &mut Vec<IntentAtom>,
    source_chars: &[char],
    start: usize,
    end: usize,
    kind: &str,
    speaker: Option<&str>,
    dependencies: Vec<usize>,
    hard_required: bool,
) -> IntentAtom {
    let atom_id = atoms.len();
    let text: String = source_chars[start..end].iter().collect();
    let atom = IntentAtom {
        atom_id,
        start,
        end,
        text,
        kind: kind.to_string(),
        speaker: speaker.map(|s| s.to_string()),
        dependencies,
        hard_required,
    };
    atoms.push(atom.clone());
    atom
}

// ---------------------------------------------------------------------------
// §8 — sentence and pipe span helpers (dependencies of structured_atoms)
// ---------------------------------------------------------------------------

/// Return true if the period at `index` in `text` (code points) is an
/// abbreviation and should not trigger a sentence boundary.
///
/// Mirrors Python `_period_is_abbreviation(text, index)`.
///
/// Note: the Python version uses `re.fullmatch`, `re.search` internally.
/// This port uses hand-written character-level logic mirroring each branch.
fn period_is_abbreviation(chars: &[char], index: usize) -> bool {
    // Branch 1: numbered item marker check.
    // ```python
    // line_prefix = text[text.rfind("\n", 0, index) + 1:index + 1]
    // if re.fullmatch(r"\s*(?:[A-Za-z][A-Za-z ]{0,24}:\s*)?\d+\.", line_prefix):
    //     following = text[index + 1:].lstrip()
    //     if following: return True
    // ```
    // Find the start of the current line.
    let line_start = chars[..index]
        .iter()
        .rposition(|&c| c == '\n')
        .map_or(0, |p| p + 1);
    // line_prefix = chars[line_start..=index]
    let line_prefix_chars = &chars[line_start..index + 1];
    if is_numbered_item_prefix(line_prefix_chars) {
        let following: String = chars[index + 1..].iter().collect();
        if !following.trim_start().is_empty() {
            return true;
        }
    }

    // Branch 2: repeated single-letter abbreviations like "U.S.A."
    // `re.search(r"(?:\b[A-Za-z]\.){2,}$", prefix)` where prefix = text[max(0,index-24)..index+1]
    let pre_start = if index >= 24 { index - 24 } else { 0 };
    let prefix_chars = &chars[pre_start..index + 1];
    if has_repeated_single_letter_abbrev(prefix_chars) {
        return true;
    }

    // Branch 3: abbreviation token lookup.
    // `token = re.search(r"([A-Za-z]+(?:\.[A-Za-z]+)*)\.$", prefix)`
    // if token in ABBREVIATIONS → True
    // if len(token)==1: following[0].isupper() → True
    if let Some(token) = last_alpha_token_before_period(prefix_chars) {
        let lower_token = token.to_lowercase();
        if ABBREVIATIONS.contains(&lower_token.as_str()) {
            return true;
        }
        if token.len() == 1 {
            let following: String = chars[index + 1..].iter().collect();
            let trimmed = following.trim_start();
            if trimmed.chars().next().map_or(false, |c| c.is_uppercase()) {
                return true;
            }
        }
    }

    false
}

/// Return true if `line_prefix` matches `^\s*(?:[A-Za-z][A-Za-z ]{0,24}:\s*)?\d+\.$`.
///
/// This is a hand-written fullmatch for the numbered-item prefix pattern.
fn is_numbered_item_prefix(chars: &[char]) -> bool {
    let n = chars.len();
    let mut i = 0;
    // Skip \s*
    while i < n && chars[i].is_whitespace() { i += 1; }
    // Optional `[A-Za-z][A-Za-z ]{0,24}:\s*` (speaker label)
    if i < n && chars[i].is_ascii_alphabetic() {
        let label_start = i;
        i += 1;
        while i < n && (i - label_start) <= 24 {
            if chars[i].is_ascii_alphabetic() || chars[i] == ' ' {
                i += 1;
            } else {
                break;
            }
        }
        if i < n && chars[i] == ':' {
            i += 1;
            while i < n && chars[i].is_whitespace() { i += 1; }
            // Now expect \d+\.
        } else {
            // Not a label — reset.
            i = 0;
            while i < n && chars[i].is_whitespace() { i += 1; }
        }
    }
    // \d+
    let digit_start = i;
    while i < n && chars[i].is_ascii_digit() { i += 1; }
    if i == digit_start { return false; }
    // \.  (the period is at index, so chars[n-1] == '.')
    i < n && chars[i] == '.' && i == n - 1
}

/// Return true if `prefix` ends with two or more `\b[A-Za-z]\.` sequences.
///
/// Mirrors `re.search(r"(?:\b[A-Za-z]\.){2,}$", prefix)`.
fn has_repeated_single_letter_abbrev(chars: &[char]) -> bool {
    // Walk backwards from end looking for letter-dot pairs.
    let n = chars.len();
    if n < 4 { return false; } // need at least two "X."
    let mut count = 0;
    let mut i = n;
    // From the end, we expect alternating '.' and letter, with optional boundary.
    while i >= 2 {
        // Check chars[i-2] is alpha, chars[i-1] is '.'
        let c_letter = chars[i - 2];
        let c_dot = chars[i - 1];
        if c_dot == '.' && c_letter.is_ascii_alphabetic() {
            // Check word boundary before the letter.
            let before = if i >= 3 { chars[i - 3] } else { '\0' };
            let is_boundary = i < 3 || !before.is_ascii_alphanumeric();
            if is_boundary {
                count += 1;
                i -= 2;
            } else {
                break;
            }
        } else {
            break;
        }
    }
    count >= 2
}

/// Extract the last `[A-Za-z]+(\.[A-Za-z]+)*` token before a final `.` in `prefix`.
///
/// Mirrors `re.search(r"([A-Za-z]+(?:\.[A-Za-z]+)*)\.$", prefix)`.
fn last_alpha_token_before_period(chars: &[char]) -> Option<String> {
    let n = chars.len();
    if n < 2 { return None; }
    // Must end with '.'.
    if chars[n - 1] != '.' { return None; }
    // Walk backward from n-2 collecting [A-Za-z] and '.' separators.
    let mut i = n - 1; // pointing at the final '.'
    // We need at least one letter immediately before this dot.
    if i == 0 || !chars[i - 1].is_ascii_alphabetic() { return None; }
    // Collect token chars backward.
    let mut token_chars: Vec<char> = Vec::new();
    while i > 0 {
        let c = chars[i - 1];
        if c.is_ascii_alphabetic() {
            token_chars.push(c);
            i -= 1;
        } else if c == '.' && !token_chars.is_empty() {
            // Allow internal dots (e.g. "e.g").
            token_chars.push('.');
            i -= 1;
        } else {
            break;
        }
    }
    if token_chars.is_empty() { return None; }
    token_chars.reverse();
    Some(token_chars.into_iter().collect())
}

/// Split `paragraph` into sentence spans.
///
/// Mirrors Python `_sentence_spans(text, base=0)`.
///
/// All offsets in the returned tuples are code-point offsets into the
/// FULL source string (shifted by `base`).
pub fn sentence_spans(paragraph: &str, base: usize) -> Vec<(usize, usize, String)> {
    let chars: Vec<char> = paragraph.chars().collect();
    let n = chars.len();
    let mut spans: Vec<(usize, usize, String)> = Vec::new();
    let mut start = 0usize;

    for index in 0..n {
        let char = chars[index];

        // Newline is a boundary only when the preceding visible char already ends a sentence.
        let newline_boundary = if char == '\n' {
            // `previous = text[:index].rstrip()`
            let before: String = chars[..index].iter().collect();
            let previous = before.trim_end();
            !previous.is_empty() && {
                let last = previous.chars().last().unwrap();
                ".!?。！？".contains(last)
            }
        } else {
            false
        };

        // Chinese/Japanese punctuation, Western punctuation with space following.
        let boundary = newline_boundary
            || "。！？".contains(char)
            || ((".!?".contains(char))
                && (index + 1 == n
                    || chars[index + 1].is_whitespace())
                && !(char == '.' && period_is_abbreviation(&chars, index)));

        if !boundary {
            continue;
        }

        // raw = text[start..index+1]
        let raw: Vec<char> = chars[start..index + 1].to_vec();
        let left = raw.iter().position(|c| !c.is_whitespace()).unwrap_or(raw.len());
        let right = raw.iter().rposition(|c| !c.is_whitespace()).map_or(0, |p| p + 1);
        if right > left {
            spans.push((
                base + start + left,
                base + start + right,
                raw[left..right].iter().collect(),
            ));
        }
        start = index + 1;
    }

    // Tail: if start < len(text)
    if start < n {
        let raw: Vec<char> = chars[start..].to_vec();
        let left = raw.iter().position(|c| !c.is_whitespace()).unwrap_or(raw.len());
        let right = raw.iter().rposition(|c| !c.is_whitespace()).map_or(0, |p| p + 1);
        if right > left {
            spans.push((
                base + start + left,
                base + start + right,
                raw[left..right].iter().collect(),
            ));
        }
    }

    spans
}

/// Split `text` on `\s+\|\s+` into trimmed sub-spans.
///
/// Mirrors Python `_pipe_spans(text, start)`.
///
/// Returns `(abs_start, abs_end, visible)` triples where coordinates are
/// code-point offsets into the full source (shifted by `start`).
pub fn pipe_spans(text: &str, start_cp: usize) -> Vec<(usize, usize, String)> {
    // Use scan_pipe_split_re which returns separator match positions.
    let separators = scan_pipe_split_re(text);
    if separators.is_empty() {
        let chars: Vec<char> = text.chars().collect();
        let left = chars.iter().position(|c| !c.is_whitespace()).unwrap_or(chars.len());
        let right = chars.iter().rposition(|c| !c.is_whitespace()).map_or(0, |p| p + 1);
        if right > left {
            return vec![(
                start_cp + left,
                start_cp + right,
                chars[left..right].iter().collect(),
            )];
        }
        return vec![(start_cp, start_cp + chars.len(), text.to_string())];
    }

    // Build bounds and ends from separators (mirrors Python zip logic).
    // bounds[0]=0, bounds[i+1]=sep[i].end_cp; ends[i]=sep[i].start_cp, ends[-1]=len(text_chars)
    let text_chars: Vec<char> = text.chars().collect();
    let text_cp_len = text_chars.len();

    let mut bounds: Vec<usize> = vec![0];
    let mut ends: Vec<usize> = Vec::new();
    for sep in &separators {
        ends.push(sep.start_cp);
        bounds.push(sep.end_cp);
    }
    ends.push(text_cp_len);

    let mut result = Vec::new();
    for (left_cp, right_cp) in bounds.iter().zip(ends.iter()) {
        let raw: Vec<char> = text_chars[*left_cp..*right_cp].to_vec();
        let trim_left = raw.iter().position(|c| !c.is_whitespace()).unwrap_or(raw.len());
        let trim_right = raw.iter().rposition(|c| !c.is_whitespace()).map_or(0, |p| p + 1);
        if trim_right > trim_left {
            result.push((
                start_cp + left_cp + trim_left,
                start_cp + left_cp + trim_right,
                raw[trim_left..trim_right].iter().collect(),
            ));
        }
    }
    result
}

/// Detect a fence-closing line for a given marker character.
///
/// Mirrors `re.match(rf"^\s*{re.escape(marker)}{{3,}}\s*$", line)`.
/// `marker_char` is either `` ` `` or `~`.
fn is_fence_close(line: &str, marker_char: char) -> bool {
    let chars: Vec<char> = line.chars().collect();
    let n = chars.len();
    let mut i = 0;
    // Skip ^\s*
    while i < n && chars[i].is_whitespace() { i += 1; }
    // Need at least 3 marker chars.
    let fence_start = i;
    while i < n && chars[i] == marker_char { i += 1; }
    if i - fence_start < 3 { return false; }
    // Skip trailing \s*
    while i < n && chars[i].is_whitespace() { i += 1; }
    // Must reach end.
    i == n
}

// ---------------------------------------------------------------------------
// §9 — structured_atoms
// ---------------------------------------------------------------------------

/// Build non-overlapping, exact, indivisible document atoms for
/// the sub-range `source_chars[start..stop]`.
///
/// Mirrors Python `_structured_atoms(source, start=0, end=None)`.
///
/// Returns `(atoms, unsupported_kinds)` where `unsupported_kinds` is a
/// sorted deduplicated list of unsupported structural shapes encountered.
pub fn structured_atoms(
    source_chars: &[char],
    start: usize,
    stop: usize,
) -> (Vec<IntentAtom>, Vec<String>) {
    let lines = physical_lines(source_chars, start, stop);
    let mut atoms: Vec<IntentAtom> = Vec::new();
    let mut unsupported: Vec<String> = Vec::new();
    let mut index = 0usize;

    while index < lines.len() {
        let (line_start, line_end, ref visible) = lines[index];

        // Skip blank lines.
        if visible.trim().is_empty() {
            index += 1;
            continue;
        }

        // --- timeline-entry / field-entry check ---
        let adjacent_field = {
            let prev_ok = index > 0
                && !scan_field_line_re(&lines[index - 1].2).is_empty();
            let next_ok = index + 1 < lines.len()
                && !scan_field_line_re(&lines[index + 1].2).is_empty();
            prev_ok || next_ok
        };
        let date_entry = scan_date_lead(visible)
            && scan_date_re(visible).len() <= 1;
        if date_entry || (scan_field_line_re(visible).len() > 0 && adjacent_field) {
            let kind = if date_entry { "timeline-entry" } else { "field-entry" };
            append_exact_atom(&mut atoms, source_chars, line_start, line_end, kind, None, vec![], false);
            index += 1;
            continue;
        }

        // --- fenced-code block ---
        let fence_matches = scan_fence_open_re(visible);
        if let Some(fm) = fence_matches.first() {
            let token = fm.groups.first().and_then(|g| g.as_ref())
                .map(|s| s.clone()).unwrap_or_default();
            let marker_char = token.chars().next().unwrap_or('`');
            let mut finish = index + 1;
            let mut closed = false;
            while finish < lines.len() {
                if is_fence_close(&lines[finish].2, marker_char) {
                    finish += 1;
                    closed = true;
                    break;
                }
                finish += 1;
            }
            let atom_end = if finish > 0 { lines[finish - 1].1 } else { line_end };
            let kind = if closed { "fenced-code" } else { "unsupported-unclosed-fence" };
            if !closed {
                unsupported.push("unclosed-fence".to_string());
            }
            append_exact_atom(&mut atoms, source_chars, line_start, atom_end, kind, None, vec![], false);
            index = finish;
            continue;
        }

        // --- indented-code block ---
        if visible.starts_with("    ") || visible.starts_with('\t') {
            let mut finish = index + 1;
            while finish < lines.len() {
                let candidate = &lines[finish].2;
                if candidate.trim().is_empty()
                    || candidate.starts_with("    ")
                    || candidate.starts_with('\t')
                {
                    finish += 1;
                } else {
                    break;
                }
            }
            append_exact_atom(
                &mut atoms, source_chars,
                line_start, lines[finish - 1].1,
                "indented-code", None, vec![], false,
            );
            index = finish;
            continue;
        }

        // --- heading ---
        if heading_level(visible).is_some() {
            // Each heading is its own atom (not grouping its section).
            append_exact_atom(&mut atoms, source_chars, line_start, line_end, "heading", None, vec![], false);
            index += 1;
            continue;
        }

        // --- table: current line has '|' AND next line is a separator ---
        if index + 1 < lines.len()
            && visible.contains('|')
            && !scan_table_separator_re(&lines[index + 1].2).is_empty()
        {
            let mut finish = index + 2;
            while finish < lines.len() && lines[finish].2.contains('|') {
                finish += 1;
            }
            append_exact_atom(
                &mut atoms, source_chars,
                line_start, lines[finish - 1].1,
                "table", None, vec![], false,
            );
            index = finish;
            continue;
        }

        // --- diagram ---
        if !scan_diagram_re(visible).is_empty() {
            let mut finish = index + 1;
            while finish < lines.len() {
                let candidate = &lines[finish].2;
                if !scan_diagram_re(candidate).is_empty() || candidate.trim().is_empty() {
                    finish += 1;
                } else {
                    break;
                }
            }
            append_exact_atom(
                &mut atoms, source_chars,
                line_start, lines[finish - 1].1,
                "diagram", None, vec![], false,
            );
            index = finish;
            continue;
        }

        // --- list-item ---
        if is_list_line(visible) {
            let parent_indent = indent_width(visible);
            let mut finish = index + 1;
            while finish < lines.len() {
                let candidate = &lines[finish].2;
                if is_list_line(candidate) {
                    if indent_width(candidate) <= parent_indent {
                        break;
                    }
                    finish += 1;
                    continue;
                }
                if candidate.trim().is_empty()
                    || candidate.starts_with("  ")
                    || candidate.starts_with('\t')
                {
                    finish += 1;
                } else {
                    break;
                }
            }
            append_exact_atom(
                &mut atoms, source_chars,
                line_start, lines[finish - 1].1,
                "list-item", None, vec![], false,
            );
            index = finish;
            continue;
        }

        // --- paragraph (possibly subdivided into sentences or pipe entries) ---
        let mut finish = index + 1;
        while finish < lines.len() {
            let candidate = &lines[finish].2;
            if candidate.trim().is_empty() {
                break;
            }
            if !scan_fence_open_re(candidate).is_empty()
                || candidate.starts_with("    ")
                || candidate.starts_with('\t')
                || heading_level(candidate).is_some()
                || is_list_line(candidate)
                || !scan_diagram_re(candidate).is_empty()
            {
                break;
            }
            if finish + 1 < lines.len()
                && candidate.contains('|')
                && !scan_table_separator_re(&lines[finish + 1].2).is_empty()
            {
                break;
            }
            finish += 1;
        }

        let atom_end = lines[finish - 1].1;
        let paragraph: String = source_chars[line_start..atom_end].iter().collect();
        let sents = sentence_spans(&paragraph, line_start);
        let pipes = pipe_spans(&paragraph, line_start);

        let subdivisions: Vec<(usize, usize, String)> = if sents.len() > 1 {
            sents
        } else if pipes.len() > 1 {
            pipes
        } else {
            vec![]
        };

        if !subdivisions.is_empty() {
            for (sub_start, sub_end, _) in subdivisions {
                append_exact_atom(
                    &mut atoms, source_chars,
                    sub_start, sub_end,
                    "sentence-or-entry", None, vec![], false,
                );
            }
            index = finish;
            continue;
        }

        // Plain paragraph (or oversized).
        let para_bytes = paragraph.len(); // UTF-8 bytes.
        // Python: len(paragraph.encode("utf-8")) > 4096
        let kind = if para_bytes > 4096 {
            unsupported.push("oversized-unstructured-paragraph".to_string());
            "unsupported-oversized-unstructured"
        } else {
            "paragraph"
        };
        append_exact_atom(&mut atoms, source_chars, line_start, atom_end, kind, None, vec![], false);
        index = finish;
    }

    // --- Link headings: each non-heading atom depends on its nearest heading ---
    // Mirrors Python heading_stack logic.
    let mut linked: Vec<IntentAtom> = Vec::new();
    let mut heading_stack: Vec<(usize, usize)> = Vec::new(); // (level, atom_id)

    for atom in &atoms {
        let mut dependencies = atom.dependencies.clone();
        if atom.kind == "heading" {
            let level = heading_level(&atom.text).unwrap_or(7);
            while heading_stack.last().map_or(false, |&(l, _)| l >= level) {
                heading_stack.pop();
            }
            if let Some(&(_, parent_id)) = heading_stack.last() {
                if !dependencies.contains(&parent_id) {
                    dependencies.push(parent_id);
                }
            }
            heading_stack.push((level, atom.atom_id));
        } else if let Some(&(_, head_id)) = heading_stack.last() {
            if !dependencies.contains(&head_id) {
                dependencies.push(head_id);
            }
        }
        // dict.fromkeys deduplication — preserves first occurrence order.
        let mut seen = HashSet::new();
        let deps_dedup: Vec<usize> = dependencies.into_iter().filter(|d| seen.insert(*d)).collect();
        linked.push(IntentAtom {
            atom_id: atom.atom_id,
            start: atom.start,
            end: atom.end,
            text: atom.text.clone(),
            kind: atom.kind.clone(),
            speaker: atom.speaker.clone(),
            dependencies: deps_dedup,
            hard_required: atom.hard_required,
        });
    }

    // Sort unsupported list (Python: `sorted(set(unsupported))`).
    let mut unsup_set: Vec<String> = unsupported.into_iter().collect();
    unsup_set.sort();
    unsup_set.dedup();

    (linked, unsup_set)
}

// ---------------------------------------------------------------------------
// §10 — reindex_atoms
// ---------------------------------------------------------------------------

/// Shift atom IDs and dependency IDs by `offset`.
///
/// Mirrors Python `_reindex_atoms(atoms, offset=0, dependency_map=None,
/// hard_ids=None)`.
pub fn reindex_atoms(
    atoms: &[IntentAtom],
    offset: usize,
    dependency_map: Option<&HashMap<usize, Vec<usize>>>,
    hard_ids: Option<&HashSet<usize>>,
) -> Vec<IntentAtom> {
    let empty_map = HashMap::new();
    let empty_set = HashSet::new();
    let dep_map = dependency_map.unwrap_or(&empty_map);
    let hard_set = hard_ids.unwrap_or(&empty_set);

    atoms.iter().map(|atom| {
        let new_id = atom.atom_id + offset;
        let dependencies = dep_map
            .get(&atom.atom_id)
            .cloned()
            .unwrap_or_else(|| atom.dependencies.clone());
        IntentAtom {
            atom_id: new_id,
            start: atom.start,
            end: atom.end,
            text: atom.text.clone(),
            kind: atom.kind.clone(),
            speaker: atom.speaker.clone(),
            dependencies: dependencies.iter().map(|d| d + offset).collect(),
            hard_required: atom.hard_required || hard_set.contains(&atom.atom_id),
        }
    }).collect()
}

// ---------------------------------------------------------------------------
// §11 — turn_body, substantive_turn, short_operative
// ---------------------------------------------------------------------------

/// Return the turn body text (stripped).
///
/// Mirrors Python `_turn_body(source, turn)`:
/// `source[turn.body_start:turn.end].strip()`
fn turn_body(source_chars: &[char], turn: &SpeakerTurn) -> String {
    let body: String = source_chars[turn.body_start..turn.end].iter().collect();
    body.trim().to_string()
}

/// Return true if the turn has substantial content (not filler).
///
/// Mirrors Python `_substantive_turn(source, turn)`:
/// `body and not TURN_FILLER_RE.fullmatch(body)`
fn substantive_turn(source_chars: &[char], turn: &SpeakerTurn) -> bool {
    let body = turn_body(source_chars, turn);
    if body.is_empty() {
        return false;
    }
    // scan_turn_filler_re acts as a fullmatch for the filler patterns.
    // The scanner matches anchored at line start ($); for fullmatch semantics
    // we check that the match spans the entire body.
    let matches = scan_turn_filler_re(&body);
    if let Some(m) = matches.first() {
        // fullmatch: match must span the whole string.
        let body_chars: Vec<char> = body.chars().collect();
        if m.start_cp == 0 && m.end_cp == body_chars.len() {
            return false;
        }
    }
    true
}

/// Return true if `text` is a short operative directive.
///
/// Mirrors Python `_short_operative(text)`:
/// ```python
/// def _short_operative(text: str) -> bool:
///     body = text.strip()
///     return bool(body and len(body.encode("utf-8")) <= 280
///                 and ("?" in body or OPERATIVE_RE.match(body)))
/// ```
/// The "?" check makes question-style requests (e.g. "what does X say?")
/// count as operative without matching OPERATIVE_RE keyword prefixes.
/// 280-byte limit matches the Python oracle (not 160).
fn short_operative(text: &str) -> bool {
    let body = text.trim();
    if body.is_empty() {
        return false;
    }
    // len(body.encode("utf-8")) <= 280 — Python UTF-8 byte length.
    if body.len() > 280 {
        return false;
    }
    // "?" in body OR OPERATIVE_RE.match(body)
    body.contains('?') || !scan_operative_re(body).is_empty()
}

// ---------------------------------------------------------------------------
// §12 — atom_terms, intent_relevance
// ---------------------------------------------------------------------------

/// Return the set of normalised terms for `atom.text`.
///
/// Mirrors Python `_atom_terms(atom) = set(_normalized_terms(atom.text))`.
fn atom_terms(atom: &IntentAtom) -> HashSet<String> {
    normalized_terms(&atom.text).into_iter().collect()
}

/// Score an atom for intent relevance.
///
/// Mirrors Python `_intent_relevance(atom)`.
fn intent_relevance(atom: &IntentAtom) -> i64 {
    let terms = atom_terms(atom);
    let stems = action_stems();
    let mut score: i64 = (terms.len() as i64) * 10;
    score += (scan_date_re(&atom.text).len() as i64) * 160;
    score += (scan_number_re(&atom.text).len() as i64) * 100;
    score += terms.iter().filter(|t| stems.contains(*t)).count() as i64 * 140;
    score += match atom.kind.as_str() {
        "fenced-code" | "indented-code" => 300,
        "table" => 280,
        "diagram" => 240,
        "list-item" => 220,
        "heading" => 180,
        "answer-fenced-code" | "answer-indented-code" => 300,
        "answer-table" => 280,
        "answer-diagram" => 240,
        "answer-list-item" => 220,
        "answer-heading" => 180,
        _ => 0,
    };
    score
}

/// Normalise atom text for duplicate detection.
///
/// Mirrors Python `_normalized_atom_text(atom)`.
fn normalized_atom_text(atom: &IntentAtom) -> String {
    let mut text = atom.text.clone();
    // For list items, strip the marker.
    if atom.kind == "list-item" || atom.kind == "answer-list-item" {
        if atom.kind == "answer-list-item" {
            // Strip speaker prefix if present.
            if let Some((_spk, body_cp)) = known_speaker(&text) {
                let chars: Vec<char> = text.chars().collect();
                text = chars[body_cp..].iter().collect();
            }
        }
        // Strip the list marker (`BULLET_LEAD.sub("", text, count=1)`).
        let list_marks = scan_list_marker_re(&text);
        if let Some(m) = list_marks.first() {
            let chars: Vec<char> = text.chars().collect();
            text = chars[m.end_cp..].iter().collect();
        }
    }
    // Collapse whitespace and casefold.
    text.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
}

// ---------------------------------------------------------------------------
// §13 — append_answer_subatoms
// ---------------------------------------------------------------------------

/// Append structured sub-atoms for one substantive answer turn.
///
/// Mirrors Python `_append_answer_subatoms(atoms, source, turn, dependencies)`.
///
/// Returns `(new_atom_ids, unsupported)`.
fn append_answer_subatoms(
    atoms: &mut Vec<IntentAtom>,
    source_chars: &[char],
    turn: &SpeakerTurn,
    dependencies: Vec<usize>,
) -> (Vec<usize>, Vec<String>) {
    let (parts, unsupported) = structured_atoms(source_chars, turn.start, turn.end);
    let mut ids: Vec<usize> = Vec::new();
    let base_id = atoms.len();

    for (part_index, part) in parts.iter().enumerate() {
        // Re-base part dependencies from their local (0-based) IDs to the
        // absolute IDs in the growing `atoms` list.
        let part_deps: Vec<usize> = part.dependencies.iter()
            .map(|d| base_id + d)
            .collect();

        // Merge with the turn-level dependencies, deduplicating.
        let mut all_deps: Vec<usize> = dependencies.clone();
        for d in &part_deps {
            if !all_deps.contains(d) {
                all_deps.push(*d);
            }
        }

        // Prefix-based kind adjustment (only for first part).
        let mut part_kind = format!("answer-{}", part.kind);
        if part_index == 0 {
            // Python: if speaker_prefix and is_list_line(text after prefix): kind = "list-item"
            if let Some((_spk, body_cp)) = known_speaker(&part.text) {
                let part_chars: Vec<char> = part.text.chars().collect();
                let after_speaker: String = part_chars[body_cp..].iter().collect();
                if is_list_line(&after_speaker) {
                    part_kind = "answer-list-item".to_string();
                }
            }
        }

        let atom = append_exact_atom(
            atoms, source_chars,
            part.start, part.end,
            &part_kind,
            Some(turn.speaker.as_str()),
            all_deps,
            false,
        );
        ids.push(atom.atom_id);
    }

    // Fallback: if no sub-atoms were produced, emit the whole turn.
    if ids.is_empty() {
        let atom = append_exact_atom(
            atoms, source_chars,
            turn.start, turn.end,
            "answer-turn",
            Some(turn.speaker.as_str()),
            dependencies,
            false,
        );
        ids.push(atom.atom_id);
    }

    (ids, unsupported)
}

// ---------------------------------------------------------------------------
// §14 — distinct_answer_ids, answer_coverage_ids
// ---------------------------------------------------------------------------

/// Return distinct (non-duplicate) answer atom IDs in order.
///
/// Mirrors Python `_distinct_answer_ids(atoms, answer_ids)`.
fn distinct_answer_ids(atoms: &[IntentAtom], answer_ids: &[usize]) -> Vec<usize> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut distinct: Vec<usize> = Vec::new();
    for &atom_id in answer_ids {
        if atom_id >= atoms.len() { continue; }
        let normalized = normalized_atom_text(&atoms[atom_id]);
        if seen.insert(normalized) {
            distinct.push(atom_id);
        }
    }
    distinct
}

/// Return the set of answer atom IDs that provide topical coverage.
///
/// Mirrors Python `_answer_coverage_ids(atoms, answer_ids)`.
fn answer_coverage_ids(atoms: &[IntentAtom], answer_ids: &[usize]) -> HashSet<usize> {
    let distinct_ids = distinct_answer_ids(atoms, answer_ids);
    let candidates: Vec<usize> = distinct_ids.iter()
        .filter(|&&id| id < atoms.len() && atoms[id].kind != "answer-heading")
        .copied()
        .collect();
    if candidates.is_empty() {
        return HashSet::new();
    }
    // Max by (intent_relevance, -start).
    let best = *candidates.iter().max_by_key(|&&id| {
        (intent_relevance(&atoms[id]), -(atoms[id].start as i64))
    }).unwrap();
    let mut covered: HashSet<usize> = HashSet::from([best]);

    // All list items (distinct).
    for &id in &distinct_ids {
        if id < atoms.len() && atoms[id].kind == "answer-list-item" {
            covered.insert(id);
        }
    }

    // Heading children: for each answer-heading, pick the best non-heading
    // child under that heading.
    for &id in answer_ids {
        if id >= atoms.len() || atoms[id].kind != "answer-heading" { continue; }
        let children: Vec<usize> = candidates.iter()
            .filter(|&&cid| cid < atoms.len() && atoms[cid].dependencies.contains(&id))
            .copied()
            .collect();
        if let Some(&best_child) = children.iter().max_by_key(|&&cid| {
            (intent_relevance(&atoms[cid]), -(atoms[cid].start as i64))
        }) {
            covered.insert(best_child);
        }
    }
    covered
}

// ---------------------------------------------------------------------------
// §15 — distinct_answer_ids helper for "hard" set
// ---------------------------------------------------------------------------

/// Return distinct answer IDs for the "hard required" set.
///
/// Mirrors Python `_distinct_answer_ids` used for active-answer selection.
fn distinct_answer_ids_for_hard(atoms: &[IntentAtom], answer_ids: &[usize]) -> Vec<usize> {
    distinct_answer_ids(atoms, answer_ids)
}

// ---------------------------------------------------------------------------
// §16 — embedded_user_fact_atoms
// ---------------------------------------------------------------------------

/// Recover embedded user facts from a mixed assistant-reaction+user-fact format.
///
/// Mirrors Python `_embedded_user_fact_atoms(source)`.
///
/// Returns an empty list for most inputs; only activates when the source
/// matches the repeated `timestamp — user: fact` pattern.
fn embedded_user_fact_atoms(source_chars: &[char]) -> Vec<IntentAtom> {
    let stop = source_chars.len();
    let lines = physical_lines(source_chars, 0, stop);

    let mut matches: Vec<(usize, usize)> = Vec::new();    // fact spans
    let mut assistant_spans: Vec<(usize, usize)> = Vec::new();
    let mut other_spans: Vec<(usize, usize)> = Vec::new();
    let mut prefix_spans: Vec<(usize, usize)> = Vec::new();
    let mut eligible_lines = 0usize;
    let mut assistant_scaffold_lines = 0usize;
    let mut other_lines = 0usize;
    let mut saw_fence = false;
    let mut fence_char: Option<char> = None;

    for (line_start, _line_end, visible) in &lines {
        let fence_ms = scan_fence_open_re(visible);
        if let Some(fm) = fence_ms.first() {
            saw_fence = true;
            let token = fm.groups.first().and_then(|g| g.as_ref())
                .map(|s| s.clone()).unwrap_or_default();
            let mc = token.chars().next().unwrap_or('`');
            if fence_char.is_none() {
                fence_char = Some(mc);
            } else if fence_char == Some(mc) {
                fence_char = None;
            }
            continue;
        }
        if fence_char.is_some() || visible.trim().is_empty() {
            continue;
        }
        eligible_lines += 1;

        // scan_embedded_user_fact_re expects the visible line; it returns the
        // "fact" group. The scan operates on `visible` but we need offsets
        // relative to `line_start` in the full source.
        let fact_ms = scan_embedded_user_fact_re(visible);
        if let Some(m) = fact_ms.first() {
            // groups[1] is the "fact" group.
            if let Some(Some(ref _fact_text)) = m.groups.get(1) {
                // scan_embedded_user_fact_re reports the fact group's span as the
                // match span (start_cp/end_cp), so the fact begins at m.start_cp
                // within `visible`.
                let fact_cp_start = line_start + m.start_cp;
                let fact_cp_end = line_start + m.end_cp;
                // prefix = visible[:start_cp]
                let prefix_visible: String = visible.chars().take(m.start_cp).collect();
                let prefix_trimmed = prefix_visible.trim_end();
                if !prefix_trimmed.is_empty() {
                    // chars().count() — code-point length, not byte length.
                    prefix_spans.push((*line_start, line_start + prefix_trimmed.chars().count()));
                }
                matches.push((fact_cp_start, fact_cp_end));
            }
        } else {
            // Check if this is an assistant-labelled line.
            if let Some((speaker, _)) = known_speaker(visible) {
                if KNOWN_ANSWER_SPEAKERS.contains(&speaker.as_str()) {
                    assistant_scaffold_lines += 1;
                    // chars().count() — code-point length, matches source_chars indexing.
                    assistant_spans.push((*line_start, line_start + visible.chars().count()));
                } else {
                    other_lines += 1;
                    other_spans.push((*line_start, line_start + visible.chars().count()));
                }
            } else {
                other_lines += 1;
                other_spans.push((*line_start, line_start + visible.chars().count()));
            }
        }
    }

    // Trigger condition (mirrors Python):
    // saw_fence or len(matches) < 4 or other_lines > 2
    // or abs(assistant_scaffold_lines - len(matches)) > 1
    // or len(matches) * 2 < eligible_lines - 2
    if saw_fence
        || matches.len() < 4
        || other_lines > 2
        || (assistant_scaffold_lines as isize - matches.len() as isize).abs() > 1
        || matches.len() * 2 < eligible_lines.saturating_sub(2)
    {
        return vec![];
    }

    // Build atoms from inventory (sorted by start, matching Python).
    let mut inventory: Vec<(usize, usize, &str, Option<&str>, bool)> = Vec::new();
    for &(s, e) in &matches {
        inventory.push((s, e, "embedded-timestamped-user-fact", Some("user"), true));
    }
    for &(s, e) in &assistant_spans {
        inventory.push((s, e, "embedded-assistant-turn", Some("assistant"), false));
    }
    for &(s, e) in &other_spans {
        inventory.push((s, e, "embedded-context-line", None, false));
    }
    for &(s, e) in &prefix_spans {
        inventory.push((s, e, "embedded-line-prefix", None, false));
    }
    // Sort by start (mirrors Python `sorted(inventory)`).
    inventory.sort_by_key(|&(s, ..)| s);

    let mut atoms: Vec<IntentAtom> = Vec::new();
    for (s, e, kind, speaker, required) in inventory {
        append_exact_atom(&mut atoms, source_chars, s, e, kind, speaker, vec![], required);
    }
    atoms
}

// ---------------------------------------------------------------------------
// §17 — find_document_exchange
// ---------------------------------------------------------------------------

/// Find a document-exchange pattern: operative request + pasted document +
/// authoritative answer.
///
/// Mirrors Python `_find_document_exchange(source, turns)`.
fn find_document_exchange<'a>(
    source_chars: &[char],
    turns: &'a [SpeakerTurn],
) -> Option<(&'a SpeakerTurn, usize, &'a SpeakerTurn)> {
    for (index, turn) in turns.iter().enumerate() {
        if !KNOWN_USER_SPEAKERS.contains(&turn.speaker.as_str()) {
            continue;
        }
        let first_body: String = source_chars[turn.body_start..turn.first_line_end]
            .iter().collect();
        let first_body_trimmed = first_body.trim();
        let continuation_start = turn.first_line_end;
        if !short_operative(first_body_trimmed) {
            continue;
        }
        let answers: Vec<&SpeakerTurn> = turns[index + 1..]
            .iter()
            .filter(|t| KNOWN_ANSWER_SPEAKERS.contains(&t.speaker.as_str())
                && substantive_turn(source_chars, t))
            .collect();
        if answers.is_empty() {
            continue;
        }
        let answer = *answers.last().unwrap();
        let continuation: String = source_chars[continuation_start..answer.start]
            .iter().collect();
        if continuation.len() < 800 {
            continue;
        }
        let immediate_payload: String = source_chars[continuation_start..turn.end]
            .iter().collect();
        if immediate_payload.len() < 800 {
            continue;
        }
        return Some((turn, continuation_start, answer));
    }
    None
}

// ---------------------------------------------------------------------------
// §18 — dependency_closure
// ---------------------------------------------------------------------------

/// Compute the transitive dependency closure of a set of atom IDs.
///
/// Mirrors Python `_dependency_closure(atom_by_id, initial)`.
pub fn dependency_closure(atom_by_id: &HashMap<usize, &IntentAtom>, initial: HashSet<usize>) -> HashSet<usize> {
    let mut closure = initial;
    let mut stack: Vec<usize> = closure.iter().copied().collect();
    while let Some(id) = stack.pop() {
        if let Some(atom) = atom_by_id.get(&id) {
            for &dep in &atom.dependencies {
                if closure.insert(dep) {
                    stack.push(dep);
                }
            }
        }
    }
    closure
}

// ---------------------------------------------------------------------------
// §19 — intent_atoms (top-level entry point)
// ---------------------------------------------------------------------------

/// Result of `intent_atoms`: all atoms, hard-required IDs, query-coverage IDs,
/// unsupported shapes, and mode details.
pub struct IntentAtomsResult {
    pub atoms: Vec<IntentAtom>,
    pub hard: HashSet<usize>,
    pub coverage: HashSet<usize>,
    pub unsupported: Vec<String>,
    pub mode: String,
    /// Mode-specific metadata spread into `selection_details` by the
    /// selection layer.  Mirrors the fifth element of Python's
    /// `_intent_atoms` return tuple (`mode_details` dict).
    pub mode_details: Map<String, Value>,
}

/// Produce intent-span atoms for `source`, handling all four topology modes:
/// - embedded-transcript
/// - document-exchange
/// - genuine-dialogue
/// - document
///
/// Mirrors Python `_intent_atoms(source)`.
pub fn intent_atoms(source: &str) -> IntentAtomsResult {
    let source_chars: Vec<char> = source.chars().collect();
    let total_cp = source_chars.len();

    // --- Mode 1: embedded-transcript ---
    let embedded = embedded_user_fact_atoms(&source_chars);
    if !embedded.is_empty() {
        let hard: HashSet<usize> = embedded.iter()
            .filter(|a| a.hard_required)
            .map(|a| a.atom_id)
            .collect();
        // Mirrors Python mode_details for embedded-transcript:
        // {"mode": "embedded-transcript", "embedded_user_fact_count": N,
        //  "embedded_assistant_turn_count": N, "embedded_context_line_count": N,
        //  "embedded_line_prefix_count": N}
        let user_fact_count = hard.len();
        let assistant_count = embedded.iter().filter(|a| a.kind == "embedded-assistant-turn").count();
        let context_line_count = embedded.iter().filter(|a| a.kind == "embedded-context-line").count();
        let prefix_count = embedded.iter().filter(|a| a.kind == "embedded-line-prefix").count();
        let mut mode_details = Map::new();
        mode_details.insert("mode".into(), json!("embedded-transcript"));
        mode_details.insert("embedded_user_fact_count".into(), json!(user_fact_count));
        mode_details.insert("embedded_assistant_turn_count".into(), json!(assistant_count));
        mode_details.insert("embedded_context_line_count".into(), json!(context_line_count));
        mode_details.insert("embedded_line_prefix_count".into(), json!(prefix_count));
        return IntentAtomsResult {
            atoms: embedded,
            hard,
            coverage: HashSet::new(),
            unsupported: vec![],
            mode: "embedded-transcript".to_string(),
            mode_details,
        };
    }

    let turns = speaker_turns(&source_chars);

    // --- Mode 2: document-exchange ---
    if let Some((request_turn, doc_start, answer_turn)) =
        find_document_exchange(&source_chars, &turns)
    {
        let mut atoms: Vec<IntentAtom> = Vec::new();
        let request_atom = append_exact_atom(
            &mut atoms, &source_chars,
            request_turn.start, request_turn.first_line_end,
            "operative-request",
            Some(request_turn.speaker.as_str()),
            vec![],
            true,
        );
        let (doc_atoms, unsupported) = structured_atoms(&source_chars, doc_start, answer_turn.start);
        let reindexed = reindex_atoms(&doc_atoms, atoms.len(), None, None);
        atoms.extend(reindexed);

        // Query coverage — find atoms that contain query terms.
        let request_body: String = source_chars[request_turn.body_start..request_turn.first_line_end]
            .iter().collect();
        let query = query_terms(&request_body);
        let mut coverage: HashSet<usize> = HashSet::new();
        let doc_ids: HashSet<usize> = atoms.iter()
            .filter(|a| doc_start <= a.start && a.start < answer_turn.start)
            .map(|a| a.atom_id)
            .collect();
        // For each term, find the best matching atom (shortest text, earliest start).
        for term in &query {
            let matches_for_term: Vec<&IntentAtom> = atoms.iter()
                .filter(|a| doc_ids.contains(&a.atom_id) && a.kind != "heading")
                .filter(|a| normalized_terms(&a.text).contains(term))
                .collect();
            if let Some(best) = matches_for_term.iter().min_by_key(|a| (a.text.len(), a.start)) {
                coverage.insert(best.atom_id);
            }
        }

        // protected_document_structure: true if any document atom has a
        // structured kind. Mirrors Python `_intent_atoms` document-exchange path.
        let protected_document = atoms.iter()
            .filter(|a| doc_start <= a.start && a.start < answer_turn.start)
            .any(|a| matches!(
                a.kind.as_str(),
                "fenced-code" | "indented-code" | "table" | "diagram"
                | "list-item" | "unsupported-unclosed-fence"
                | "unsupported-oversized-unstructured"
            ));

        // Sort query terms for stable output (mirrors Python `sorted(query)`).
        let mut query_sorted: Vec<String> = query.into_iter().collect();
        query_sorted.sort();

        // Mirrors Python mode_details for document-exchange:
        // {"mode": "document-exchange", "query_terms": [...],
        //  "protected_document_structure": bool,
        //  "derived_answer_omitted": {start, end, speaker, reason}}
        let mut mode_details = Map::new();
        mode_details.insert("mode".into(), json!("document-exchange"));
        mode_details.insert("query_terms".into(), Value::Array(
            query_sorted.into_iter().map(Value::String).collect()
        ));
        mode_details.insert("protected_document_structure".into(), json!(protected_document));
        mode_details.insert("derived_answer_omitted".into(), json!({
            "start": answer_turn.start,
            "end": answer_turn.end,
            "speaker": answer_turn.speaker,
            "reason": "generated-transform-not-source-evidence",
        }));

        return IntentAtomsResult {
            atoms,
            hard: HashSet::from([request_atom.atom_id]),
            coverage,
            unsupported,
            mode: "document-exchange".to_string(),
            mode_details,
        };
    }

    // --- Mode 3: genuine-dialogue ---
    if turns.len() >= 2 {
        let mut atoms: Vec<IntentAtom> = Vec::new();
        let mut hard: HashSet<usize> = HashSet::new();
        let mut coverage: HashSet<usize> = HashSet::new();
        let mut unsupported: Vec<String> = Vec::new();
        let mut consumed_answers: HashSet<usize> = HashSet::new();
        let mut turn_atom_ids: HashMap<usize, Vec<usize>> = HashMap::new();
        // Track non-substantive user turns for mode_details.discarded_turns.
        // Mirrors Python `discarded` list in `_intent_atoms` genuine-dialogue path.
        let mut discarded_turns: Vec<Value> = Vec::new();

        let substantive_user_indexes: Vec<usize> = turns.iter().enumerate()
            .filter(|(_, t)| KNOWN_USER_SPEAKERS.contains(&t.speaker.as_str())
                && substantive_turn(&source_chars, t))
            .map(|(i, _)| i)
            .collect();
        let last_substantive_user = substantive_user_indexes.last().copied();

        // Dialogue-prefix context (text before the first speaker turn).
        if turns[0].start > 0 {
            let prefix_text: String = source_chars[..turns[0].start].iter().collect();
            if !prefix_text.trim().is_empty() {
                let prefix_atom = append_exact_atom(
                    &mut atoms, &source_chars,
                    0, turns[0].start,
                    "dialogue-prefix-context",
                    None, vec![], true,
                );
                hard.insert(prefix_atom.atom_id);
            }
        }

        for index in 0..turns.len() {
            let turn = &turns[index];
            if !KNOWN_USER_SPEAKERS.contains(&turn.speaker.as_str()) {
                continue;
            }
            if !substantive_turn(&source_chars, turn) {
                // Record filler turns for mode_details, mirroring Python:
                // discarded.append({"speaker": turn.speaker, "start": turn.start,
                //                   "reason": "filler"})
                discarded_turns.push(json!({
                    "speaker": turn.speaker,
                    "start": turn.start,
                    "reason": "filler",
                }));
                continue;
            }

            // Check if this user turn depends on the preceding answer turn.
            let mut dependencies: Vec<usize> = Vec::new();
            let user_body = turn_body(&source_chars, turn);
            if index > 0 {
                let context_turn = &turns[index - 1];
                let context_body = turn_body(&source_chars, context_turn);
                let polarity = !scan_polarity_only_re(&user_body).is_empty()
                    && {
                        // fullmatch semantics.
                        let user_chars: Vec<char> = user_body.chars().collect();
                        scan_polarity_only_re(&user_body).first()
                            .map_or(false, |m| m.start_cp == 0 && m.end_cp == user_chars.len())
                    };
                let context_needed = polarity
                    || (user_body.len() <= 160 && context_body.contains('?'))
                    || (user_body.len() <= 280 && !scan_transform_followup_re(&user_body).is_empty());
                if context_needed
                    && KNOWN_ANSWER_SPEAKERS.contains(&context_turn.speaker.as_str())
                    && substantive_turn(&source_chars, context_turn)
                {
                    let context_ids = if let Some(ids) = turn_atom_ids.get(&(index - 1)) {
                        ids.clone()
                    } else {
                        let (ids, probs) = append_answer_subatoms(
                            &mut atoms, &source_chars, context_turn, vec![]);
                        unsupported.extend(probs);
                        turn_atom_ids.insert(index - 1, ids.clone());
                        ids
                    };
                    hard.extend(context_ids.iter().copied());
                    dependencies = context_ids;
                }
            }

            // Emit the user turn atom.
            let user_atom = append_exact_atom(
                &mut atoms, &source_chars,
                turn.start, turn.end,
                "substantive-user-turn",
                Some(turn.speaker.as_str()),
                dependencies,
                true,
            );
            turn_atom_ids.insert(index, vec![user_atom.atom_id]);
            hard.insert(user_atom.atom_id);

            // Find and process answer turns that follow.
            let mut answer_indexes: Vec<usize> = Vec::new();
            for answer_index in (index + 1)..turns.len() {
                let answer_turn = &turns[answer_index];
                if KNOWN_USER_SPEAKERS.contains(&answer_turn.speaker.as_str()) {
                    break;
                }
                if !consumed_answers.contains(&answer_index)
                    && KNOWN_ANSWER_SPEAKERS.contains(&answer_turn.speaker.as_str())
                    && substantive_turn(&source_chars, answer_turn)
                {
                    answer_indexes.push(answer_index);
                }
            }

            for &paired_answer_index in &answer_indexes {
                let answer_turn = &turns[paired_answer_index];
                let answer_ids = if let Some(ids) = turn_atom_ids.get(&paired_answer_index) {
                    ids.clone()
                } else {
                    let (ids, probs) = append_answer_subatoms(
                        &mut atoms, &source_chars,
                        answer_turn,
                        vec![user_atom.atom_id],
                    );
                    unsupported.extend(probs);
                    turn_atom_ids.insert(paired_answer_index, ids.clone());
                    ids
                };

                // Query coverage.
                let cov_ids = answer_coverage_ids(&atoms, &answer_ids);
                coverage.extend(cov_ids);

                // Hard set: active answer.
                let active_answer = Some(index) == last_substantive_user
                    && (user_body.contains('?')
                        || !scan_operative_re(&user_body).is_empty()
                        || {
                            // REVISION_MARKER_RE check — simple keyword scan.
                            let lb = user_body.to_lowercase();
                            (lb.contains("revised ") || lb.contains("updated ") || lb.contains("final "))
                                && (lb.contains("outline") || lb.contains("draft")
                                    || lb.contains("plan") || lb.contains("version"))
                        });
                if active_answer {
                    let distinct = distinct_answer_ids_for_hard(&atoms, &answer_ids);
                    hard.extend(distinct);
                }
                consumed_answers.insert(paired_answer_index);
            }
        }

        // Process any answer turns not yet consumed.
        for index in 0..turns.len() {
            if turn_atom_ids.contains_key(&index) { continue; }
            let turn = &turns[index];
            if KNOWN_ANSWER_SPEAKERS.contains(&turn.speaker.as_str())
                && substantive_turn(&source_chars, turn)
            {
                let (ids, probs) = append_answer_subatoms(
                    &mut atoms, &source_chars, turn, vec![]);
                unsupported.extend(probs);
                turn_atom_ids.insert(index, ids);
            }
        }

        if !atoms.is_empty() {
            let mut unsup_sorted: Vec<String> = unsupported.into_iter().collect();
            unsup_sorted.sort();
            unsup_sorted.dedup();
            // Mirrors Python mode_details for genuine-dialogue:
            // {"mode": "genuine-dialogue", "discarded_turns": discarded}
            let mut mode_details = Map::new();
            mode_details.insert("mode".into(), json!("genuine-dialogue"));
            mode_details.insert("discarded_turns".into(), Value::Array(discarded_turns));
            return IntentAtomsResult {
                atoms,
                hard,
                coverage,
                unsupported: unsup_sorted,
                mode: "genuine-dialogue".to_string(),
                mode_details,
            };
        }
    }

    // --- Mode 4: document ---
    let (atoms, unsupported) = structured_atoms(&source_chars, 0, total_cp);
    // Mirrors Python mode_details for document: {"mode": "document"}
    let mut mode_details_doc = Map::new();
    mode_details_doc.insert("mode".into(), json!("document"));
    IntentAtomsResult {
        atoms,
        hard: HashSet::new(),
        mode_details: mode_details_doc,
        coverage: HashSet::new(),
        unsupported,
        mode: "document".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_physical_lines_basic() {
        let src: Vec<char> = "hello\nworld\n".chars().collect();
        let lines = physical_lines(&src, 0, src.len());
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0], (0, 6, "hello".to_string()));
        assert_eq!(lines[1], (6, 12, "world".to_string()));
    }

    #[test]
    fn test_physical_lines_no_trailing_newline() {
        let src: Vec<char> = "foo\nbar".chars().collect();
        let lines = physical_lines(&src, 0, src.len());
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0].2, "foo");
        assert_eq!(lines[1].2, "bar");
    }

    #[test]
    fn test_known_speaker_user() {
        let result = known_speaker("user: hello world");
        assert!(result.is_some());
        let (spk, body) = result.unwrap();
        assert_eq!(spk, "user");
        assert_eq!(body, 6); // "user: " = 6 chars
    }

    #[test]
    fn test_known_speaker_unknown() {
        assert!(known_speaker("alice: hello").is_none());
    }

    #[test]
    fn test_heading_level_markdown() {
        assert_eq!(heading_level("## Hello"), Some(2));
        assert_eq!(heading_level("### World"), Some(3));
    }

    #[test]
    fn test_heading_level_bold() {
        assert_eq!(heading_level("**Bold Heading**"), Some(7));
    }

    #[test]
    fn test_is_list_line() {
        assert!(is_list_line("- item"));
        assert!(is_list_line("* item"));
        assert!(is_list_line("1. item"));
        assert!(!is_list_line("plain text"));
    }

    #[test]
    fn test_indent_width() {
        assert_eq!(indent_width("  hello"), 2);
        assert_eq!(indent_width("\thello"), 4);
        assert_eq!(indent_width("    hello"), 4);
    }

    #[test]
    fn test_sentence_spans_basic() {
        let para = "Hello world. This is a test.";
        let spans = sentence_spans(para, 0);
        assert!(spans.len() >= 1, "expected at least 1 span, got {:?}", spans);
    }

    #[test]
    fn test_structured_atoms_simple() {
        let src = "Hello world. This is a test.\n\nAnother paragraph.\n";
        let chars: Vec<char> = src.chars().collect();
        let (atoms, unsup) = structured_atoms(&chars, 0, chars.len());
        assert!(atoms.len() >= 1, "expected atoms, got empty");
        assert!(unsup.is_empty());
        // All atom texts must match source exactly.
        for atom in &atoms {
            let expected: String = chars[atom.start..atom.end].iter().collect();
            assert_eq!(atom.text, expected, "atom text mismatch at id={}", atom.atom_id);
        }
    }

    #[test]
    fn test_intent_atoms_document_mode() {
        let src = "Hello world. This is a test.\n\nAnother paragraph.\n";
        let result = intent_atoms(src);
        assert_eq!(result.mode, "document");
        assert!(!result.atoms.is_empty());
    }

    #[test]
    fn test_intent_atoms_dialogue_mode() {
        let src = "user: What is the answer?\nassistant: The answer is 42.\nuser: Thank you.\nassistant: You're welcome.\n";
        let result = intent_atoms(src);
        assert_eq!(result.mode, "genuine-dialogue", "mode was: {}", result.mode);
    }
}

#[test]
fn test_sentence_gdpr_para() {
    // Paragraph from sample30 row 26, starts at cp=47041 in source.
    // Oracle expects two sentence spans: [47041,47292) and [47293,47699).
    // This tests that "U.S." abbreviations are handled and "GDPR." is a boundary.
    let para = include_str!("/private/tmp/debug_para.txt");
    let spans = sentence_spans(para, 47041);
    eprintln!("spans: {:?}", spans.iter().map(|(s,e,_)| (*s,*e)).collect::<Vec<_>>());
    assert_eq!(spans.len(), 2, "expected 2 spans, got {}", spans.len());
    assert_eq!(spans[0].0, 47041);
    assert_eq!(spans[0].1, 47292);
    assert_eq!(spans[1].0, 47293);
    assert_eq!(spans[1].1, 47699);
}
