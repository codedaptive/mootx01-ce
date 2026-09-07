//! Transient sub-span max-cosine scoring (MISSION_11X_RECALL_GAP_01 Item 1).
//!
//! Rust twin of Swift `SubSpanScoring.swift`. Implements the same bounded,
//! on-the-fly scoring pass over a candidate content set: each candidate's
//! `effective_dense_text` is segmented into token-window sub-spans, each
//! sub-span is embedded via the caller's provider, and the max cosine
//! similarity against the query embedding is returned per candidate.
//!
//! # Design invariants (shared with Swift twin)
//!
//! - **Zero persistence**: sub-span vectors are computed and discarded
//!   immediately. No storage write, no VectorStore interaction.
//! - **Compute bounded**: by the `SubSpanBudget`, not by the candidate pool
//!   or the corpus. The per-record byte cap bounds the windows one record can
//!   produce and the aggregate window budget bounds the `embed_float` calls
//!   one scoring call can make. Candidates are visited in the caller's order,
//!   so the caller decides which candidates the budget reaches first; the
//!   candidates the budget leaves without a window are reported as
//!   `unscored_ids` and keep their stored signals.
//! - **Cross-port determinism**: `sub_span_ranges` uses the same Unicode
//!   alphabetic + ASCII digit (U+0030–U+0039) scalar predicate as Swift's
//!   `subSpanRanges`, the same sliding window arithmetic, and the same UTF-8
//!   byte-offset calculation. Given identical (text, window_tokens,
//!   overlap_tokens), Swift and Rust produce bit-identical ranges. The byte
//!   cap cuts at the same scalar boundary in both ports, and both ports walk
//!   the candidates in the caller's order, so the same budget truncates the
//!   same candidates.
//! - **Cosine inline**: `cosine_similarity` is pure f32 arithmetic with no
//!   BLAS/NEON dependency — reproducible-within-config, not universally
//!   bit-identical across optimization levels, but functionally equivalent
//!   for the scoring comparison.
//! - **Silent degradation**: if the provider returns Err on `embed_float`,
//!   the candidate is skipped and the function returns an empty outcome. No
//!   panic, no error propagation to the caller.
//!
//! # Cross-port contract
//!
//! The segment text fed to the embedding provider for any given candidate
//! is identical in Swift and Rust for the same (text, window, overlap,
//! budget). Provider-identical scores result. The raw cosine values may
//! differ by float rounding, but the ranking is stable across ports.
//!
//! See also:
//! - `CorpusContentEngine::score_sub_spans` — the engine-level surface.
//! - `Corpus::score_sub_spans` — the chunk-based Corpus surface.
//! - GLK RecallDirector step 5.8 — the caller (both ports).

use crate::content::{CorpusContentId, CorpusContentSource};
use std::collections::HashMap;
use synapsekit::EmbeddingProvider;

// ── Public constants ──────────────────────────────────────────────────────────

/// Default token window size for sub-span segmentation. Mirrors Swift
/// `SubSpanScoring.defaultWindowTokens`.
pub const DEFAULT_WINDOW_TOKENS: usize = 32;

/// Default token overlap between adjacent windows. Mirrors Swift
/// `SubSpanScoring.defaultOverlapTokens`.
pub const DEFAULT_OVERLAP_TOKENS: usize = 8;

// ── Budget ────────────────────────────────────────────────────────────────────

/// The work bound of one scoring call. Mirrors Swift `SubSpanBudget`.
///
/// Without a bound the cost of a call is the sum of every candidate's window
/// count, and a candidate's window count grows with its content: a client
/// that can file large records and issue ordinary searches could force
/// hundreds of thousands of synchronous embedding calls per query while the
/// caller holds the estate coordinator lock. The two limits make the cost of
/// a call a constant of the build, not of the estate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SubSpanBudget {
    /// Bytes of a record's dense text the segmenter reads. The cut lands on
    /// the last scalar boundary at or below the cap, so a window never
    /// straddles a partial scalar. Mirrors Swift `maxRecordBytes`.
    pub max_record_bytes: usize,
    /// Aggregate sub-span `embed_float` calls one scoring call may make. The
    /// query embedding is not counted. Mirrors Swift `maxWindows`.
    pub max_windows: usize,
}

