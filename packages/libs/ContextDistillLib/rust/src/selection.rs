//! Selection layer — Rust port of the intent-span atom selector from
//! `distill_plus_converter.py`.
//!
//! # What this module provides
//!
//! Given a source string and the byte length of the already-projected
//! enrichment trailer, this module selects which atoms to include in the
//! distilled output using the same greedy ranked-utility algorithm as
//! Python's `intent_span`.
//!
//! ## Scope (CDL-01 Part 4)
//!
//! - `sentence_initial`     — mirrors `_sentence_initial`
//! - `selection_bytes`      — mirrors `_selection_bytes`
//! - `overlap_permille`     — mirrors `_overlap_permille`
//! - `render_exact`         — mirrors `_render_exact`
//! - `portable_span_offsets`— mirrors `_portable_span_offsets`
//! - `IntentSpanResult`     — typed result struct
//! - `intent_span_selection`— mirrors `intent_span` (body only; trailer
//!   projection and `_combine` are excluded per CDL-01 Part 4 spec)
//!
//! ## Index unit
//!
//! All `start`/`end` fields are **Unicode code-point indices** (Python `str`
//! semantics).  UTF-8 byte offsets (`start_utf8_byte`, `end_utf8_byte`) are
//! derived and stored alongside each span.
//!
//! ## No regex
//!
//! Zero use of the `regex` crate.  `sentence_initial` is a hand-written
//! backward scanner; all other pattern work delegates to `crate::atoms`
//! (which itself delegates to `crate::scanners`).
//!
//! ## Python function mirrors
//!
//! | Rust function            | Python original             |
//! |--------------------------|-----------------------------|
//! | `sentence_initial`       | `_sentence_initial`         |
//! | `selection_bytes`        | `_selection_bytes`          |
//! | `overlap_permille`       | `_overlap_permille`         |
//! | `render_exact`           | `_render_exact`             |
//! | `portable_span_offsets`  | `_portable_span_offsets`    |
//! | `intent_span_selection`  | `intent_span` (body)        |

use std::collections::{HashMap, HashSet};

use serde_json::{json, Map, Value};

use crate::atoms::{dependency_closure, intent_atoms, IntentAtom};
use crate::terms::normalized_terms;
use crate::scanners::{scan_date_re, scan_number_re, scan_list_marker_re};
use crate::atoms::known_speaker;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Intent-span version tag embedded in every `selection_details` dict.
/// Mirrors Python `INTENT_SPAN_VERSION = "intent-span-v22-authority-closure"`.
const INTENT_SPAN_VERSION: &str = "intent-span-v22-authority-closure";

/// Action words used by `intent_relevance`.  Mirrors Python `ACTION_WORDS`.
const ACTION_WORDS: &[&str] = &[
    "agreed", "approved", "assigned", "build", "built", "cancel", "changed",
    "choose", "decided", "deliver", "due", "failed", "fixed", "launch",
    "must", "need", "planned", "prefer", "preferred", "prefers",
    "preference", "favorite", "routine", "regularly", "usually", "required",
    "ship", "shipped", "should", "started", "stop", "will", "won't",
];

/// Compute the set of normalised action stems (lazy, per-call).
/// Mirrors Python `ACTION_STEMS = frozenset(_normalized_terms(w) for w in ACTION_WORDS)`.
fn action_stems() -> HashSet<String> {
    let mut stems = HashSet::new();
    for &word in ACTION_WORDS {
        for term in normalized_terms(word) {
            stems.insert(term);
        }
    }
    stems
}

// ---------------------------------------------------------------------------
// §1 — sentence_initial
// ---------------------------------------------------------------------------

