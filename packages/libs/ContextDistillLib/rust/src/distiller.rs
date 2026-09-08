//! Full-row distillation assembler — Rust port of CDL-01 Part 5.
//!
//! Ports the intent-span branch of `candidate_rows()` from
//! `distill_plus_converter.py`, plus `project_intent_trailer` and `_combine`.
//!
//! ## Public surface
//!
//! - [`DistilledRepresentation`] — serde-serialisable output row; field names
//!   are exact oracle JSON key names (snake_case with `#[serde(rename)]`).
//! - [`ContextDistiller`] — stateless assembler; `distill()` is the entry point.
//! - [`project_intent_trailer`] — port of Python `project_intent_trailer`.
//! - [`combine`] — port of Python `_combine`.
//!
//! ## Python function mirrors
//!
//! | Rust symbol                    | Python original                        |
//! |-------------------------------|----------------------------------------|
//! | `project_intent_trailer`       | `project_intent_trailer`               |
//! | `source_occurrences`           | `_source_occurrences`                  |
//! | `combine`                      | `_combine`                             |
//! | `ContextDistiller::distill`    | intent-span branch of `candidate_rows` |
//!
//! ## No regex, no external deps
//!
//! All pattern matching uses hand-written scanners mirroring Python Unicode
//! semantics.  No `regex` crate.  Serde + serde_json are the only deps.
//!
//! ## Index unit
//!
//! Code-point (char) indices throughout.  UTF-8 byte offsets are derived
//! exactly as in Python.

use serde::Serialize;
use serde_json::{json, Map, Value};

use crate::atoms::intent_atoms_with_peer_dialogue;
use crate::converter::ContextDistillConverter;
use crate::digest::{estimate_tokens, source_digest};
use crate::input::DistillationInput;
use crate::python_text::{is_python_whitespace, py_strip, py_word_char};
use crate::scanners::{scan_date_re, scan_quantity_value_re, ScannerMatch};
use crate::selection::{intent_span_selection_with_peer_dialogue, sentence_initial};
use crate::shape::classify_record;
use crate::terms::normalized_terms;

// ---------------------------------------------------------------------------
// Constants (mirrors distill_plus_converter.py)
// ---------------------------------------------------------------------------

/// Labels that are opaque taxonomy terms — always rejected.
/// Mirrors Python: `{"kind", "fdc"}`.
const OPAQUE_LABELS: &[&str] = &["kind", "fdc"];

/// Labels with source-anchoring rules.
/// Mirrors Python: `{"entity", "place", "country", "date", "quantity"}`.
const SUPPORTED_LABELS: &[&str] = &["entity", "place", "country", "date", "quantity"];

/// Values that are never valid entity names.
/// Mirrors Python `ENTITY_NON_NAME_VALUES`.
const ENTITY_NON_NAME_VALUES: &[&str] = &[
    "absolutely", "acknowledged", "certainly", "correct", "exactly",
    "got it", "great", "hello", "no", "noted", "okay", "perfect",
    "received", "right", "sounds good", "sure", "thanks",
    "thank you", "understood", "yes", "you're welcome", "you are welcome",
];

/// First-term prefixes that disqualify an entity value.
/// Mirrors Python `ENTITY_NON_NAME_PREFIXES`.
const ENTITY_NON_NAME_PREFIXES: &[&str] = &[
    "analyze", "answer", "check", "compare", "convert", "describe",
    "determine", "explain", "extract", "find", "identify", "list",
    "please", "provide", "review", "show", "summarize", "tell", "verify",
    "write",
];

/// ENTITY_CUE words (mirrors Python `ENTITY_CUE` regex group).
const ENTITY_CUE_WORDS: &[&str] = &[
    "called", "named", "project", "company", "person", "store", "city",
    "brand", "organization",
];

/// ENTITY_SUBJECT_CUE words (mirrors Python `ENTITY_SUBJECT_CUE` regex group).
const ENTITY_SUBJECT_CUE_WORDS: &[&str] = &[
    "agreed", "approved", "asked", "attended", "bought", "chose",
    "decided", "discovered", "joined", "lives", "moved", "ordered",
    "owns", "planned", "prefers", "said", "shipped", "works",
];

/// LOCATIVE_CUE words (mirrors Python `LOCATIVE_CUE` regex group).
const LOCATIVE_CUE_WORDS: &[&str] = &[
    "in", "at", "from", "to", "near", "around", "inside", "outside",
    "visited", "visiting", "located", "based", "lives", "lived", "moved",
    "travelled", "traveled", "traveling",
];

// ---------------------------------------------------------------------------
// §1 — source_occurrences
// ---------------------------------------------------------------------------

/// Find all case-insensitive word-boundary-delimited occurrences of `value`
/// in `source_chars`.
///
/// Returns a list of `(start_cp, end_cp)` pairs in code-point space.
///
/// Mirrors Python:
/// ```python
/// def _source_occurrences(source: str, value: str) -> list[re.Match]:
///     return list(re.finditer(
///         rf"(?<![\w]){re.escape(value)}(?![\w])", source, re.IGNORECASE))
/// ```
///
/// `(?<![\w])` is a negative lookbehind: the character before the match
/// must NOT be a `\w` character (Python Unicode word char: alnum + `_`).
/// `(?![\w])` is a negative lookahead: the character after must not be `\w`.
/// `re.IGNORECASE` uses Python's Unicode case-folding.
///
/// ## Python / Rust divergence
///
/// Python's `\w` matches Unicode alphanumerics and `_`; `py_word_char`
/// from `python_text` mirrors this with `char::is_alphanumeric() || c == '_'`.
fn source_occurrences(source_chars: &[char], value: &str) -> Vec<(usize, usize)> {
    let value_chars: Vec<char> = value.chars().collect();
    let vn = value_chars.len();
    let n = source_chars.len();
    if vn == 0 || vn > n {
        return Vec::new();
    }
    let mut result = Vec::new();
    let mut i = 0usize;
    while i + vn <= n {
        // Negative lookbehind: char before must not be \w.
        if i > 0 && py_word_char(source_chars[i - 1]) {
            i += 1;
            continue;
        }
        // Case-insensitive match of value_chars at source_chars[i..].
        // Python IGNORECASE uses simple Unicode case-folding (str.lower()).
        // We lower() each char individually and compare.
        let mut matched = true;
        for k in 0..vn {
            // Lowercase comparison mirrors Python re.IGNORECASE semantics.
            let sc: String = source_chars[i + k].to_lowercase().collect();
            let vc: String = value_chars[k].to_lowercase().collect();
            if sc != vc {
                matched = false;
                break;
            }
        }
        if matched {
            let end = i + vn;
            // Negative lookahead: char after match must not be \w.
            if end < n && py_word_char(source_chars[end]) {
                i += 1;
                continue;
            }
            result.push((i, end));
            i = end; // Advance past match (no overlapping).
        } else {
            i += 1;
        }
    }
    result
}

