//! Sentence segmentation. Splits on `.`, `!`, `?`, and
//! newline while preserving the terminator at the end of each
//! segment.
//!
//! This is the canonical reference implementation of the FDC
//! encoder mandate's sentence-segmentation stage (cookbook §2.2):
//! deterministic, cross-platform identical, byte-for-byte parity
//! with Swift's `EideticLib.sentencesByDelimiter`. The Swift port
//! also carries an optional Apple `NLTokenizer` acceleration
//! exposed via `EideticLib.sentences`; the Rust port has no
//! platform acceleration today, so `sentences` and the canonical
//! reference are the same function.
//!
//! Downstream consumers (e.g. corpus-kit's chunker) content-address
//! their outputs, so platform-divergent segmentation produces a
//! superset of chunks across devices under an append-only conflict
//! policy rather than conflicting writes (C-2).
//!
//! Relocated 2026-05-27 (F16) from corpus-kit/src/chunker.rs
//! `sentence_segments` to centralize linguistic-pipeline stages
//! in eidetic-lib alongside tokenizer / normalizer / stemmer /
//! word_class.

/// Segment text into sentence-shaped pieces. Splits on `.`, `!`,
/// `?`, and `\n`, preserving the terminator at the end of each
/// segment. Empty input returns an empty vector; non-empty input
/// always yields at least one segment.
pub fn sentences(text: &str) -> Vec<String> {
    if text.is_empty() {
        return Vec::new();
    }
    let mut out: Vec<String> = Vec::new();
    let mut current = String::new();
    for c in text.chars() {
        current.push(c);
        if c == '.' || c == '!' || c == '?' || c == '\n' {
            out.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        out.push(current);
    }
    if out.is_empty() {
        out.push(text.to_string());
    }
    out
}
