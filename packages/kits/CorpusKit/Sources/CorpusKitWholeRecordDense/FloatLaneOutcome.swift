// FloatLaneOutcome.swift
//
// The observable outcome and discrimination signal of the whole-record dense
// float lane. This target is the WholeRecordDense sidecar: it compiles only
// when the `WholeRecordDense` trait defines MOOTX01_WHOLE_RECORD_DENSE. The
// default product graph never links it; the span stage (Arctic) is the one
// dense provider in the default build.
//
// Rust twin: rust/src/corpus/float_lane.rs (feature `whole-record-dense`).

#if MOOTX01_WHOLE_RECORD_DENSE
import Foundation

// MARK: - FloatLaneOutcome

/// The observable outcome of a `Corpus.floatNearest` call.
///
/// Dark outcomes (`.unavailableProviderOptOut`, `.unavailableNoFloatRows`,
/// `.emptyQuery`) are EXPECTED degradations — the calling lane degrades
/// gracefully and emits an explainer marker. `.storeError` is NOT expected:
/// it is logged via OSLog and emitted as a telemetry counter so that store
/// failures are never swallowed silently. `.hits` is the happy path.
///
/// Callers must never treat a dark outcome as an error — per the softPrior
/// grammar a dark dense lane means the query runs on the other lanes only,
/// not that the query failed.
public enum FloatLaneOutcome: Sendable {
    /// The lane ran and returned at least one ranked hit.
    ///
    /// - Parameter hits: `(itemID, cosineSimilarity)` pairs, nearest first.
    ///   `itemID` is the `sourceID` the caller ingested under (drawer ID in
    ///   the GLK context). Similarity ∈ [−1, 1], 1.0 = identical direction.
    case hits([(itemID: String, similarity: Float)])

    /// Provider opted out of the float lane — expected, not an error.
    ///
    /// The configured `EmbeddingProvider` threw `SynapseKitError.embeddingFailed`
    /// on the embed call, indicating it has no float lane at all (structural
    /// opt-out). This is the normal outcome for the default `.deterministic`
    /// provider and for any provider that does not override `embedFloat`. The
    /// dense lane is dark for this corpus; all other lanes are unaffected.
    ///
    /// Distinct from `.unavailableNoVocabHit`: that case indicates a TRAINED
    /// distributional provider where this specific query's tokens are all
    /// out-of-vocabulary. Both produce no float candidates, but the cause
    /// differs — a structural opt-out vs a vocabulary coverage gap.
    case unavailableProviderOptOut

    /// Trained distributional provider returned no float vector because all
    /// query tokens are out-of-vocabulary (OOV) — expected, not an error.
    ///
    /// The provider HAS a trained basis (vocab is non-empty) but none of the
    /// query's tokens appear in it. This is the normal outcome for a query on
    /// a thinly-trained estate or a query using vocabulary the corpus never saw.
    /// The dense lane is dark for this query; recall continues on other lanes.
    ///
    /// Distinct from `.unavailableProviderOptOut` (provider has no float lane
    /// at all) and from `.unavailableNoFloatRows` (provider supports float but
    /// ingest has not run yet or stored no rows).
    ///
    /// Surface string: `dense_lane:dark:vocabMiss`.
    case unavailableNoVocabHit

    /// No float rows are stored — expected when ingest has not run yet or the
    /// provider opted out during ingest. Dense lane is dark; other lanes are
    /// unaffected.
    case unavailableNoFloatRows

    /// Query was empty or `limit` was zero — the call was a no-op.
    ///
    /// Not a store error; the caller supplied a query that cannot produce
    /// results. No telemetry emitted for this case beyond the outcome itself.
    case emptyQuery

    /// The vector store threw an error during `findNearestFloat`.
    ///
    /// This is NOT an expected degradation. CorpusKit logs the error via OSLog
    /// (category "CorpusKit") and emits a `corpus.float_lane.store_error`
    /// telemetry counter so the failure is observable. The query still succeeds
    /// on the other lanes — this outcome degrades, not fails.
    ///
    /// - Parameter error: The underlying store error. Included for logging at
    ///   the call site; not propagated to the caller as a thrown error.
    case storeError(Error)
}

// MARK: - FloatDiscriminationSignal

/// Per-query discrimination signal from the dense float lane.
///
/// Measures how spread the top-K cosine similarity scores are, distinguishing
/// a contrastive regime (clear semantic winner) from a saturated regime (all
/// scores near-uniform, as observed with short chat turns dominated by stopword
/// mass — pairwise document cosines 0.93–0.98 collapse query-to-document cosines
/// to a similarly narrow band).
///
/// **Statistic choice — relative spread:**
/// `relativeSpread = (maxSim − minSim) / max(maxSim, 0.001)`
/// - Saturated regime (short-text RI vectors): spread ≈ 0.05 (no clear winner).
/// - Contrastive regime (meaningful semantic hit): spread ≥ 0.15.
/// - Only two values needed: the first and last of the already-sorted `.hits`
///   list — O(1) cost with zero extra store access or embed calls.
/// - Degrades safely when `maxSim ≤ 0`: returns 0.0 (treat as saturated).
///
/// **Design boundary:** CorpusKit computes and reports; GLK (RecallDirector)
/// decides what to do with the signal. CorpusKit never changes behaviour based
/// on it — measurement only. Standalone CorpusKit consumers receive the raw
/// signal for their own fusion decisions.
public struct FloatDiscriminationSignal: Sendable {
    /// Relative spread of top-K hit cosines: (max − min) / max (or 0 when max ≤ 0).
    ///
    /// 0.0 = perfectly saturated (all scores identical, or max cosine non-positive);
    /// 1.0 = maximally discriminating (best score, worst near 0).
    ///
    /// Threshold guidance for GLK consumers (defined in RecallDirector):
    ///   < 0.10 → clearly saturated regime — strong discount.
    ///   0.10–0.15 → transition band — partial discount.
    ///   ≥ 0.15 → contrastive — no discount (discriminationFactor = 1.0).
    public let relativeSpread: Float

    /// Hit count K used to compute the spread (top-K hits, after limit truncation).
    public let hitCount: Int
}
#endif // MOOTX01_WHOLE_RECORD_DENSE