// ---------------------------------------------------------------------------
// §2 — Trailer grammar helpers
// ---------------------------------------------------------------------------

/// Match the trailer grammar `\(\*\[\s*(.*?)\s*\]\*\)` against the full
/// `trailer_chars` slice (fullmatch semantics).
///
/// Returns the range of the inner content (between `(*[` and `]*)`) if the
/// entire string matches the grammar.
///
/// Mirrors Python:
/// ```python
/// match = re.fullmatch(r"\(\*\[\s*(.*?)\s*\]\*\)", trailer, re.DOTALL)
/// ```
fn match_trailer_grammar(trailer_chars: &[char]) -> Option<std::ops::Range<usize>> {
    let n = trailer_chars.len();
    // Minimum: (*[ ]*)  = 6 chars.
    if n < 6 { return None; }
    // Must start with (*[
    if trailer_chars[0] != '(' || trailer_chars[1] != '*' || trailer_chars[2] != '[' {
        return None;
    }
    // Must end with ]*)
    if trailer_chars[n - 3] != ']' || trailer_chars[n - 2] != '*' || trailer_chars[n - 1] != ')' {
        return None;
    }
    // Inner range: indices 3..(n-3).
    Some(3..(n - 3))
}

/// Split the trailer inner string on commas that precede a field label.
///
/// Mirrors Python:
/// ```python
/// raw_fields = re.split(r",\s*(?=[A-Za-z][A-Za-z0-9_-]*\s*:)", match.group(1))
/// ```
///
/// A comma is a delimiter only when followed (after optional whitespace) by
/// a sequence matching `[A-Za-z][A-Za-z0-9_-]*\s*:` (a field label + colon).
/// A comma inside a numeric value (e.g. `quantity: 1,200`) is data.
fn split_trailer_fields(inner: &str) -> Vec<String> {
    let chars: Vec<char> = inner.chars().collect();
    let n = chars.len();
    let mut parts = Vec::new();
    let mut seg_start = 0usize;
    let mut i = 0usize;

    while i < n {
        if chars[i] == ',' {
            // Look ahead for \s*[A-Za-z][A-Za-z0-9_-]*\s*:
            let mut j = i + 1;
            while j < n && is_python_whitespace(chars[j]) { j += 1; }
            if is_field_label_start(&chars, j, n) {
                // Split here.
                parts.push(chars[seg_start..i].iter().collect::<String>());
                seg_start = i + 1;
            }
        }
        i += 1;
    }
    parts.push(chars[seg_start..].iter().collect::<String>());
    parts
}

/// Returns true if `chars[at..]` starts a field label: `[A-Za-z][A-Za-z0-9_-]*\s*:`.
///
/// Mirrors Python lookahead `(?=[A-Za-z][A-Za-z0-9_-]*\s*:)`.
fn is_field_label_start(chars: &[char], at: usize, limit: usize) -> bool {
    if at >= limit { return false; }
    // First char must be ASCII alpha.
    if !chars[at].is_ascii_alphabetic() { return false; }
    let mut i = at + 1;
    // Subsequent chars: [A-Za-z0-9_-]*.
    while i < limit {
        let c = chars[i];
        if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
            i += 1;
        } else {
            break;
        }
    }
    // Optional whitespace then colon.
    while i < limit && is_python_whitespace(chars[i]) { i += 1; }
    i < limit && chars[i] == ':'
}

// ---------------------------------------------------------------------------
// §3 — Case-insensitive scalar comparison
// ---------------------------------------------------------------------------

/// Case-insensitive comparison of two chars using Python IGNORECASE semantics.
///
/// For ASCII, lowercases A-Z to a-z.  For non-ASCII, uses Rust's
/// `char::to_lowercase()` — which covers Unicode case folding.
/// Python's IGNORECASE also uses Unicode case folding for non-ASCII.
#[inline]
fn char_eq_ci(a: char, b: char) -> bool {
    if a.is_ascii() && b.is_ascii() {
        a.to_ascii_lowercase() == b.to_ascii_lowercase()
    } else {
        let al: String = a.to_lowercase().collect();
        let bl: String = b.to_lowercase().collect();
        al == bl
    }
}

// ---------------------------------------------------------------------------
// §4 — Entity / locative cue search helpers
// ---------------------------------------------------------------------------

