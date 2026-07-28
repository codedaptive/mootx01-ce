// SubSpanScoring.swift
//
// Transient sub-span max-cosine scoring (MISSION_11X_RECALL_GAP_01 Item 1).
//
// Exposes a bounded, on-the-fly scoring pass over a candidate content set:
// each candidate's effectiveDenseText is segmented into token-window sub-spans,
// each sub-span is embedded via the caller's provider, and the max cosine
// similarity against the query embedding is returned per candidate.
//
// DESIGN INVARIANTS:
//   - Zero persistence: sub-span vectors are computed and DISCARDED immediately.
//   - Compute is bounded by candidate set size (~40), not corpus size.
//   - Segmentation is deterministic and cross-port identical: the alphanumeric-
//     run token-window rule mirrors the standalone-passages `PassageProduction`
//     algorithm (same scalar classification, same sliding window arithmetic).
//     The Rust twin (`sub_span_scoring.rs`) uses identical parameters.
//   - Cosine similarity is computed inline (no VectorKit dependency):
//     pure IEEE-754 arithmetic — same result cross-port within a config.
//   - A candidate absent from the source, a provider that returns an empty
//     float vector, or a text with no tokens is scored 0.0 (safe neutral value).
//
// CONFORMANCE CONTRACT:
//   Sub-span range production for any given (text, windowTokens, overlapTokens)
//   must produce bit-identical UTF-8 byte ranges in Swift and Rust on the same
//   input. The cosineSimilarity formula is NOT four-way bit-identical (float
//   arithmetic is reproducible-within-config, not universally bit-exact), but
//   the SEGMENT TEXT passed to the provider is identical, so provider-identical
//   scores result.
//
// See also:
//   - CorpusContentEngine.scoreSubSpans(query:candidateIDs:) — the actor-level
//     surface that wires this module to the engine's source and default provider.
//   - GLK RecallDirector step 5.8 — the caller that scores the candidate pool.
//
// Rust twin: `rust/src/sub_span_scoring.rs`.

import Foundation
import VectorKit

// MARK: - SubSpanScoring

/// Transient sub-span max-cosine scoring capability.
///
/// `SubSpanScoring` is a CorpusKit SDK primitive: any `CorpusContentSource`
/// implementation (standalone `CorpusDocumentStore` or GLK's LocusKit-backed
/// adapter) feeds it identically. GLK's RecallDirector calls it on
/// `CorpusContentEngine.scoreSubSpans`, but SDK consumers may call
/// `SubSpanScoring.score(query:candidateIDs:source:provider:)` directly.
public enum SubSpanScoring {

    // MARK: - Window parameters

    /// Default token window size for sub-span segmentation.
    ///
    /// 32 tokens covers roughly 20–40 words — a typical sentence or short
    /// paragraph. Short texts (< windowTokens tokens) produce a single span
    /// spanning the whole text; long texts get a sliding window.
    public static let defaultWindowTokens = 32

    /// Default token overlap between adjacent windows.
    ///
    /// 8-token overlap ensures context at window boundaries is not lost.
    public static let defaultOverlapTokens = 8

    // MARK: - Primary scoring entry point