impl SubSpanBudget {
    /// 16 KiB per record: covers about nine in ten drawers of a conversation
    /// estate whole (the LME-S aggregate's p90 body is 17 KB) and bounds one
    /// record at about 110 windows under the default 32/8 window.
    pub const DEFAULT_MAX_RECORD_BYTES: usize = 16_384;
    /// 1,024 windows per query: about 1 MB of text through the provider,
    /// roughly a dozen full-cap records, which keeps a query on a small
    /// on-device encoder inside a few seconds under the coordinator lock.
    pub const DEFAULT_MAX_WINDOWS: usize = 1_024;
    /// The default budget. Mirrors Swift `SubSpanBudget.default`.
    pub const DEFAULT: Self = Self {
        max_record_bytes: Self::DEFAULT_MAX_RECORD_BYTES,
        max_windows: Self::DEFAULT_MAX_WINDOWS,
    };
}

impl Default for SubSpanBudget {
    fn default() -> Self {
        Self::DEFAULT
    }
}

/// The result of one scoring call. Mirrors Swift `SubSpanScoringOutcome`.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SubSpanScoringOutcome {
    /// Max-cosine ∈ [0,1] per candidate the call embedded at least one
    /// window for. Missing keys implicitly score 0.0.
    pub scores: HashMap<CorpusContentId, f32>,
    /// True when the aggregate window budget stopped the call before every
    /// window of every candidate was embedded. The per-record byte cap alone
    /// does not set it: the cap is a constant of the measure, the aggregate
    /// budget is a truncation of the candidate set.
    pub truncated: bool,
    /// The candidates the aggregate budget left without a single embedded
    /// window, in the caller's order. Their dense column stays at its stored
    /// value; the recall explainer names them.
    pub unscored_ids: Vec<CorpusContentId>,
    /// Sub-span `embed_float` calls the call made.
    pub windows_embedded: usize,
}

// ── Primary scoring entry point ───────────────────────────────────────────────