/// Return true when code-point position `start` is sentence-initial in
/// `source_chars`.
///
/// Mirrors Python `_sentence_initial(source, start)`:
/// ```python
/// cursor = start - 1
/// while cursor >= 0:
///     if source[cursor] == "\n":   return True
///     if source[cursor].isspace() or source[cursor] in "-*>•([{\"'":
///         cursor -= 1; continue
///     break
/// return cursor < 0 or source[cursor] in ".!?\n"
/// ```
///
/// Walking backward from `start - 1`: newlines always signal sentence-
/// initial; whitespace and certain punctuation are skipped; anything else
/// is a sentence-final character test.
///
/// Python `.isspace()` includes `\t`, `\n`, `\r`, `\f`, `\v`, and standard
/// Unicode spaces.  Rust `char::is_whitespace()` matches the same set for
/// valid Unicode scalars — no divergence for the text corpus in scope.
pub fn sentence_initial(source_chars: &[char], start: usize) -> bool {
    // Guard: nothing before the first character is always sentence-initial.
    if start == 0 {
        return true;
    }
    let mut cursor = start as isize - 1;
    while cursor >= 0 {
        let ch = source_chars[cursor as usize];
        if ch == '\n' {
            return true;
        }
        // Python: source[cursor].isspace() or source[cursor] in "-*>•([{\"'"
        if ch.is_whitespace() || "-*>•([{\"'".contains(ch) {
            cursor -= 1;
            continue;
        }
        break;
    }
    // cursor < 0 → we reached BOF without finding a non-space non-punc char.
    if cursor < 0 {
        return true;
    }
    // Otherwise the character at cursor is the non-space, non-punc char
    // immediately before `start`.  Sentence-final if it is ".!?\n".
    let ch = source_chars[cursor as usize];
    ch == '.' || ch == '!' || ch == '?' || ch == '\n'
}

// ---------------------------------------------------------------------------
// §2 — selection_bytes
// ---------------------------------------------------------------------------

/// Compute the UTF-8 byte size of the rendered output for `selected` atoms.
///
/// Atoms are sorted by `start`.  Gap characters between consecutive atoms are
/// included verbatim when they are pure whitespace; otherwise they are counted
/// as 2 bytes (`"\n\n"`).
///
/// Mirrors Python `_selection_bytes(source, atoms, selected)`:
/// ```python
/// chosen = sorted((a for a in atoms if a.atom_id in selected),
///                 key=lambda a: a.start)
/// size = sum(len(a.text.encode("utf-8")) for a in chosen)
/// for left, right in zip(chosen, chosen[1:]):
///     gap = source[left.end:right.start]
///     size += len(gap.encode("utf-8")) if not gap.strip() else 2
/// return size
/// ```
///
/// `source_chars` is the code-point slice so gap extraction is O(gap size).
pub fn selection_bytes(source_chars: &[char], atoms: &[IntentAtom], selected: &HashSet<usize>) -> usize {
    let mut chosen: Vec<&IntentAtom> = atoms.iter()
        .filter(|a| selected.contains(&a.atom_id))
        .collect();
    chosen.sort_by_key(|a| a.start);

    if chosen.is_empty() {
        return 0;
    }

    // Sum atom UTF-8 sizes.
    let mut size: usize = chosen.iter().map(|a| a.text.len()).sum(); // UTF-8 bytes

    // Add gap sizes between consecutive chosen atoms.
    for window in chosen.windows(2) {
        let left = window[0];
        let right = window[1];
        // Gap as Python code-point slice.
        let gap: String = source_chars[left.end..right.start].iter().collect();
        if gap.trim().is_empty() {
            // Pure whitespace — include verbatim byte count.
            size += gap.len(); // gap is ASCII whitespace so bytes == chars
        } else {
            // Non-whitespace gap → "\n\n" (2 bytes).
            size += 2;
        }
    }
    size
}

// ---------------------------------------------------------------------------
// §3 — overlap_permille
// ---------------------------------------------------------------------------

/// Compute Jaccard overlap as a per-mille integer.
///
/// Mirrors Python `_overlap_permille(left, right)`:
/// ```python
/// if not left or not right: return 0
/// return len(left & right) * 1000 // len(left | right)
/// ```
///
/// Integer division floors (Python `//` and Rust `/` agree for non-negative
/// values — no divergence).
pub fn overlap_permille(left: &HashSet<String>, right: &HashSet<String>) -> i64 {
    if left.is_empty() || right.is_empty() {
        return 0;
    }
    let intersection = left.iter().filter(|t| right.contains(*t)).count();
    let union = left.iter().chain(right.iter()).collect::<HashSet<_>>().len();
    (intersection * 1000 / union) as i64
}