    /// Compute sub-span max-cosine scores for a bounded candidate set.
    ///
    /// For each candidate content ID in `candidateIDs`:
    ///   1. Resolves `effectiveDenseText` via `source.records(for:)`.
    ///   2. Segments the text into token-window sub-spans using the
    ///      alphanumeric-run rule (cross-port identical; see `subSpanRanges`).
    ///   3. Embeds each sub-span via `provider.embedFloat`.
    ///   4. Computes cosine similarity against the pre-embedded `query`.
    ///   5. Returns the MAX cosine across all sub-spans, normalized to [0,1]
    ///      using `(cosine + 1) / 2` — the same convention as the dense lane.
    ///
    /// Candidates absent from the source, candidates where `embedFloat` returns
    /// an empty vector, and candidates whose text has no alphanumeric tokens are
    /// not included in the result dictionary (they contribute 0.0 implicitly).
    ///
    /// - Parameters:
    ///   - query: The query text. Embedded once via `provider.embedFloat`.
    ///   - candidateIDs: Bounded content ID set (typically ~40 from the pool).
    ///   - source: The content source used to resolve `effectiveDenseText`.
    ///   - provider: The embedding provider for both query and sub-span vectors.
    ///   - windowTokens: Tokens per sub-span window (default 32).
    ///   - overlapTokens: Token overlap between windows (default 8).
    /// - Returns: `[CorpusContentID: Float]` — max-cosine ∈ [0,1] per candidate.
    ///   Missing keys implicitly score 0.0.
    public static func score(
        query: String,
        candidateIDs: [CorpusContentID],
        source: any CorpusContentSource,
        provider: any EmbeddingProvider,
        windowTokens: Int = defaultWindowTokens,
        overlapTokens: Int = defaultOverlapTokens
    ) async -> [CorpusContentID: Float] {
        guard !query.isEmpty, !candidateIDs.isEmpty else { return [:] }

        // Embed the query once. If the provider has no float lane, return empty.
        let queryVec: [Float]
        do {
            let result = try await provider.embedFloat(query)
            guard !result.isEmpty else { return [:] }
            queryVec = result
        } catch {
            // Provider opted out (embedFloatVocabMiss, or structural opt-out).
            return [:]
        }

        // Batch-resolve content records to get effectiveDenseText.
        // Uses the default N-serial fallback when the source doesn't override;
        // SQL-backed sources (CorpusDocumentStore, GLK adapter) provide a single
        // WHERE…IN query override.
        let records: [CorpusContentID: CorpusContentRecord]
        do {
            records = try await source.records(for: candidateIDs)
        } catch {
            return [:]
        }

        // Score each resolved candidate.
        var out: [CorpusContentID: Float] = [:]
        out.reserveCapacity(records.count)
        for (id, record) in records {
            let text = record.effectiveDenseText
            guard !text.isEmpty else { continue }

            let ranges = subSpanRanges(
                text: text, windowTokens: windowTokens, overlapTokens: overlapTokens)
            guard !ranges.isEmpty else { continue }

            var maxNorm: Float = 0.0
            let utf8 = text.utf8
            for (spanStart, spanLength) in ranges {
                // Extract the sub-span text from UTF-8 byte offsets.
                guard spanStart >= 0, spanStart + spanLength <= utf8.count else { continue }
                let lo = utf8.index(utf8.startIndex, offsetBy: spanStart)
                let hi = utf8.index(lo, offsetBy: spanLength)
                guard let spanText = String(utf8[lo..<hi]) else { continue }

                let spanVec: [Float]
                do {
                    let result = try await provider.embedFloat(spanText)
                    guard !result.isEmpty else { continue }
                    spanVec = result
                } catch {
                    continue
                }

                let cosine = cosineSimilarity(queryVec, spanVec)
                // Normalize cosine ∈ [−1, 1] to [0, 1]: same convention as the
                // dense lane in RecallDirector (`(similarity + 1) / 2`).
                let norm = max(0, min(1, (cosine + 1) / 2))
                if norm > maxNorm { maxNorm = norm }
            }
            if maxNorm > 0 { out[id] = maxNorm }
        }
        return out
    }

    // MARK: - Segmentation (cross-port identical)