/// Check for `\bcue\s+(?:the\s+)?value\b` (case-insensitive).
///
/// Mirrors Python:
/// ```python
/// re.search(rf"\b{ENTITY_CUE}\s+(?:the\s+)?{re.escape(value)}\b",
///           source, re.IGNORECASE)
/// ```
fn has_cue_before_value(source_chars: &[char], cue: &str, value: &str, optional_the: bool) -> bool {
    let cue_chars: Vec<char> = cue.chars().collect();
    let value_chars: Vec<char> = value.chars().collect();
    let n = source_chars.len();
    let cn = cue_chars.len();
    let vn = value_chars.len();

    for i in 0..n {
        // \b before cue: char before must be non-word (or BOF).
        if i > 0 && py_word_char(source_chars[i - 1]) { continue; }
        if i + cn > n { continue; }
        // Match cue.
        let mut c_match = true;
        for k in 0..cn {
            if !char_eq_ci(source_chars[i + k], cue_chars[k]) { c_match = false; break; }
        }
        if !c_match { continue; }
        let after_cue = i + cn;
        // \b after cue (word boundary after the cue word).
        if after_cue < n && py_word_char(source_chars[after_cue]) { continue; }
        let mut j = after_cue;
        // \s+
        if j >= n || !is_python_whitespace(source_chars[j]) { continue; }
        while j < n && is_python_whitespace(source_chars[j]) { j += 1; }
        // (?:the\s+)?  — case-insensitive "the" followed by whitespace.
        if optional_the && j + 3 <= n {
            let the_chars = ['t', 'h', 'e'];
            let is_the = (0..3).all(|k| char_eq_ci(source_chars[j + k], the_chars[k]));
            // "the" must be followed by whitespace (or end of string that still
            // leaves room for value).
            if is_the && (j + 3 >= n || is_python_whitespace(source_chars[j + 3])) {
                // Consume "the" + following whitespace.
                j += 3;
                while j < n && is_python_whitespace(source_chars[j]) { j += 1; }
            }
        }
        // Match value.
        if j + vn > n { continue; }
        let mut v_match = true;
        for k in 0..vn {
            if !char_eq_ci(source_chars[j + k], value_chars[k]) { v_match = false; break; }
        }
        if !v_match { continue; }
        let end = j + vn;
        // \b after value.
        if end < n && py_word_char(source_chars[end]) { continue; }
        return true;
    }
    false
}

/// Check for `\bvalue\s+cue\b` (case-insensitive).
///
/// Mirrors Python:
/// ```python
/// re.search(rf"\b{re.escape(value)}\s+{ENTITY_SUBJECT_CUE}\b",
///           source, re.IGNORECASE)
/// ```
fn has_value_before_cue(source_chars: &[char], value: &str, cue: &str) -> bool {
    let value_chars: Vec<char> = value.chars().collect();
    let cue_chars: Vec<char> = cue.chars().collect();
    let n = source_chars.len();
    let vn = value_chars.len();
    let cn = cue_chars.len();

    for i in 0..n {
        if i > 0 && py_word_char(source_chars[i - 1]) { continue; }
        if i + vn > n { continue; }
        let mut v_match = true;
        for k in 0..vn {
            if !char_eq_ci(source_chars[i + k], value_chars[k]) { v_match = false; break; }
        }
        if !v_match { continue; }
        let after_value = i + vn;
        if after_value < n && py_word_char(source_chars[after_value]) { continue; }
        let mut j = after_value;
        // \s+
        if j >= n || !is_python_whitespace(source_chars[j]) { continue; }
        while j < n && is_python_whitespace(source_chars[j]) { j += 1; }
        // Match cue.
        if j + cn > n { continue; }
        let mut c_match = true;
        for k in 0..cn {
            if !char_eq_ci(source_chars[j + k], cue_chars[k]) { c_match = false; break; }
        }
        if !c_match { continue; }
        let end = j + cn;
        // \b after cue.
        if end < n && py_word_char(source_chars[end]) { continue; }
        return true;
    }
    false
}

/// Check for `\blabel\s*(?:is|:)?\s*value\b` (case-insensitive).
///
/// Mirrors Python:
/// ```python
/// re.search(rf"\b{label}\s*(?:is|:)?\s*{re.escape(value)}\b",
///           source, re.IGNORECASE)
/// ```
fn has_explicit_label(source_chars: &[char], label: &str, value: &str) -> bool {
    let label_chars: Vec<char> = label.chars().collect();
    let value_chars: Vec<char> = value.chars().collect();
    let n = source_chars.len();
    let ln = label_chars.len();
    let vn = value_chars.len();

    for i in 0..n {
        if i > 0 && py_word_char(source_chars[i - 1]) { continue; }
        if i + ln > n { continue; }
        let mut l_match = true;
        for k in 0..ln {
            if !char_eq_ci(source_chars[i + k], label_chars[k]) { l_match = false; break; }
        }
        if !l_match { continue; }
        let mut j = i + ln;
        // \s*
        while j < n && is_python_whitespace(source_chars[j]) { j += 1; }
        // (?:is|:)?
        if j < n {
            if j + 2 <= n
                && char_eq_ci(source_chars[j], 'i')
                && char_eq_ci(source_chars[j + 1], 's')
            {
                j += 2;
            } else if source_chars[j] == ':' {
                j += 1;
            }
        }
        // \s*
        while j < n && is_python_whitespace(source_chars[j]) { j += 1; }
        // Match value.
        if j + vn > n { continue; }
        let mut v_match = true;
        for k in 0..vn {
            if !char_eq_ci(source_chars[j + k], value_chars[k]) { v_match = false; break; }
        }
        if !v_match { continue; }
        let end = j + vn;
        // \b after value.
        if end < n && py_word_char(source_chars[end]) { continue; }
        return true;
    }
    false
}

// ---------------------------------------------------------------------------
// §5 — DATE_RE fullmatch / QUANTITY_VALUE_RE fullmatch
// ---------------------------------------------------------------------------

/// Check whether `value` fully matches the DATE_RE pattern.
///
/// Uses `scan_date_re` (findall) and verifies the single result spans 0..n.
///
/// Mirrors Python: `DATE_RE.fullmatch(value)`.
fn date_re_fullmatch(value: &str) -> bool {
    let n = value.chars().count();
    if n == 0 { return false; }
    let matches: Vec<ScannerMatch> = scan_date_re(value);
    matches.iter().any(|m| m.start_cp == 0 && m.end_cp == n)
}

/// Check whether `value` fully matches the QUANTITY_VALUE_RE pattern.
///
/// `scan_quantity_value_re` already has fullmatch semantics: it returns
/// a non-empty result only if the entire string matches.
///
/// Mirrors Python: `QUANTITY_VALUE_RE.fullmatch(value)`.
fn quantity_value_re_fullmatch(value: &str) -> bool {
    !scan_quantity_value_re(value).is_empty()
}