/// Compute sub-span max-cosine scores for a candidate set under a budget.
///
/// For each candidate content ID in `candidate_ids`, in that order:
///   1. Resolves `effective_dense_text` via `source.records_for(ids)`.
///   2. Cuts the text at `budget.max_record_bytes` on a scalar boundary.
///   3. Segments the text into token-window sub-spans using the
///      alphanumeric-run rule (`sub_span_ranges` — cross-port identical).
///   4. Embeds each sub-span via `provider.embed_float` while the aggregate
///      window budget lasts.
///   5. Computes cosine similarity against the pre-embedded `query`.
///   6. Returns the MAX cosine across the embedded sub-spans, normalized to
///      [0,1] using `(cosine + 1) / 2` — the same convention as the dense lane.
///
/// Candidates absent from the source, candidates where `embed_float` returns
/// `Err`, and candidates whose text has no alphanumeric tokens are not
/// included in the returned scores (they contribute 0.0 implicitly). A
/// candidate the budget reached only partway is scored over the windows it
/// got; a candidate the budget did not reach at all is listed in
/// `unscored_ids`.
///
/// # Parameters
/// - `query`: The query text. Embedded once via `provider.embed_float`.
/// - `candidate_ids`: Content IDs in priority order: the budget serves the
///   front of the slice first.
/// - `source`: The content source for resolving `effective_dense_text`.
/// - `provider`: The embedding provider for query and sub-span vectors.
/// - `window_tokens`: Tokens per sub-span window.
/// - `overlap_tokens`: Token overlap between windows.
/// - `budget`: The per-record byte cap and the aggregate window budget.
pub fn score(
    query: &str,
    candidate_ids: &[&str],
    source: &dyn CorpusContentSource,
    provider: &dyn EmbeddingProvider,
    window_tokens: usize,
    overlap_tokens: usize,
    budget: SubSpanBudget,
) -> SubSpanScoringOutcome {
    if query.is_empty() || candidate_ids.is_empty() {
        return SubSpanScoringOutcome::default();
    }

    // Embed the query once. If the provider opts out of the float lane, return empty.
    let query_vec = match provider.embed_float(query) {
        Ok(v) if !v.is_empty() => v,
        _ => return SubSpanScoringOutcome::default(),
    };

    // Batch-resolve content records. Falls back to N serial record() calls
    // via the CorpusContentSource default implementation.
    let records = match source.records_for(candidate_ids) {
        Ok(r) => r,
        Err(_) => return SubSpanScoringOutcome::default(),
    };

    let mut outcome = SubSpanScoringOutcome {
        scores: HashMap::with_capacity(records.len()),
        ..SubSpanScoringOutcome::default()
    };
    // The candidate slice, not the record map, drives the walk: the map has
    // no order, and the budget must reach the caller's first candidates first.
    for &id in candidate_ids {
        let Some(record) = records.get(id) else { continue };
        let text = capped_text(record.effective_dense_text(), budget.max_record_bytes);
        if text.is_empty() {
            continue;
        }
        if outcome.windows_embedded >= budget.max_windows {
            // Budget exhausted by an earlier candidate: this one keeps its
            // stored signals. The ranges are not computed; the text is
            // non-empty, which is the condition the caller can act on.
            outcome.truncated = true;
            outcome.unscored_ids.push(id.to_string());
            continue;
        }
        let ranges = sub_span_ranges(text, window_tokens, overlap_tokens);
        if ranges.is_empty() {
            continue;
        }
        let text_bytes = text.as_bytes();
        let mut max_norm: f32 = 0.0;
        let mut embedded_here = 0usize;
        for (span_start, span_length) in &ranges {
            if outcome.windows_embedded >= budget.max_windows {
                outcome.truncated = true;
                break;
            }
            let lo = *span_start;
            let hi = lo + span_length;
            // Byte-range guard (should always hold for well-formed input).
            if hi > text_bytes.len() {
                continue;
            }
            let span_text = match std::str::from_utf8(&text_bytes[lo..hi]) {
                Ok(s) => s,
                Err(_) => continue,
            };
            outcome.windows_embedded += 1;
            embedded_here += 1;
            let span_vec = match provider.embed_float(span_text) {
                Ok(v) if !v.is_empty() => v,
                _ => continue,
            };
            let cosine = cosine_similarity(&query_vec, &span_vec);
            // Normalize cosine ∈ [−1, 1] to [0, 1]: same convention as the
            // dense lane in RecallDirector (`(similarity + 1) / 2`).
            let norm = f32::max(0.0, f32::min(1.0, (cosine + 1.0) / 2.0));
            if norm > max_norm {
                max_norm = norm;
            }
        }
        if embedded_here == 0 {
            outcome.unscored_ids.push(id.to_string());
            continue;
        }
        if max_norm > 0.0 {
            outcome.scores.insert(id.to_string(), max_norm);
        }
    }
    outcome
}

/// The longest prefix of `text` that is at most `max_bytes` long and ends on
/// a scalar boundary. Mirrors Swift `SubSpanScoring.cappedText`: both ports
/// step back from the cap to the nearest boundary, so the same bytes reach
/// the segmenter.
pub fn capped_text(text: &str, max_bytes: usize) -> &str {
    if text.len() <= max_bytes {
        return text;
    }
    let mut cut = max_bytes;
    while cut > 0 && !text.is_char_boundary(cut) {
        cut -= 1;
    }
    &text[..cut]
}

// ── Segmentation (cross-port identical) ──────────────────────────────────────