    /// Deterministic alphanumeric-run token-window sub-span ranges over UTF-8 text.
    ///
    /// Token boundaries follow the alphanumeric-run rule: a token is a maximal
    /// contiguous run of scalars that are either Unicode-alphabetic OR ASCII
    /// digits (U+0030–U+0039). The rule is identical to `defaultKeywordTokens`
    /// (CorpusDefaultTokenizer) and to `PassageProduction.passageRanges` in the
    /// standalone-passages feature — the same well-tested cross-port boundary.
    ///
    /// Each window spans from the UTF-8 start byte of its first token through
    /// the UTF-8 end byte of its last token. Adjacent windows overlap by
    /// `overlapTokens` tokens. A text shorter than one full window produces a
    /// single range covering all of its tokens.
    ///
    /// **Cross-port contract:** the Rust twin (`sub_span_scoring::sub_span_ranges`)
    /// uses the same scalar predicate, the same window/stride arithmetic, and the
    /// same UTF-8 byte-offset calculation. Given identical (text, windowTokens,
    /// overlapTokens), both ports return the same (start, length) pairs.
    ///
    /// Exposed `internal` so tests can verify the ranges directly. Callers outside
    /// the module use `score(query:candidateIDs:source:provider:)`.
    ///
    /// - Parameters:
    ///   - text: Source text (UTF-8 encoded; Swift String is always valid UTF-8).
    ///   - windowTokens: Token count per window. Clamped to at least 1.
    ///   - overlapTokens: Token overlap between adjacent windows.
    ///     Clamped to [0, windowTokens − 1].
    /// - Returns: UTF-8 byte-offset ranges `(utf8Start: Int, utf8Length: Int)`.
    ///   Empty when `text` contains no alphanumeric tokens.
    static func subSpanRanges(
        text: String,
        windowTokens: Int,
        overlapTokens: Int
    ) -> [(utf8Start: Int, utf8Length: Int)] {
        let window = max(1, windowTokens)
        let overlap = max(0, min(overlapTokens, window - 1))
        let stride = window - overlap

        // Extract alphanumeric-run token byte ranges.
        // Each token = (startByte: Int, endByte: Int) — half-open [start, end).
        var tokenRanges: [(start: Int, end: Int)] = []
        var offset = 0
        var runStart: Int? = nil
        for scalar in text.unicodeScalars {
            let width = scalar.utf8.count
            let isToken = scalar.properties.isAlphabetic
                || (scalar.value >= 0x30 && scalar.value <= 0x39)
            if isToken {
                if runStart == nil { runStart = offset }
            } else if let start = runStart {
                tokenRanges.append((start, offset))
                runStart = nil
            }
            offset += width
        }
        if let start = runStart { tokenRanges.append((start, offset)) }

        guard !tokenRanges.isEmpty else { return [] }

        // Build sliding token windows.
        var out: [(utf8Start: Int, utf8Length: Int)] = []
        var index = 0
        while index < tokenRanges.count {
            let windowEnd = min(index + window, tokenRanges.count)
            let first = tokenRanges[index]
            let last = tokenRanges[windowEnd - 1]
            out.append((utf8Start: first.start, utf8Length: last.end - first.start))
            if windowEnd == tokenRanges.count { break }
            index += stride
        }
        return out
    }

    // MARK: - Cosine similarity (inline, no VectorKit dependency)

    /// L2-normalised cosine similarity between two equal-length float32 vectors.
    ///
    /// Returns a value in [−1, 1]: 1.0 = identical direction, −1.0 = opposite,
    /// 0.0 = orthogonal. Returns 0.0 when either vector is all-zero (no signal).
    ///
    /// **Why inline:** sub-span scoring is the only call site for on-the-fly
    /// cosine over raw `[Float]` arrays. Adding a VectorKit import only for this
    /// one computation would introduce a dependency edge that doesn't exist
    /// anywhere else in CorpusKit core. The pure arithmetic is tiny and correct.
    ///
    /// **Cross-port:** IEEE-754 float32 `+` and `*` are the same in Swift and
    /// Rust on the same hardware. The result is reproducible-within-config, NOT
    /// four-way bit-identical (the DenseMetric determinism note applies here too).
    ///
    /// Exposed `internal` for testing. Not part of the public SDK surface.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0.0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot   += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = normA.squareRoot() * normB.squareRoot()
        guard denom > 0 else { return 0.0 }
        return dot / denom
    }
}