// ---------------------------------------------------------------------------
// §6 — Entity / locative context checks
// ---------------------------------------------------------------------------

/// Validate entity context per Python's rules.
///
/// Returns `Some(reason)` when the entity is rejected, `None` when accepted.
///
/// Mirrors Python's entity-validation block inside `project_intent_trailer`.
fn check_entity_context(
    source_chars: &[char],
    value: &str,
    occurrences: &[(usize, usize)],
) -> Option<&'static str> {
    // Mirror Python: if value.strip().casefold() in ENTITY_NON_NAME_VALUES
    let value_lower: String = value.to_lowercase();
    let value_lower_stripped = value_lower.trim();
    if ENTITY_NON_NAME_VALUES.contains(&value_lower_stripped) {
        return Some("unsafe-entity-context");
    }

    // Mirror Python: value_terms = _normalized_terms(value)
    //   if value_terms and value_terms[0] in ENTITY_NON_NAME_PREFIXES:
    let value_terms = normalized_terms(value);
    if let Some(first_term) = value_terms.first() {
        if ENTITY_NON_NAME_PREFIXES.contains(&first_term.as_str()) {
            return Some("unsafe-entity-context");
        }
    }

    // Mirror Python: capitalized_any = any(source[m.start():m.end()][:1].isupper() ...)
    // First char of each occurrence in the source (not the value) is tested.
    let capitalized_any = occurrences.iter().any(|&(start, _end)| {
        start < source_chars.len() && source_chars[start].is_uppercase()
    });

    // Mirror Python: capitalized = any(... and not _sentence_initial(source, m.start()) ...)
    // Both conditions must hold: starts uppercase AND is not sentence-initial.
    let capitalized = occurrences.iter().any(|&(start, _end)| {
        start < source_chars.len()
            && source_chars[start].is_uppercase()
            && !sentence_initial(source_chars, start)
    });

    // Mirror Python: cue = re.search(rf"\b{ENTITY_CUE}\s+(?:the\s+)?{re.escape(value)}\b", ...)
    let cue = ENTITY_CUE_WORDS
        .iter()
        .any(|&cw| has_cue_before_value(source_chars, cw, value, true));

    // Mirror Python: subject_cue = capitalized_any and re.search(...)
    let subject_cue = capitalized_any
        && ENTITY_SUBJECT_CUE_WORDS
            .iter()
            .any(|&cw| has_value_before_cue(source_chars, value, cw));

    if !capitalized && !cue && !subject_cue {
        Some("unsafe-entity-context")
    } else {
        None
    }
}

/// Validate place / country context.
///
/// Returns `Some(reason)` when rejected, `None` when accepted.
///
/// Mirrors Python's place/country-validation block inside `project_intent_trailer`.
fn check_locative_context(
    source_chars: &[char],
    value: &str,
    label: &str,
) -> Option<&'static str> {
    // Mirror Python: cue = re.search(rf"\b{LOCATIVE_CUE}\s+(?:the\s+)?{re.escape(value)}\b", ...)
    let cue = LOCATIVE_CUE_WORDS
        .iter()
        .any(|&cw| has_cue_before_value(source_chars, cw, value, true));

    // Mirror Python: explicit = re.search(rf"\b{label}\s*(?:is|:)?\s*{re.escape(value)}\b", ...)
    let explicit = has_explicit_label(source_chars, label, value);

    if !cue && !explicit {
        Some("unsafe-locative-context")
    } else {
        None
    }
}

// ---------------------------------------------------------------------------
// §7 — project_intent_trailer
// ---------------------------------------------------------------------------

