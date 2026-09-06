// Spanner.swift
//
// Deterministic span windowing shared by the `spanEncode` duty (which
// encodes) and the recall rerank stage (which renders the best span). Both
// ports implement the identical rule and are pinned by the shared fixture
// `SynapseKit/Tests/Fixtures/encoder/spanner_vectors.json`.
//
// Mirror: rust/src/encoder/spanner.rs.

import Foundation

/// Span windowing over a record's word list.
public enum Spanner {

    /// Half-open word ranges `[start, end)` covering `wordCount` words.
    ///
    /// The rule matches the measured reference (`windows()` in the offline
    /// evaluation) exactly, plus the `maxSpans` cap:
    ///
    /// 1. `wordCount <= windowWords` → one span `(0, wordCount)`. A zero-word
    ///    record therefore yields the single empty span `(0, 0)`; callers
    ///    that have nothing to encode skip such records before calling.
    /// 2. Otherwise `step = max(1, windowWords / overlapDivisor)` and the
    ///    starts are `0, step, 2·step, …` while `start <= wordCount - windowWords`.
    ///    Every span is `(start, start + windowWords)`. The tail is NOT
    ///    force-covered here: 121 words at window 60 give starts 0, 30, 60
    ///    and word 120 is left out, as in the reference.
    /// 3. If step 2 yields more than `maxSpans` spans, the step widens to
    ///    `ceil((wordCount - windowWords) / (maxSpans - 1))`, the starts are
    ///    `0, step', 2·step', …` while `start < wordCount - windowWords`, and
    ///    the final start is pinned to `wordCount - windowWords` so the last
    ///    span ends exactly at `wordCount`. The count is then `<= maxSpans`.
    ///
    /// Spans are always emitted in ascending start order; there is no
    /// longest-first ordering anywhere in this rule.
    ///
    /// Degenerate parameters: `windowWords <= 0` behaves as rule 1;
    /// `overlapDivisor <= 0` is treated as 1; `maxSpans <= 1` returns the
    /// single tail-anchored span `(wordCount - windowWords, wordCount)`.
    public static func spans(
        wordCount: Int,
        windowWords: Int,
        overlapDivisor: Int,
        maxSpans: Int
    ) -> [(start: Int, end: Int)] {
        // Rule 1: the whole record fits in one window.
        guard windowWords > 0, wordCount > windowWords else {
            return [(start: 0, end: max(0, wordCount))]
        }
        let lastStart = wordCount - windowWords
        // Rule 2: half-overlap stride (divisor 2), clamped to at least one word.
        let step = max(1, windowWords / max(1, overlapDivisor))
        var starts = Array(stride(from: 0, through: lastStart, by: step))
        if starts.count > maxSpans {
            // A cap below two cannot hold both a head and a tail span; the
            // tail-anchored span keeps "the last span ends at wordCount".
            guard maxSpans >= 2 else {
                return [(start: lastStart, end: wordCount)]
            }
            // Rule 3: integer ceil((lastStart) / (maxSpans - 1)). The
            // multiples of the widened step strictly below lastStart number
            // at most maxSpans - 1, so adding the pinned tail start keeps the
            // total at or under maxSpans.
            let widened = (lastStart + maxSpans - 2) / (maxSpans - 1)
            starts = Array(stride(from: 0, to: lastStart, by: widened))
            starts.append(lastStart)
        }
        return starts.map { (start: $0, end: $0 + windowWords) }
    }

    /// The product's word split: lowercase runs of Unicode-alphabetic and
    /// ASCII-digit scalars, everything else a separator. This is
    /// `defaultKeywordTokens`, the same split BM25 indexes with, so a span's
    /// word bounds address the same words the lexical lane matched.
    public static func words(_ content: String) -> [String] {
        defaultKeywordTokens(content)
    }
}