/// Deterministic alphanumeric-run token-window sub-span ranges over UTF-8 text.
///
/// # Cross-port contract
///
/// The token boundary rule is:
/// - A scalar is in-token iff it is Unicode-alphabetic OR is an ASCII digit
///   (U+0030–U+0039, i.e. `char::is_ascii_digit()`).
/// - The same rule is used by Swift `subSpanRanges`, `defaultKeywordTokens`
///   (CorpusDefaultTokenizer), and `PassageProduction.passageRanges` in the
///   standalone-passages feature.
///
/// Each window spans from the UTF-8 start byte of its first token through
/// the UTF-8 end byte of its last token. Adjacent windows overlap by
/// `overlap_tokens` tokens. A text shorter than one full window produces a
/// single range covering all of its tokens.
///
/// Given identical (text, window_tokens, overlap_tokens), this function and
/// Swift `SubSpanScoring.subSpanRanges` return the same (start, length)
/// pairs.
///
/// # Parameters
/// - `text`: Source text (UTF-8).
/// - `window_tokens`: Token count per window. Clamped to at least 1.
/// - `overlap_tokens`: Token overlap between adjacent windows. Clamped to
///   `[0, window_tokens − 1]`.
///
/// # Returns
/// `Vec<(usize, usize)>` of `(utf8_start, utf8_length)` pairs. Empty when
/// `text` contains no alphanumeric tokens.
pub fn sub_span_ranges(
    text: &str,
    window_tokens: usize,
    overlap_tokens: usize,
) -> Vec<(usize, usize)> {
    let window = window_tokens.max(1);
    let overlap = overlap_tokens.min(window - 1);
    let stride = window - overlap;

    // Collect alphanumeric-run token byte ranges: (start, end) half-open.
    // Iterates over chars (not bytes) for Unicode correctness, tracking
    // the UTF-8 byte offset via char.len_utf8().
    let mut token_ranges: Vec<(usize, usize)> = Vec::new();
    let mut offset: usize = 0;
    let mut run_start: Option<usize> = None;

    for ch in text.chars() {
        // Same scalar predicate as Swift: alphabetic OR ASCII digit.
        let in_token = ch.is_alphabetic() || ch.is_ascii_digit();
        if in_token {
            if run_start.is_none() {
                run_start = Some(offset);
            }
        } else if let Some(start) = run_start.take() {
            token_ranges.push((start, offset));
        }
        offset += ch.len_utf8();
    }
    if let Some(start) = run_start {
        token_ranges.push((start, offset));
    }

    if token_ranges.is_empty() {
        return Vec::new();
    }

    // Build sliding token windows.
    let mut out: Vec<(usize, usize)> = Vec::new();
    let mut index: usize = 0;
    while index < token_ranges.len() {
        let window_end = (index + window).min(token_ranges.len());
        let (first_start, _) = token_ranges[index];
        let (_, last_end) = token_ranges[window_end - 1];
        out.push((first_start, last_end - first_start));
        if window_end == token_ranges.len() {
            break;
        }
        index += stride;
    }
    out
}

// ── Cosine similarity (inline, no BLAS dependency) ───────────────────────────

/// L2-normalised cosine similarity between two equal-length f32 vectors.
///
/// Returns a value in [−1, 1]: 1.0 = identical direction, −1.0 = opposite,
/// 0.0 = orthogonal. Returns 0.0 when either vector is all-zero (no signal),
/// or when the lengths differ.
///
/// # Cross-port note
///
/// IEEE-754 f32 `+` and `*` are the same in Swift and Rust on the same
/// hardware. The result is reproducible-within-config, not universally
/// bit-identical across optimization levels.
pub fn cosine_similarity(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() || a.is_empty() {
        return 0.0;
    }
    let mut dot: f32 = 0.0;
    let mut norm_a: f32 = 0.0;
    let mut norm_b: f32 = 0.0;
    for (&ai, &bi) in a.iter().zip(b.iter()) {
        dot += ai * bi;
        norm_a += ai * ai;
        norm_b += bi * bi;
    }
    let denom = norm_a.sqrt() * norm_b.sqrt();
    if denom <= 0.0 {
        0.0
    } else {
        dot / denom
    }
}