/// Project only source-anchored, type-context-safe trailer fields.
///
/// Returns `(projected_trailer, projection_dict)` where:
///   - `projected_trailer` is the rebuilt `(*[ field: value, ... ]*)` string
///     (empty if no field was accepted).
///   - `projection_dict` is `{"accepted": [...], "rejected": [...]}`.
///
/// The `excluded_source_spans` key is NOT added here — the caller
/// (`ContextDistiller::distill`) adds it after calling this function, mirroring
/// Python's `projection["excluded_source_spans"] = excluded_projection_spans`.
///
/// Mirrors Python `project_intent_trailer(source, trailer)`.
pub fn project_intent_trailer(
    source_chars: &[char],
    trailer: &str,
) -> (String, Map<String, Value>) {
    let mut accepted: Vec<Value> = Vec::new();
    let mut rejected: Vec<Value> = Vec::new();

    // Mirrors Python: if not trailer: return "", {"accepted": [], "rejected": []}
    if trailer.is_empty() {
        let mut d = Map::new();
        d.insert("accepted".into(), json!([]));
        d.insert("rejected".into(), json!([]));
        return (String::new(), d);
    }

    // Mirror Python: match = re.fullmatch(r"\(\*\[\s*(.*?)\s*\]\*\)", trailer, re.DOTALL)
    let trailer_chars: Vec<char> = trailer.chars().collect();
    let inner_range = match match_trailer_grammar(&trailer_chars) {
        None => {
            rejected.push(json!({"raw": trailer, "reason": "invalid-trailer-grammar"}));
            let mut d = Map::new();
            d.insert("accepted".into(), Value::Array(accepted));
            d.insert("rejected".into(), Value::Array(rejected));
            return (String::new(), d);
        }
        Some(r) => r,
    };

    // Inner text: trailer_chars[inner_range], then .strip() (mirrors re.DOTALL inner).
    // Python: match.group(1) is the captured group between (*[ and ]*), with the
    // leading and trailing \s stripped by the `\s*(.*?)\s*` pattern.
    // We take the raw inner and trim manually.
    let inner_raw: String = trailer_chars[inner_range].iter().collect();
    let inner_str = inner_raw.trim().to_string();

    // Mirror Python: raw_fields = re.split(r",\s*(?=[A-Za-z][A-Za-z0-9_-]*\s*:)", inner)
    let raw_fields = split_trailer_fields(&inner_str);

    for raw in &raw_fields {
        // Mirror Python: field = raw.strip(); if not field: continue
        let field = raw.trim().to_string();
        if field.is_empty() { continue; }

        // Mirror Python: if ":" not in field: rejected; continue
        let colon_pos = match field.find(':') {
            None => {
                rejected.push(json!({"raw": field, "reason": "invalid-field"}));
                continue;
            }
            Some(p) => p,
        };

        // Mirror Python: label, value = (part.strip() for part in field.split(":", 1))
        //   label = label.casefold()
        let label_raw = field[..colon_pos].trim().to_string();
        let value = field[colon_pos + 1..].trim().to_string();
        let label = label_raw.to_lowercase();

        let occurrences = source_occurrences(source_chars, &value);

        // Determine rejection reason.
        let reason: Option<&str> = if OPAQUE_LABELS.contains(&label.as_str()) {
            // Mirror Python: if label in {"kind", "fdc"}: reason = "opaque-taxonomy"
            Some("opaque-taxonomy")
        } else if !SUPPORTED_LABELS.contains(&label.as_str()) {
            // Mirror Python: elif label not in {...}: reason = "unsupported-field-type"
            Some("unsupported-field-type")
        } else if occurrences.is_empty() {
            // Mirror Python: elif not occurrences: reason = "not-source-anchored"
            Some("not-source-anchored")
        } else if label == "entity" {
            // Mirror Python: entity context checks.
            check_entity_context(source_chars, &value, &occurrences)
        } else if label == "place" || label == "country" {
            // Mirror Python: place/country context checks.
            check_locative_context(source_chars, &value, &label)
        } else if label == "date" {
            // Mirror Python: elif label == "date" and not DATE_RE.fullmatch(value):
            if !date_re_fullmatch(&value) { Some("unsafe-date-context") } else { None }
        } else if label == "quantity" {
            // Mirror Python: elif label == "quantity" and not QUANTITY_VALUE_RE.fullmatch(value):
            if !quantity_value_re_fullmatch(&value) { Some("unsafe-quantity-context") } else { None }
        } else {
            None
        };

        // Mirror Python: item = {"field": label, "value": value, "raw": field}
        //   if reason: item["reason"] = reason; rejected.append(item)
        //   else: accepted.append(item)
        if let Some(r) = reason {
            rejected.push(json!({"field": label, "value": value, "raw": field, "reason": r}));
        } else {
            accepted.push(json!({"field": label, "value": value, "raw": field}));
        }
    }

    // Mirror Python: if accepted: projected = "(*[ field: value, ... ]*)"
    let projected = if !accepted.is_empty() {
        let body = accepted.iter().map(|item| {
            let f = item["field"].as_str().unwrap_or("");
            let v = item["value"].as_str().unwrap_or("");
            format!("{}: {}", f, v)
        }).collect::<Vec<_>>().join(", ");
        format!("(*[ {} ]*)", body)
    } else {
        String::new()
    };

    let mut d = Map::new();
    d.insert("accepted".into(), Value::Array(accepted));
    d.insert("rejected".into(), Value::Array(rejected));
    (projected, d)
}

// ---------------------------------------------------------------------------
// §8 — combine
// ---------------------------------------------------------------------------

/// Concatenates core text and trailer with a single space separator.
///
/// Mirrors Python `_combine`:
/// ```python
/// def _combine(core: str, trailer: str) -> str:
///     if core and trailer:
///         return f"{core} {trailer}"
///     return core or trailer
/// ```
///
/// Returns `""` when both are empty, the non-empty one when only one is
/// non-empty, or `"{core} {trailer}"` when both are non-empty.
pub fn combine(core: &str, trailer: &str) -> String {
    match (core.is_empty(), trailer.is_empty()) {
        (false, false) => format!("{} {}", core, trailer),
        (false, true)  => core.to_string(),
        (true, false)  => trailer.to_string(),
        (true, true)   => String::new(),
    }
}

// ---------------------------------------------------------------------------
// §9 — DistilledRepresentation
// ---------------------------------------------------------------------------

/// Full output row produced by the intent-span converter for one estate record.
///
/// Field names use snake_case with `serde(rename)` so that JSON serialisation
/// uses the exact oracle key names.  Mirrors the intent-span branch of
/// `candidate_rows()` in `distill_plus_converter.py`.
#[derive(Debug, Serialize)]
pub struct DistilledRepresentation {
    // --- Identity fields ---

    /// Schema version.  Mirrors `"schema_version": 1`.
    #[serde(rename = "schema_version")]
    pub schema_version: u32,

    /// Converter ruleset label.  Mirrors `"converter_version": "distill-plus-v1"`.
    #[serde(rename = "converter_version")]
    pub converter_version: String,

    /// Ruleset version.  Mirrors `"ruleset_version": INTENT_SPAN_VERSION`.
    #[serde(rename = "ruleset_version")]
    pub ruleset_version: String,

    /// Fully-qualified converter identifier.
    /// Mirrors `"converter_id": f"{candidate}@{candidate_ruleset}"`.
    #[serde(rename = "converter_id")]
    pub converter_id: String,

    /// SHA-256 hex digest of the source text.
    /// Mirrors `"source_sha256": source_digest(record.content)`.
    #[serde(rename = "source_sha256")]
    pub source_sha256: String,

    // --- Content fields ---

    /// Structural shape classification.
    /// Mirrors `"shape": decision.as_dict()`.
    pub shape: Value,

    /// Span offset unit label.  Always `"unicode-code-point"`.
    #[serde(rename = "span_offset_unit")]
    pub span_offset_unit: String,

    /// UTF-8 span offset unit label.  Always `"byte"`.
    #[serde(rename = "span_utf8_offset_unit")]
    pub span_utf8_offset_unit: String,

    /// Per-atom span metadata with UTF-8 byte offsets.
    /// Mirrors `"selected_source_spans": _portable_span_offsets(source, spans)`.
    #[serde(rename = "selected_source_spans")]
    pub selected_source_spans: Value,

    /// Exact source-atom concatenation (core text before trailer).
    /// Mirrors `"compact_core"`.
    #[serde(rename = "compact_core")]
    pub compact_core: String,

