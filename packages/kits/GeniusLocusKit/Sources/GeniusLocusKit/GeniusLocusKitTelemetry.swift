// GeniusLocusKitTelemetry.swift
//
// Per-estate rollup telemetry for GeniusLocusKit — GLK_ROLLUPS_001.
//
// WHAT THIS FILE DOES
// Declares the metric name constants for the `geniuslocus.estate.*` namespace
// and the shared inline helper `glkEmit` that wraps Intellectus.report with
// the correct construction. Actual emit call sites live in EstateCoordinator,
// EstateLifecycle, and VerbSurface — this file is the canonical source of
// metric names so they cannot drift across files.
//
// DESIGN: OFF-PATH IS FREE
// All emit calls use `Intellectus.report(@autoclosure)`. When monitoring is
// disabled (the default), the autoclosure is NEVER evaluated — cost is a
// single Atomic<Bool> load (~1 ns, lock-free). Estate coordination results
// are byte-identical whether monitoring is on or off.
//
// METRIC NAMESPACE
// All metrics are under `geniuslocus.estate.*` to distinguish these per-estate
// rollups from per-kit metrics emitted by LocusKit, VectorKit, and CorpusKit
// (which use `locus.*`, `vector.*`, `corpus.*` respectively).
//
// CALLER-SUPPLIED TIMESTAMPS
// All emit sites receive `now: Date` as a parameter per the fleet determinism
// rule (CLAUDE.md: never call Date() inside an engine). The `ts` field is
// `now.timeIntervalSince1970`.
//
// METRICS EMITTED (one sample set per estate, tagged by estate_id):
//
//   geniuslocus.estate.mount_state_transition
//     value = 1.0 (one transition)
//     tags: estate_id, state (mounted | quiesced | draining | unmounted)
//
//   geniuslocus.estate.provision
//     value = 1.0 (one provision event)
//     tags: estate_id, kind (GLK | CorpusOnly | LocusOnly)
//
//   geniuslocus.estate.noun_count
//     value = drawer count (Double)
//     tags: estate_id
//     emitted at open() if monitoring is on — snapshot of the estate's
//     drawer count at admission time (zero for fresh estates, non-zero
//     for re-opened existing ones).
//
//   geniuslocus.estate.verb_error
//     value = 1.0 (one error event)
//     tags: estate_id, verb
//     emitted when a verb call crosses the error boundary in remap().

import Foundation
import IntellectusLib

// MARK: - Metric name constants

/// Canonical metric names for the `geniuslocus.estate.*` telemetry namespace.
///
/// Every emit site imports this enum so names cannot drift. Adding a new
/// metric here is the only place the name is authored.
enum GLKMetricName {

    /// A per-estate mount state transition (mounted/quiesced/draining/unmounted).
    /// Tagged: `estate_id`, `state`.
    static let mountStateTransition = "geniuslocus.estate.mount_state_transition"

    /// A provisioning event (create + open + wiring) for a new estate.
    /// Tagged: `estate_id`, `kind`.
    static let provision = "geniuslocus.estate.provision"

    /// Snapshot of the estate's active drawer count at admission time.
    /// Tagged: `estate_id`.
    static let nounCount = "geniuslocus.estate.noun_count"

    /// A verb error crossing the GLK estate boundary in `remap()`.
    /// Tagged: `estate_id`, `verb`.
    static let verbError = "geniuslocus.estate.verb_error"

    /// The dense float lane (Lane D) was dark for a recall query.
    ///
    /// Emitted by Step 4.5 of the RecallDirector when `floatNearest` returns
    /// any outcome other than `.hits`. The `reason` tag carries the dark-lane
    /// classification: `providerOptOut`, `noFloatRows`, or `storeError`. Use
    /// this counter to detect misconfigured estates where the dense lane is
    /// expected but consistently dark (e.g. provider not wired up after ingest).
    /// Tagged: `estate_id`, `reason`.
    static let denseLaneDark = "glk.recall.dense_lane_dark"

    // MARK: — Stage-degradation counters (P1 fail-loud degradation contract)

    /// The Hamming vector lane's `findNearest` call threw.
    ///
    /// Emitted by the RecallDirector when `VectorStore.findNearest` fails
    /// (corpusOnly, hybrid, or unionBest lane). The query survives; the
    /// vector column is absent from hit scores. Tagged: `estate_id`, `lane`
    /// (corpusOnly | hybrid | unionBest).
    static let vectorHammingDegraded = "glk.recall.vectorHamming.findNearest_degraded"

    /// The embedding call inside `compileSketch` threw.
    ///
    /// Emitted when `corpus.embed` fails during query-sketch compilation.
    /// The vector lane is dark for this query — same downstream effect as
    /// `vectorHammingDegraded`. Tagged: `estate_id`, `lane`.
    static let corpusEmbedDegraded = "glk.recall.corpus.embed_degraded"

