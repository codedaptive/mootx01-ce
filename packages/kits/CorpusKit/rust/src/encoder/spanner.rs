//! Deterministic span windowing shared by the `spanEncode` duty (which
//! encodes) and the recall rerank stage (which renders the best span).
//! Both ports implement the identical rule and are pinned by the shared
//! fixture `SynapseKit/Tests/Fixtures/encoder/spanner_vectors.json`.
//!
//! Mirror of Swift `Spanner.swift`.

use crate::tokenizer::default_keyword_tokens;

/// Half-open word ranges `[start, end)` covering `word_count` words.
///
/// The rule matches the measured reference (`windows()` in the offline
/// evaluation) exactly, plus the `max_spans` cap:
///
/// 1. `word_count <= window_words` → one span `(0, word_count)`. A zero-word
///    record therefore yields the single empty span `(0, 0)`; callers that
///    have nothing to encode skip such records before calling.
/// 2. Otherwise `step = max(1, window_words / overlap_divisor)` and the
///    starts are `0, step, 2·step, …` while `start <= word_count - window_words`.
///    Every span is `(start, start + window_words)`. The tail is NOT
///    force-covered here: 121 words at window 60 give starts 0, 30, 60 and
///    word 120 is left out, as in the reference.
/// 3. If step 2 yields more than `max_spans` spans, the step widens to
///    `ceil((word_count - window_words) / (max_spans - 1))`, the starts are
///    `0, step', 2·step', …` while `start < word_count - window_words`, and
///    the final start is pinned to `word_count - window_words` so the last
///    span ends exactly at `word_count`. The count is then `<= max_spans`.
///
/// Spans are always emitted in ascending start order; there is no
/// longest-first ordering anywhere in this rule.
///
/// Degenerate parameters: `window_words == 0` behaves as rule 1;
/// `overlap_divisor == 0` is treated as 1; `max_spans <= 1` returns the
/// single tail-anchored span `(word_count - window_words, word_count)`.
pub fn spans(
    word_count: usize,
    window_words: usize,
    overlap_divisor: usize,
    max_spans: usize,
) -> Vec<(usize, usize)> {
    // Rule 1: the whole record fits in one window.
    if window_words == 0 || word_count <= window_words {
        return vec![(0, word_count)];
    }
    let last_start = word_count - window_words;
    // Rule 2: half-overlap stride (divisor 2), clamped to at least one word.
    let step = (window_words / overlap_divisor.max(1)).max(1);
    let mut starts: Vec<usize> = (0..=last_start).step_by(step).collect();
    if starts.len() > max_spans {
        // A cap below two cannot hold both a head and a tail span; the
        // tail-anchored span keeps "the last span ends at word_count".
        if max_spans < 2 {
            return vec![(last_start, word_count)];
        }
        // Rule 3: integer ceil(last_start / (max_spans - 1)). The multiples
        // of the widened step strictly below last_start number at most
        // max_spans - 1, so adding the pinned tail start keeps the total at
        // or under max_spans.
        let widened = (last_start + max_spans - 2) / (max_spans - 1);
        starts = (0..last_start).step_by(widened).collect();
        starts.push(last_start);
    }
    starts.into_iter().map(|s| (s, s + window_words)).collect()
}

/// The product's word split: lowercase runs of Unicode-alphabetic and
/// ASCII-digit characters, everything else a separator. This is
/// `default_keyword_tokens`, the same split BM25 indexes with, so a span's
/// word bounds address the same words the lexical lane matched.
pub fn words(content: &str) -> Vec<String> {
    default_keyword_tokens(content)
}