    /// Projected trailer actually applied (may be empty).
    /// Mirrors `"applied_enrichment_trailer"`.
    #[serde(rename = "applied_enrichment_trailer")]
    pub applied_enrichment_trailer: String,

    /// Combined text (compact_core + " " + applied_enrichment_trailer).
    /// Mirrors `"ai_text": _combine(intent_text, intent_trailer)`.
    #[serde(rename = "ai_text")]
    pub ai_text: String,

    /// Same as ai_text for intent-span.
    /// Mirrors `"mining_body"`.
    #[serde(rename = "mining_body")]
    pub mining_body: String,

    // --- Metrics ---

    /// Size and compression metrics dict.
    /// Mirrors `"metrics"` in `candidate_rows()`.
    pub metrics: Value,

    // --- Selection details ---

    /// Full selection metadata dict including trailer_projection.
    /// Mirrors `"selection_details": details` from `intent_span()`.
    #[serde(rename = "selection_details")]
    pub selection_details: Value,
}

// ---------------------------------------------------------------------------
// §10 — ContextDistiller
// ---------------------------------------------------------------------------

/// Renders selected named-peer turns as one attributed prose stream.
///
/// Splits on Python str.splitlines() boundaries (LF, VT, FF, CR, CR+LF,
/// FS/GS/RS, NEL, LS/PS), strips each line with Python str.strip() semantics
/// via py_strip, and formats lines matching the speaker-colon pattern as
/// `Speaker said: \u{201C}body\u{201D}` clauses joined by a single space.
/// Mirrors Python render_peer_attributed_prose exactly.
pub fn render_peer_attributed_prose(text: &str) -> String {
    // Python str.splitlines() splits on these code points:
    //   LF (0x0A), VT (0x0B), FF (0x0C), CR (0x0D),
    //   FS/GS/RS (0x1C-0x1E), NEL (0x85), LS/PS (0x2028-0x2029).
    // CR followed immediately by LF counts as one separator.
    let is_py_line_boundary = |c: char| -> bool {
        matches!(c as u32,
            0x0A | 0x0B | 0x0C | 0x0D | 0x1C | 0x1D | 0x1E | 0x85
            | 0x2028 | 0x2029)
    };

    let chars: Vec<char> = text.chars().collect();
    let mut lines: Vec<Vec<char>> = Vec::new();
    let mut i = 0;
    let n = chars.len();
    let mut line_start = 0;
    while i < n {
        if is_py_line_boundary(chars[i]) {
            lines.push(chars[line_start..i].to_vec());
            // Absorb CR+LF as one separator.
            if chars[i] == '\r' && i + 1 < n && chars[i + 1] == '\n' {
                i += 2;
            } else {
                i += 1;
            }
            line_start = i;
        } else {
            i += 1;
        }
    }
    if line_start < n {
        lines.push(chars[line_start..].to_vec());
    }

    lines.iter().filter_map(|raw_line| {
        // Python str.strip() semantics via py_strip.
        let stripped = py_strip(raw_line);
        if stripped.is_empty() { return None; }

        // Pattern: ^([A-Za-z][A-Za-z ._-]{0,31}):\s*(.*)$
        // Mirrors the Swift renderPeerAttributedProse scanner exactly.
        let mut cursor = 0;
        if !stripped[cursor].is_ascii_alphabetic() {
            return Some(stripped.iter().collect::<String>());
        }
        cursor += 1;
        let mut tail_count = 0usize;
        while cursor < stripped.len() && tail_count < 31 {
            let v = stripped[cursor] as u32;
            let allowed = (v >= 0x41 && v <= 0x5A)
                || (v >= 0x61 && v <= 0x7A)
                || v == 0x20  // space
                || v == 0x2E  // '.'
                || v == 0x5F  // '_'
                || v == 0x2D; // '-'
            if !allowed { break; }
            cursor += 1;
            tail_count += 1;
        }
        if cursor >= stripped.len() || stripped[cursor] != ':' {
            return Some(stripped.iter().collect::<String>());
        }
        let speaker: String = stripped[..cursor].iter().collect();
        cursor += 1; // skip ':'
        // Skip \s* after colon using Python whitespace semantics.
        while cursor < stripped.len() && is_python_whitespace(stripped[cursor]) {
            cursor += 1;
        }
        let body: String = stripped[cursor..].iter().collect();
        Some(format!("{speaker} said: “{body}”"))
    }).collect::<Vec<_>>().join(" ")
}

/// Stateless assembler for the intent-span distillation candidate.
///
/// Mirrors the intent-span branch of `candidate_rows()` in
/// `distill_plus_converter.py`.  All computation is deterministic and pure:
/// no `Date()`, no randomness, no I/O.
#[derive(Debug, Default)]
pub struct ContextDistiller;

impl ContextDistiller {
    fn complete_representation(&self, input: &DistillationInput, converter: ContextDistillConverter) -> DistilledRepresentation {
        let source = &input.original;
        let reduced = crate::complete_content::CompleteContentReducer::distill(source, estimate_tokens).ok();
        let core = reduced.as_ref().map(|r| r.text.as_str()).unwrap_or(source);
        let trailer = &input.enrichment_trailer;
        let combined = combine(core, trailer);
        let bytes = source.len();
        DistilledRepresentation {
            schema_version: converter.schema_version(), converter_version: converter.converter_version().into(),
            ruleset_version: "complete-form-visible-v6".into(), converter_id: converter.id().into(),
            source_sha256: source_digest(source),
            shape: serde_json::to_value(classify_record(source)).expect("shape serializes"),
            span_offset_unit: "unicode-code-point".into(), span_utf8_offset_unit: "byte".into(),
            selected_source_spans: if source.is_empty() { json!([]) } else { json!([{
                "start": 0, "end": source.chars().count(), "start_utf8_byte": 0,
                "end_utf8_byte": bytes, "kind": "complete-source"
            }]) },
            compact_core: core.into(), applied_enrichment_trailer: trailer.clone(),
            ai_text: combined.clone(), mining_body: combined.clone(),
            metrics: json!({"original_bytes": bytes, "original_tokens_est": estimate_tokens(source),
                "core_bytes": core.len(), "trailer_bytes": trailer.len(), "applied_trailer_bytes": trailer.len(),
                "distilled_bytes": combined.len(), "distilled_tokens_est": estimate_tokens(&combined),
                "compression_ratio_ppm": if bytes == 0 { 0 } else { combined.len() * 1_000_000 / bytes }}),
            selection_details: json!({"mode": "complete-form", "complete": true,
                "rendering": "complete-form-visible-v6", "count_unit": "tokens_estimate",
                "model_assistance": false, "fallback_unchanged": reduced.is_none()}),
        }
    }
    /// Creates a new distiller.
    pub fn new() -> Self { ContextDistiller }