    /// The structured pool load (`estate.getDrawers`) threw in `unionBest`.
    ///
    /// Emitted when the body-free wide-pool load (step 5.5) fails. All
    /// matrix/graph/preference scoring columns are zero for this query.
    /// Tagged: `estate_id`.
    static let poolGetDrawersDegraded = "glk.recall.pool.getDrawers_degraded"

    /// The MMR content-hydration step threw in `unionBest`.
    ///
    /// Emitted when `estate.hydrateBodies` fails at step 9.5 (MMR content
    /// for `.full` recall). MMR ran on sourceMask Jaccard proxy instead of
    /// content shingles. Tagged: `estate_id`.
    static let poolHydrateBodiesMMRDegraded = "glk.recall.pool.hydrateBodies.mmr_degraded"

    /// The late-hydration step for returned hits threw in `unionBest`.
    ///
    /// Emitted when `estate.hydrateBodies` fails at step 10.5. Returned
    /// hits carry empty `content` fields for `.structured` recall.
    /// Tagged: `estate_id`.
    static let poolHydrateBodiesReturnDegraded = "glk.recall.pool.hydrateBodies.return_degraded"

    /// The frontier candidate `getDrawers` call threw in the `hybrid` lane.
    ///
    /// Emitted when `estate.getDrawers` fails while hydrating BM25/vector
    /// frontier candidates. BM25/vector hits not in the locus index are absent.
    /// Tagged: `estate_id`.
    static let hybridGetDrawersDegraded = "glk.recall.hybrid.getDrawers_degraded"

    /// The frontier candidate `getDrawers` call threw in the `corpusOnly` lane.
    ///
    /// Emitted when `estate.getDrawers` fails while loading fused candidates
    /// for the corpusOnly lane. Returned hits may be empty even with BM25/vector
    /// candidates present. Tagged: `estate_id`.
    static let corpusOnlyGetDrawersDegraded = "glk.recall.corpusOnly.getDrawers_degraded"

    // MARK: — Scoring-fallback degradation counters
    //
    // These name a REQUESTED-SCORING fallback (not an exceptional stage
    // failure): the caller asked for a scoring strategy that is not yet a
    // distinct implementation in that lane, so the director fell back to a
    // simpler combiner. The query succeeds; the result envelope names the
    // fallback in `degradedStages` so the caller knows the requested scoring
    // was not the one applied — replacing the previously-silent downgrade.
    // The genuinely-implemented combos (unionBest+matrixAware, the full
    // weighted pipeline; hybrid/corpusOnly+rrf, real RRF fusion) do NOT emit.

    /// `matrixAware` was requested for the `locusOnly` lane, which has no
    /// matrix scoring pass; the lane returned raw bitmap-evaluator ordering.
    /// Tagged: `estate_id`.
    static let locusOnlyMatrixAwareFallback = "glk.recall.locusOnly.matrixAware_degraded"

    /// `matrixAware` was requested for the `corpusOnly` lane, which has no
    /// matrix scoring pass; the lane fell back to RRF fusion of BM25 + vector.
    /// Tagged: `estate_id`.
    static let corpusOnlyMatrixAwareFallback = "glk.recall.corpusOnly.matrixAware_degraded"

    /// `matrixAware` was requested for the `hybrid` lane, which has no matrix
    /// scoring pass; the lane fell back to three-way RRF fusion. Tagged: `estate_id`.
    static let hybridMatrixAwareFallback = "glk.recall.hybrid.matrixAware_degraded"

    /// `rrf` was requested for the `unionBest` lane, which implements the
    /// weighted matrix-aware pipeline and a raw pass but not a distinct
    /// equal-weight RRF fusion across lane scores; it fell back to the raw
    /// (`buffer.final`) lane-normalised score. Tagged: `estate_id`.
    static let unionBestRRFFallback = "glk.recall.unionBest.rrf_degraded"
}

// MARK: - Shared emit helper

/// Emit a `geniuslocus.estate.*` metric through `Intellectus`.
///
/// Wraps `Intellectus.report` so each call site is a single line. The
/// `@autoclosure` on the `Intellectus.report` call means this helper is
/// itself an ordinary (non-autoclosure) call — the autoclosure optimisation
/// lives inside `Intellectus.report(_:)`. The caller supplies `now` so no
/// clock is read inside this helper (fleet determinism rule).
///
/// - Parameters:
///   - name:  Metric name from `GLKMetricName.*`.
///   - value: The measured quantity.
///   - tags:  String key-value context. Must always include `estate_id`.
///   - now:   Caller-supplied timestamp. Converted to epoch seconds for `ts`.
@inline(__always)
func glkEmit(name: String, value: Double, tags: [String: String], now: Date) {
    Intellectus.report(.metric(
        name: name,
        value: value,
        tags: tags,
        ts: now.timeIntervalSince1970
    ))
}
