//! Deterministic delimiter-based sentence segmentation. This is the
//! canonical cross-leg reference path, byte-identical to the Swift
//! version's `EideticLib.sentencesByDelimiter(_:)`.
//!
//! The Swift version exposes two entry points:
//!   - `sentences(_:)` — platform-routed; uses Apple's `NLTokenizer`
//!     on Apple platforms, falls back to the delimiter algorithm
//!     elsewhere. The Apple NLTokenizer path is deliberately
//!     Apple-only per the apple-nlp-accel constitutional constraint
//!     (C-2) and is excluded from the cross-leg parity surface.
//!   - `sentencesByDelimiter(_:)` — the deterministic delimiter
//!     algorithm, identical across platforms.
//!
//! The Rust `segmenter::sentences` here implements the delimiter
//! algorithm only — there is no Rust NLTokenizer path. It is the
//! cross-leg counterpart of Swift's `sentencesByDelimiter`, not
//! of Swift's platform-routed `sentences`.
//!
//! Algorithm invariant: segments concatenate back to the original
//! input with no gaps, overlaps, or reordering (total coverage).
//! Downstream CorpusKit chunking relies on this invariant.

/// Segment `text` into sentences using the deterministic delimiter
/// algorithm. Splits on `.`, `!`, `?`, and `\n`, preserving the
/// terminator at the end of each segment.
///
/// Behaviour matches Swift `EideticLib.sentencesByDelimiter(_:)`:
/// - Empty input → empty `Vec`.
/// - Non-empty input where no delimiter is found → the whole input
///   as one segment.
/// - Otherwise each delimited run is a segment; any trailing text
///   after the last delimiter is its own segment.
/// - Segments concatenate back to the original input (total
///   coverage).
///
/// UTF-8 correctness: `char_indices` yields `(byte_offset, char)`
/// pairs; segment slices are taken at those byte offsets, so no
/// codepoint is ever split across a segment boundary.
pub fn sentences(text: &str) -> Vec<String> {
    if text.is_empty() {
        return Vec::new();
    }

    let mut out: Vec<String> = Vec::new();
    let mut last_start: usize = 0; // byte offset of the current segment start

    for (byte_idx, ch) in text.char_indices() {
        if ch == '.' || ch == '!' || ch == '?' || ch == '\n' {
            // Include the terminator in this segment. `ch.len_utf8()`
            // is 1 for all four sentinel chars (ASCII), but written
            // generically so the arithmetic is self-documenting.
            let end = byte_idx + ch.len_utf8();
            out.push(text[last_start..end].to_string());
            last_start = end;
        }
    }

    // Trailing remainder: text after the last terminator (no terminator
    // at the end). Mirrors Swift's `if lastStart < text.endIndex` guard.
    if last_start < text.len() {
        out.push(text[last_start..].to_string());
    }

    // Total-coverage guard: non-empty input always produces ≥1 segment
    // through the algorithm above, but mirror the Swift guard explicitly
    // for cross-leg fidelity.
    if out.is_empty() {
        out.push(text.to_string());
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── Empty / single-sentence ──────────────────────────────────────

    /// Mirrors Swift `emptyInputReturnsEmpty` (delimiter path).
    #[test]
    fn empty_input_returns_empty() {
        assert!(sentences("").is_empty());
    }

    /// Mirrors Swift `singleSentenceNoTerminatorReturnsFullInput`
    /// (delimiter path).
    #[test]
    fn single_sentence_no_terminator_returns_full_input() {
        let text = "this is one fragment with no terminator";
        let segs = sentences(text);
        assert_eq!(segs.len(), 1);
        assert_eq!(segs[0], text);
    }

    // ── Delimiter reference ──────────────────────────────────────────

    /// Mirrors Swift `delimiterSplitsOnPeriodExclaimQuestion`.
    #[test]
    fn delimiter_splits_on_period_exclaim_question() {
        let text = "First. Second! Third? Fourth";
        let segs = sentences(text);
        assert_eq!(segs.len(), 4);
        assert_eq!(segs[0], "First.");
        assert_eq!(segs[1], " Second!");
        assert_eq!(segs[2], " Third?");
        assert_eq!(segs[3], " Fourth");
    }

    /// Mirrors Swift `delimiterSplitsOnNewline` — newline preserved
    /// at the end of each split segment; last segment has no trailing
    /// newline.
    #[test]
    fn delimiter_splits_on_newline() {
        let text = "Line one\nLine two\nLine three";
        let segs = sentences(text);
        assert_eq!(segs.len(), 3);
        assert!(segs[0].ends_with('\n'));
        assert!(segs[1].ends_with('\n'));
        assert!(!segs[2].ends_with('\n'));
    }

    /// Mirrors Swift `delimiterTotalCoverage` — segments must
    /// concatenate back to the original input exactly.
    #[test]
    fn delimiter_total_coverage() {
        let text = "Alpha. Beta! Gamma? Delta\nEpsilon";
        let segs = sentences(text);
        let rejoined: String = segs.join("");
        assert_eq!(rejoined, text);
    }

    // ── Pathological inputs ──────────────────────────────────────────

    /// Mirrors Swift `inputWithOnlyTerminatorsProducesEmptyButCoveringSegments`.
    #[test]
    fn input_with_only_terminators_produces_covering_segments() {
        let text = "...";
        let segs = sentences(text);
        assert_eq!(segs.len(), 3);
        for s in &segs {
            assert_eq!(s.as_str(), ".");
        }
        let rejoined: String = segs.join("");
        assert_eq!(rejoined, text);
    }

    /// Mirrors Swift `inputWithoutTerminatorYieldsSingleSegment`
    /// (delimiter path — no language-specific edge cases).
    #[test]
    fn input_without_terminator_yields_single_segment() {
        let text = "no terminators here";
        let segs = sentences(text);
        assert_eq!(segs.len(), 1);
        assert_eq!(segs[0], text);
    }

    // ── Platform-routed agreement (delimiter path) ───────────────────

    /// Mirrors Swift `routedAndReferenceAgreeOnSimpleInput` — segment
    /// count and round-trip equality for unambiguous input. The Apple
    /// NLTokenizer path is Apple-only; this test covers the delimiter
    /// reference, which is the cross-leg parity surface.
    #[test]
    fn simple_input_segment_count_and_roundtrip() {
        let text = "One sentence. Two sentences. Three sentences.";
        let segs = sentences(text);
        assert_eq!(segs.len(), 3);
        let rejoined: String = segs.join("");
        assert_eq!(rejoined, text);
    }

    /// Mirrors Swift `routedRoundTripsToInput` (delimiter path).
    #[test]
    fn round_trips_to_input() {
        let text = "Round trip. Round trip. Round trip.";
        let segs = sentences(text);
        let rejoined: String = segs.join("");
        assert_eq!(rejoined, text);
    }

    // ── Distillation eligibility (R10, 2026-06-20) ──────────────────────

    /// The R10 parity probe text: the exact content used in the head-to-head
    /// live test that revealed the Rust/Swift distillation divergence (Swift
    /// produced 1 factoid, Rust produced 0 factoids). The delimiter segmenter
    /// must yield ≥3 segments so the item meets `MIN_INTRA_ITEM_UNITS` = 3
    /// and is considered eligible for intra-item distillation.
    ///
    /// Mirrors the distillation eligibility assertion on the Swift path:
    /// `guard sentences.count >= 3` in `GeniusLocusKit.distillItem`.
    #[test]
    fn r10_probe_text_yields_at_least_three_segments_for_distillation_eligibility() {
        let probe = "Head to head parity probe: the same content filed on both \
the Swift and Rust servers to diff capture, recall, distillation, and lens \
output byte for byte. Distillation needs several sentences. This memory has \
enough sentences to distill. The ports should agree.";
        let segs = sentences(probe);
        // Total coverage invariant
        let rejoined: String = segs.join("");
        assert_eq!(rejoined, probe, "total-coverage invariant must hold on probe text");
        // Distillation eligibility: ≥3 segments
        assert!(
            segs.len() >= 3,
            "R10 probe text must segment into ≥3 units for distillation eligibility \
             (got {}) — parity gate that caused Swift=1 factoid, Rust=0 factoid",
            segs.len()
        );
    }

    // ── UTF-8 multibyte correctness ──────────────────────────────────

    /// Not in Swift tests (Swift Substring slicing is char-safe), but
    /// Rust requires explicit byte-offset correctness. Verifies that
    /// multibyte codepoints are never split and total coverage holds.
    #[test]
    fn multibyte_input_total_coverage_and_no_panic() {
        let text = "Héllo wörld. Ünïcödé! 日本語？Emoji 😀";
        let segs = sentences(text);
        // Must not panic; all codepoints must survive intact.
        let rejoined: String = segs.join("");
        assert_eq!(rejoined, text, "UTF-8 total coverage invariant");
        // At least the ASCII terminators split the input.
        assert!(segs.len() >= 2);
    }
}