    /// Distils one estate record into the full intent-span representation.
    ///
    /// # Parameters
    ///
    /// - `input`: Source text (`original`) and raw enrichment trailer.
    /// - `converter`: Explicit v22 or v23.2 attributed converter variant.
    ///
    /// # Returns
    ///
    /// A `DistilledRepresentation` whose fields match the oracle JSONL schema
    /// for the intent-span candidate.
    ///
    /// Mirrors Python:
    /// ```python
    /// intent_text, intent_spans, intent_details, intent_trailer = intent_span(
    ///     record.content, trailer)
    /// combined = _combine(intent_text, intent_trailer)
    /// ```
    pub fn distill(
        &self,
        input: &DistillationInput,
        converter: ContextDistillConverter,
    ) -> DistilledRepresentation {
        let source = &input.original;
        let trailer = &input.enrichment_trailer;
        if converter == ContextDistillConverter::CompleteFormV6 {
            return self.complete_representation(input, converter);
        }
        let peer_dialogue = matches!(
            converter, ContextDistillConverter::IntentSpanV23Attributed);

        // §10.1 — Shape classification.
        // Mirrors Python: decision = classify_record(record.content)
        let shape_decision = classify_record(source);
        let shape_value: Value = serde_json::to_value(&shape_decision)
            .expect("ShapeDecision must be serialisable");

        // §10.2 — Build projection source.
        //
        // Mirrors Python:
        //   omitted = mode_details.get("derived_answer_omitted")
        //   if isinstance(omitted, dict):
        //       projection_source = source[:start] + " " * (end - start) + source[end:]
        //       excluded_projection_spans.append({...})
        let source_chars: Vec<char> = source.chars().collect();
        let atoms_result = intent_atoms_with_peer_dialogue(source, peer_dialogue);
        let mode_details = &atoms_result.mode_details;

        let mut excluded_projection_spans: Vec<Value> = Vec::new();
        let projection_chars: Vec<char> = if let Some(omitted) = mode_details.get("derived_answer_omitted") {
            if let (Some(start_v), Some(end_v)) = (omitted.get("start"), omitted.get("end")) {
                if let (Some(start), Some(end)) = (start_v.as_u64(), end_v.as_u64()) {
                    let start = start as usize;
                    let end = end as usize;
                    if start <= end && end <= source_chars.len() {
                        excluded_projection_spans.push(json!({
                            "start": start,
                            "end": end,
                            "reason": "generated-transform-not-source-evidence",
                        }));
                        // Replace [start, end) with spaces (same code-point count).
                        let mut chars = source_chars.clone();
                        for ch in &mut chars[start..end] {
                            *ch = ' ';
                        }
                        chars
                    } else {
                        source_chars.clone()
                    }
                } else {
                    source_chars.clone()
                }
            } else {
                source_chars.clone()
            }
        } else {
            source_chars.clone()
        };

        // §10.3 — Project the enrichment trailer.
        //
        // Mirrors Python:
        //   projected_trailer, projection = project_intent_trailer(projection_source, trailer)
        //   projection["excluded_source_spans"] = excluded_projection_spans
        let (projected_trailer, mut projection) =
            project_intent_trailer(&projection_chars, trailer);
        projection.insert(
            "excluded_source_spans".into(),
            Value::Array(excluded_projection_spans),
        );

        // §10.4 — Run intent-span selection with correct budget.
        //
        // `intent_span_selection` takes `applied_trailer_bytes` which determines
        // the budget. The projected trailer's UTF-8 byte length is passed here,
        // mirroring Python's:
        //   budget = max(512, len(source.encode("utf-8")) * budget_percent // 100
        //                     - len(projected_trailer.encode("utf-8")))
        let applied_trailer_bytes = projected_trailer.len(); // UTF-8 bytes (str::len())
        let selection_result = intent_span_selection_with_peer_dialogue(
            source, applied_trailer_bytes, peer_dialogue);

        // §10.5 — Add trailer_projection to selection_details.
        //
        // Part 4 excluded this key from `selection_details`. Part 5 inserts it.
        // Mirrors Python: details["trailer_projection"] = projection
        let mut selection_details_map = selection_result.selection_details;
        let peer_mode = selection_details_map.get("mode")
            .and_then(Value::as_str) == Some("peer-dialogue");
        if peer_dialogue {
            selection_details_map.insert(
                "rendering".into(),
                json!(if peer_mode { "inline-attributed-prose" }
                      else { "source-exact" }),
            );
        }
        selection_details_map.insert(
            "trailer_projection".into(),
            Value::Object(projection),
        );
        let selection_details_value = Value::Object(selection_details_map);

        // §10.6 — _combine.
        // Mirrors Python: combined = _combine(intent_text, intent_trailer)
        let rendered_core = if peer_dialogue && peer_mode {
            render_peer_attributed_prose(&selection_result.compact_core)
        } else {
            selection_result.compact_core
        };
        let combined = combine(&rendered_core, &projected_trailer);

        // §10.7 — Metrics.
        // Mirrors Python: metrics dict inside candidate_rows().
        let original_bytes = source.len() as u64; // str::len() = UTF-8 bytes
        let core_bytes = rendered_core.len() as u64;
        let trailer_bytes = trailer.len() as u64;
        let applied_trailer_bytes_u64 = projected_trailer.len() as u64;
        let distilled_bytes = combined.len() as u64;
        // Python: compression_ratio_ppm = combined_bytes * 1_000_000 // original_bytes
        //   if original_bytes else 0
        let compression_ratio_ppm: u64 = if original_bytes > 0 {
            distilled_bytes * 1_000_000 / original_bytes
        } else {
            0
        };
        let metrics_value = json!({
            "original_bytes":        original_bytes,
            "original_tokens_est":   estimate_tokens(source),
            "core_bytes":            core_bytes,
            "trailer_bytes":         trailer_bytes,
            "applied_trailer_bytes": applied_trailer_bytes_u64,
            "distilled_bytes":       distilled_bytes,
            "distilled_tokens_est":  estimate_tokens(&combined),
            "compression_ratio_ppm": compression_ratio_ppm,
        });

        // §10.8 — Source SHA-256.
        // Mirrors Python: digest = source_digest(record.content)
        let sha256 = source_digest(source);

        // §10.9 — Converter identity fields.
        // Mirrors Python:
        //   candidate_ruleset = INTENT_SPAN_VERSION  # for intent-span
        //   converter_id = f"{candidate}@{candidate_ruleset}"
        let converter_id = converter.id();
        let ruleset_version = converter.ruleset_version();

        // §10.10 — Assemble DistilledRepresentation.
        DistilledRepresentation {
            schema_version:             converter.schema_version(),
            converter_version:          converter.converter_version().to_string(),
            ruleset_version:            ruleset_version.to_string(),
            converter_id:               converter_id.to_string(),
            source_sha256:              sha256,
            shape:                      shape_value,
            span_offset_unit:           "unicode-code-point".to_string(),
            span_utf8_offset_unit:      "byte".to_string(),
            selected_source_spans:      Value::Array(selection_result.selected_source_spans),
            compact_core:               rendered_core,
            applied_enrichment_trailer: projected_trailer,
            ai_text:                    combined.clone(),
            mining_body:                combined,
            metrics:                    metrics_value,
            selection_details:          selection_details_value,
        }
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_combine_both() {
        assert_eq!(combine("core", "(*[ x ]*)"),"core (*[ x ]*)");
    }

    #[test]
    fn test_combine_no_trailer() {
        assert_eq!(combine("core", ""), "core");
    }

    #[test]
    fn test_combine_no_core() {
        assert_eq!(combine("", "(*[ x ]*)"),"(*[ x ]*)");
    }

    #[test]
    fn test_combine_both_empty() {
        assert_eq!(combine("", ""), "");
    }

    #[test]
    fn test_source_occurrences_basic() {
        let chars: Vec<char> = "Hello world".chars().collect();
        let occ = source_occurrences(&chars, "world");
        assert_eq!(occ, vec![(6, 11)]);
    }

    #[test]
    fn test_source_occurrences_case_insensitive() {
        let chars: Vec<char> = "Hello WORLD".chars().collect();
        let occ = source_occurrences(&chars, "world");
        assert_eq!(occ, vec![(6, 11)]);
    }

    #[test]
    fn test_source_occurrences_no_mid_word() {
        // "worlds" should NOT match "world" (mid-word blocked by lookahead).
        let chars: Vec<char> = "worlds".chars().collect();
        let occ = source_occurrences(&chars, "world");
        assert!(occ.is_empty());
    }

    #[test]
    fn test_project_intent_trailer_empty() {
        let chars: Vec<char> = "".chars().collect();
        let (proj, dict) = project_intent_trailer(&chars, "");
        assert!(proj.is_empty());
        assert_eq!(dict["accepted"], json!([]));
        assert_eq!(dict["rejected"], json!([]));
    }

    #[test]
    fn test_project_intent_trailer_invalid_grammar() {
        let chars: Vec<char> = "hello world".chars().collect();
        let (proj, dict) = project_intent_trailer(&chars, "not-a-trailer");
        assert!(proj.is_empty());
        let rejected = dict["rejected"].as_array().unwrap();
        assert_eq!(rejected.len(), 1);
        assert_eq!(rejected[0]["reason"], "invalid-trailer-grammar");
    }

    #[test]
    fn test_project_intent_trailer_opaque() {
        let source = "hello world";
        let chars: Vec<char> = source.chars().collect();
        let (proj, dict) = project_intent_trailer(&chars, "(*[ kind: general works ]*)");
        assert!(proj.is_empty());
        let rejected = dict["rejected"].as_array().unwrap();
        assert_eq!(rejected[0]["reason"], "opaque-taxonomy");
    }

    #[test]
    fn test_project_intent_trailer_not_anchored() {
        let source = "A sunny day";
        let chars: Vec<char> = source.chars().collect();
        // "moon" does not appear in source → not-source-anchored.
        let (proj, dict) = project_intent_trailer(&chars, "(*[ entity: moon ]*)");
        assert!(proj.is_empty());
        let rejected = dict["rejected"].as_array().unwrap();
        assert_eq!(rejected[0]["reason"], "not-source-anchored");
    }

    #[test]
    fn test_date_re_fullmatch_valid() {
        assert!(date_re_fullmatch("2024-10-01"));
        assert!(date_re_fullmatch("2024"));
        assert!(date_re_fullmatch("1/2/2024"));
    }

    #[test]
    fn test_date_re_fullmatch_invalid() {
        assert!(!date_re_fullmatch("not-a-date"));
        assert!(!date_re_fullmatch(""));
    }

    #[test]
    fn test_distiller_smoke() {
        let input = DistillationInput::new("Hello world. This is a test.", "");
        let distiller = ContextDistiller::new();
        let result = distiller.distill(&input, ContextDistillConverter::CompleteFormV6);
        assert!(!result.compact_core.is_empty());
        assert_eq!(result.schema_version, 1);
        assert_eq!(result.converter_version, "distill-plus-v1");
        assert_eq!(result.span_offset_unit, "unicode-code-point");
        assert_eq!(result.span_utf8_offset_unit, "byte");
    }
}