// ---------------------------------------------------------------------------
// §4 — atom_terms / intent_relevance / normalized_atom_text
// (local re-implementations that mirror atoms.rs private helpers;
//  duplicated here so selection.rs is self-contained)
// ---------------------------------------------------------------------------

/// Return the set of normalised terms for `atom.text`.
/// Mirrors Python `_atom_terms(atom) = set(_normalized_terms(atom.text))`.
fn atom_terms(atom: &IntentAtom) -> HashSet<String> {
    normalized_terms(&atom.text).into_iter().collect()
}

/// Score an atom for intent relevance.
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
/// Mirrors Python `_normalized_atom_text(atom)`.
fn normalized_atom_text(atom: &IntentAtom) -> String {
    let mut text = atom.text.clone();
    // For list items, strip the marker (Python BULLET_LEAD.sub).
    if atom.kind == "list-item" || atom.kind == "answer-list-item" {
        if atom.kind == "answer-list-item" {
            if let Some((_spk, body_cp)) = known_speaker(&text) {
                let chars: Vec<char> = text.chars().collect();
                text = chars[body_cp..].iter().collect();
            }
        }
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
// §5 — render_exact
// ---------------------------------------------------------------------------

/// A span dict ready for serialisation (before UTF-8 byte offset attachment).
#[derive(Debug, Clone)]
pub struct SpanInfo {
    pub atom_id: usize,
    pub start: usize,
    pub end: usize,
    pub kind: String,
    pub speaker: Option<String>,
    pub dependencies: Vec<usize>,
    pub hard_required: bool,
}

/// Render chosen atoms into a single string and span list.
///
/// Atoms are sorted by `(start, end)`.  Gaps between consecutive atoms are
/// included verbatim when pure whitespace; otherwise they are replaced with
/// `"\n\n"`.
///
/// Mirrors Python `_render_exact(source, atoms, selected, hard_ids=None)`.
///
/// The load-bearing assertion from Python (`atom.text == source[a.start:a.end]`)
/// is checked via `debug_assert!` — it holds by construction but is skipped in
/// release builds for speed.
pub fn render_exact(
    source_chars: &[char],
    atoms: &[IntentAtom],
    selected: &HashSet<usize>,
    hard: &HashSet<usize>,
) -> (String, Vec<SpanInfo>) {
    let mut chosen: Vec<&IntentAtom> = atoms.iter()
        .filter(|a| selected.contains(&a.atom_id))
        .collect();
    // Sort by (start, end) — mirrors Python `key=lambda atom: (atom.start, atom.end)`.
    chosen.sort_by_key(|a| (a.start, a.end));

    let mut pieces: Vec<String> = Vec::new();
    let mut spans: Vec<SpanInfo> = Vec::new();
    let mut previous_end: Option<usize> = None;

    for atom in &chosen {
        if let Some(prev_end) = previous_end {
            if atom.start > prev_end {
                let gap: String = source_chars[prev_end..atom.start].iter().collect();
                if gap.trim().is_empty() {
                    // Pure whitespace gap — include verbatim.
                    pieces.push(gap);
                } else {
                    // Non-whitespace gap → separator.
                    pieces.push("\n\n".to_string());
                }
            }
        }

        // Load-bearing check: atom text must exactly match source slice.
        // (held by construction in append_exact_atom)
        let source_slice: String = source_chars[atom.start..atom.end].iter().collect();
        debug_assert_eq!(
            atom.text, source_slice,
            "atom text diverged from source at [{},{})",
            atom.start, atom.end
        );

        pieces.push(atom.text.clone());
        spans.push(SpanInfo {
            atom_id: atom.atom_id,
            start: atom.start,
            end: atom.end,
            kind: atom.kind.clone(),
            speaker: atom.speaker.clone(),
            dependencies: atom.dependencies.clone(),
            hard_required: atom.hard_required || hard.contains(&atom.atom_id),
        });
        previous_end = Some(atom.end);
    }

    (pieces.concat(), spans)
}

// ---------------------------------------------------------------------------
// §6 — portable_span_offsets
// ---------------------------------------------------------------------------

/// Attach `start_utf8_byte` and `end_utf8_byte` fields to every span.
///
/// Mirrors Python `_portable_span_offsets(source, spans)`:
/// ```python
/// positions = sorted({pos for span in spans
///                     for pos in (span["start"], span["end"])})
/// utf8_offsets: dict[int, int] = {}
/// previous, byte_offset = 0, 0
/// for position in positions:
///     byte_offset += len(source[previous:position].encode("utf-8"))
///     utf8_offsets[position] = byte_offset
///     previous = position
/// ```
///
/// Code-point positions are the index unit; UTF-8 byte offsets are derived by
/// walking the source exactly once in position order.
pub fn portable_span_offsets(source_chars: &[char], spans: &[SpanInfo]) -> Vec<Value> {
    // Collect and sort all distinct code-point positions.
    let mut positions: Vec<usize> = spans.iter()
        .flat_map(|s| [s.start, s.end])
        .collect();
    positions.sort_unstable();
    positions.dedup();

    // Walk positions in order, accumulating UTF-8 byte offset.
    let mut utf8_offsets: HashMap<usize, usize> = HashMap::new();
    let mut previous: usize = 0;
    let mut byte_offset: usize = 0;
    for &position in &positions {
        // Encode the slice [previous, position) as UTF-8.
        let slice: String = source_chars[previous..position].iter().collect();
        byte_offset += slice.len(); // .len() on String gives UTF-8 byte count
        utf8_offsets.insert(position, byte_offset);
        previous = position;
    }

    // Build output list mirroring Python dict structure.
    spans.iter().map(|span| {
        json!({
            "atom_id": span.atom_id,
            "start": span.start,
            "end": span.end,
            "kind": span.kind,
            "speaker": span.speaker,
            "dependencies": span.dependencies,
            "hard_required": span.hard_required,
            "start_utf8_byte": utf8_offsets.get(&span.start).copied().unwrap_or(0),
            "end_utf8_byte": utf8_offsets.get(&span.end).copied().unwrap_or(0),
        })
    }).collect()
}

// ---------------------------------------------------------------------------
// §7 — IntentSpanResult
// ---------------------------------------------------------------------------

/// Result of `intent_span_selection`.
pub struct IntentSpanResult {
    /// Verbatim core text assembled from selected atoms.  Matches oracle
    /// `compact_core`.
    pub compact_core: String,
    /// Span list with UTF-8 byte offsets.  Matches oracle
    /// `selected_source_spans`.
    pub selected_source_spans: Vec<Value>,
    /// Selection metadata (all fields except `trailer_projection`).  Matches
    /// oracle `selection_details` minus `trailer_projection`.
    pub selection_details: Map<String, Value>,
}

// ---------------------------------------------------------------------------
// §8 — intent_span_selection
// ---------------------------------------------------------------------------

/// Select atoms and build the intent-span core and span list.
///
/// This is the Rust port of the body of Python `intent_span(source, trailer)`
/// excluding `project_intent_trailer` / `_combine` (CDL-01 Part 4 scope).
///
/// # Parameters
///
/// - `source`: the raw source text.
/// - `applied_trailer_bytes`: the UTF-8 byte length of the already-projected
///   enrichment trailer (`applied_enrichment_trailer` in the oracle).  This
///   value is subtracted from the core budget, mirroring Python
///   `len(projected_trailer.encode("utf-8"))`.
///
/// # Returns
///
/// An `IntentSpanResult` with `compact_core`, `selected_source_spans`, and
/// `selection_details` (without `trailer_projection`).
pub fn intent_span_selection(source: &str, applied_trailer_bytes: usize) -> IntentSpanResult {
    let source_chars: Vec<char> = source.chars().collect();
    let source_bytes = source.len(); // UTF-8 byte count

    // §8.1 — Build atoms.
    let result = intent_atoms(source);
    let atoms = result.atoms;
    let hard = result.hard;
    let coverage = result.coverage;
    let mut unsupported = result.unsupported;
    let mode_details = result.mode_details;

    // §8.2 — Build atom lookup map and initial selection.
    //
    // Mirrors Python:
    //   atom_by_id = {atom.atom_id: atom for atom in atoms}
    //   selected = _dependency_closure(atom_by_id, hard | coverage)
    let atom_by_id: HashMap<usize, &IntentAtom> = atoms.iter()
        .map(|a| (a.atom_id, a))
        .collect();

    let initial_selected: HashSet<usize> = hard.union(&coverage).copied().collect();
    let mut selected = if atoms.is_empty() {
        HashSet::new()
    } else {
        dependency_closure(&atom_by_id, initial_selected)
    };

    // §8.3 — Budget computation.
    //
    // Mirrors Python:
    //   budget_percent = 55
    //   if mode == "document-exchange" and not protected_document_structure:
    //       budget_percent = 35
    //   budget = max(512,
    //       source_bytes * budget_percent // 100 - applied_trailer_bytes)
    let mode_str = mode_details.get("mode")
        .and_then(Value::as_str)
        .unwrap_or("document");
    let protected = mode_details.get("protected_document_structure")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    let budget_percent: usize = if mode_str == "document-exchange" && !protected {
        35
    } else {
        55
    };

    // Python: budget = max(512, source_bytes * budget_percent // 100 - applied_trailer_bytes)
    // Python integer floor division (//); Rust `/` matches for non-negative values.
    // Saturating subtraction prevents underflow when trailer is larger than the percent slice.
    let raw_budget = (source_bytes * budget_percent / 100).saturating_sub(applied_trailer_bytes);
    let budget: usize = std::cmp::max(512, raw_budget);

    // §8.4 — preserve_all_short: include all atoms when source is small.
    //
    // Mirrors Python:
    //   preserve_all_short = (source_bytes <= 512 or
    //       (mode == "document" and source_bytes <= 2048))
    let preserve_all_short = source_bytes <= 512
        || (mode_str == "document" && source_bytes <= 2048);

    if preserve_all_short && !atoms.is_empty() {
        selected = dependency_closure(&atom_by_id, atom_by_id.keys().copied().collect());
    }

    // §8.5 — Pre-compute per-atom scoring data.
    //
    // Mirrors Python: terms_by_id, relevance_by_id, normalized_by_id.
    let terms_by_id: HashMap<usize, HashSet<String>> = atoms.iter()
        .map(|a| (a.atom_id, atom_terms(a)))
        .collect();
    let relevance_by_id: HashMap<usize, i64> = atoms.iter()
        .map(|a| (a.atom_id, intent_relevance(a)))
        .collect();
    let normalized_by_id: HashMap<usize, String> = atoms.iter()
        .map(|a| (a.atom_id, normalized_atom_text(a)))
        .collect();

    // §8.6 — Greedy ranked-utility selection loop.
    //
    // Mirrors Python `while remaining:` loop with utility scoring and
    // budget enforcement.  Python `max(ranked, key=lambda row: row[:3])`
    // uses lexicographic comparison on (utility, relevance, -start) tuples.
    // Rust replicates this exactly.
    //
    // Python stable-sort guarantee: `max` over distinct (utility, relevance,
    // -start) triples is deterministic when atom IDs are unique.
    let mut remaining: Vec<&IntentAtom> = atoms.iter()
        .filter(|a| !selected.contains(&a.atom_id)
            && a.kind != "heading"
            && a.kind != "answer-heading")
        .collect();
    let mut budget_rejected: Vec<Value> = Vec::new();

    while !remaining.is_empty() {
        // Compute term set of currently selected atoms.
        let selected_terms: HashSet<String> = if selected.is_empty() {
            HashSet::new()
        } else {
            selected.iter()
                .flat_map(|id| terms_by_id.get(id).into_iter().flatten().cloned())
                .collect()
        };
        let selected_normalized: HashSet<&str> = selected.iter()
            .filter_map(|id| normalized_by_id.get(id).map(String::as_str))
            .collect();

        // Score every remaining atom.
        // Python: utility = relevance * 1000 + novelty * 120 - max_overlap * 300
        let mut best_score: Option<(i64, i64, i64)> = None; // (utility, relevance, neg_start)
        let mut best_index = 0usize;

        for (i, atom) in remaining.iter().enumerate() {
            let terms = &terms_by_id[&atom.atom_id];
            let novelty = (terms.difference(&selected_terms).count()) as i64;
            // max overlap permille with any currently selected atom.
            let max_overlap = selected.iter()
                .filter_map(|id| terms_by_id.get(id))
                .map(|t| overlap_permille(terms, t))
                .max()
                .unwrap_or(0);
            let relevance = relevance_by_id[&atom.atom_id];
            let utility = relevance * 1000 + novelty * 120 - max_overlap * 300;
            let score = (utility, relevance, -(atom.start as i64));
            if best_score.map_or(true, |b| score > b) {
                best_score = Some(score);
                best_index = i;
            }
        }

        let atom = remaining.remove(best_index);

        // Exact-duplicate check: skip if normalised text already selected.
        if selected_normalized.contains(normalized_by_id[&atom.atom_id].as_str()) {
            budget_rejected.push(json!({
                "atom_id": atom.atom_id,
                "kind": atom.kind,
                "bytes": atom.text.len(),
                "reason": "exact-duplicate",
            }));
            continue;
        }

        // Budget check: include only if dependency-closed set fits.
        let proposed = dependency_closure(&atom_by_id,
            selected.iter().copied().chain(std::iter::once(atom.atom_id)).collect());
        if selection_bytes(&source_chars, &atoms, &proposed) <= budget {
            selected = proposed;
        } else {
            budget_rejected.push(json!({
                "atom_id": atom.atom_id,
                "kind": atom.kind,
                "bytes": atom.text.len(),
                "reason": "complete-atom-does-not-fit",
            }));
        }
    }

    // §8.7 — Render the selected atoms.
    let (core, spans) = render_exact(&source_chars, &atoms, &selected, &hard);
    let selected_bytes = core.len(); // UTF-8 bytes

    // §8.8 — Check for empty core.
    if !atoms.is_empty() && core.trim().is_empty() {
        unsupported.sort();
        unsupported.dedup();
        unsupported.push("no-complete-atom-fits-budget".to_string());
        unsupported.sort();
        unsupported.dedup();
    }

    // §8.9 — Attach UTF-8 byte offsets to spans.
    let portable_spans = portable_span_offsets(&source_chars, &spans);

    // §8.10 — Build selection_details (without trailer_projection).
    //
    // Mirrors Python:
    //   details = {
    //       "selection": "intent-span-exact-source-atoms",
    //       "intent_span_version": INTENT_SPAN_VERSION,
    //       **mode_details,
    //       "core_budget_bytes": budget,
    //       "core_budget_percent": budget_percent,
    //       "selected_core_bytes": selected_bytes,
    //       "budget_overflow": selected_bytes > budget,
    //       "empty_core": not bool(core.strip()),
    //       "preserve_all_short_document": preserve_all_short,
    //       "hard_required_atom_ids": sorted(hard),
    //       "query_coverage_atom_ids": sorted(coverage),
    //       "dependency_closed_atom_ids": sorted(hard_closure),
    //       "budget_rejected_atoms": budget_rejected,
    //       "unsupported_shapes": unsupported,
    //       "trailer_projection": projection,   ← EXCLUDED in Part 4
    //       "exact_source_spans": True,
    //   }
    //
    // hard_closure is defined in Python as:
    //   _dependency_closure(atom_by_id, hard | coverage) if atoms else set()
    let hard_closure_initial: HashSet<usize> = hard.union(&coverage).copied().collect();
    let hard_closure: HashSet<usize> = if atoms.is_empty() {
        HashSet::new()
    } else {
        dependency_closure(&atom_by_id, hard_closure_initial)
    };

    let mut hard_sorted: Vec<usize> = hard.iter().copied().collect();
    hard_sorted.sort_unstable();
    let mut coverage_sorted: Vec<usize> = coverage.iter().copied().collect();
    coverage_sorted.sort_unstable();
    let mut hard_closure_sorted: Vec<usize> = hard_closure.iter().copied().collect();
    hard_closure_sorted.sort_unstable();

    // Start with mode_details fields (spread semantics of Python **mode_details).
    let mut details: Map<String, Value> = Map::new();
    // "selection" and "intent_span_version" come first in Python dict, but
    // JSON serialisation is order-insensitive; comparison is field-by-field.
    details.insert("selection".into(), json!("intent-span-exact-source-atoms"));
    details.insert("intent_span_version".into(), json!(INTENT_SPAN_VERSION));
    // Spread mode_details (mirrors Python **mode_details).
    for (k, v) in &mode_details {
        details.insert(k.clone(), v.clone());
    }
    details.insert("core_budget_bytes".into(), json!(budget));
    details.insert("core_budget_percent".into(), json!(budget_percent));
    details.insert("selected_core_bytes".into(), json!(selected_bytes));
    details.insert("budget_overflow".into(), json!(selected_bytes > budget));
    details.insert("empty_core".into(), json!(core.trim().is_empty()));
    details.insert("preserve_all_short_document".into(), json!(preserve_all_short));
    details.insert("hard_required_atom_ids".into(),
        Value::Array(hard_sorted.into_iter().map(|v| json!(v)).collect()));
    details.insert("query_coverage_atom_ids".into(),
        Value::Array(coverage_sorted.into_iter().map(|v| json!(v)).collect()));
    details.insert("dependency_closed_atom_ids".into(),
        Value::Array(hard_closure_sorted.into_iter().map(|v| json!(v)).collect()));
    details.insert("budget_rejected_atoms".into(), Value::Array(budget_rejected));
    details.insert("unsupported_shapes".into(),
        Value::Array(unsupported.into_iter().map(Value::String).collect()));
    // trailer_projection intentionally omitted (CDL-01 Part 4 scope).
    details.insert("exact_source_spans".into(), json!(true));

    IntentSpanResult {
        compact_core: core,
        selected_source_spans: portable_spans,
        selection_details: details,
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sentence_initial_bof() {
        // Position 0 is always sentence-initial.
        let chars: Vec<char> = "Hello".chars().collect();
        assert!(sentence_initial(&chars, 0));
    }

    #[test]
    fn test_sentence_initial_after_period() {
        let chars: Vec<char> = "One. Two".chars().collect();
        // "T" at index 5 is after ". " → sentence-initial.
        assert!(sentence_initial(&chars, 5));
    }

    #[test]
    fn test_sentence_initial_mid_sentence() {
        let chars: Vec<char> = "Hello world".chars().collect();
        // "w" at index 6 is mid-sentence.
        assert!(!sentence_initial(&chars, 6));
    }

    #[test]
    fn test_sentence_initial_after_newline() {
        let chars: Vec<char> = "Line1\nLine2".chars().collect();
        // "L" at index 6 (start of second line) is sentence-initial.
        assert!(sentence_initial(&chars, 6));
    }

    #[test]
    fn test_overlap_permille_empty() {
        let a: HashSet<String> = HashSet::new();
        let b: HashSet<String> = ["x".to_string()].into_iter().collect();
        assert_eq!(overlap_permille(&a, &b), 0);
    }

    #[test]
    fn test_overlap_permille_full() {
        let a: HashSet<String> = ["a".to_string(), "b".to_string()].into_iter().collect();
        let b = a.clone();
        // intersection=2, union=2 → 2*1000//2 = 1000
        assert_eq!(overlap_permille(&a, &b), 1000);
    }

    #[test]
    fn test_overlap_permille_half() {
        let a: HashSet<String> = ["a".to_string(), "b".to_string()].into_iter().collect();
        let b: HashSet<String> = ["b".to_string(), "c".to_string()].into_iter().collect();
        // intersection=1 {"b"}, union=3 {"a","b","c"} → 1*1000//3 = 333
        assert_eq!(overlap_permille(&a, &b), 333);
    }

    #[test]
    fn test_selection_bytes_empty() {
        let chars: Vec<char> = "hello world".chars().collect();
        let atoms: Vec<IntentAtom> = Vec::new();
        let sel: HashSet<usize> = HashSet::new();
        assert_eq!(selection_bytes(&chars, &atoms, &sel), 0);
    }

    #[test]
    fn test_intent_span_selection_smoke() {
        // Minimal smoke test: short document should produce non-empty core.
        let source = "Hello world. This is a test.";
        let result = intent_span_selection(source, 0);
        assert!(!result.compact_core.is_empty());
        assert!(!result.selected_source_spans.is_empty());
    }
}
