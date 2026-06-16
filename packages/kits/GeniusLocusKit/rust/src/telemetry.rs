// telemetry.rs — Per-estate rollup telemetry for GeniusLocusKit (GLK_ROLLUPS_001).
//
// Rust parity of `Sources/GeniusLocusKit/GeniusLocusKitTelemetry.swift`.
//
// DESIGN: OFF-PATH IS FREE
// All emit calls use the `report!` macro from intellectus_lib, which expands to:
//   if Intellectus::is_enabled() { Intellectus::report_sample(expr) }
// When monitoring is disabled (the default), the argument expression is NEVER
// evaluated — cost is a single AtomicBool::load(Acquire) + branch (~1 ns,
// lock-free). Results are byte-identical whether monitoring is on or off.
//
// METRIC NAMESPACE
// All metrics are under `geniuslocus.estate.*` to distinguish these per-estate
// rollups from per-kit metrics emitted by LocusKit, VectorKit, and CorpusKit.
//
// TIMESTAMPS
// Rust is synchronous; timestamps are produced via
// `std::time::SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs_f64()`.
// This mirrors the Swift pattern of using `Date().timeIntervalSince1970`
// inside the autoclosure — evaluated only when monitoring is enabled.

/// Canonical metric names for the `geniuslocus.estate.*` namespace.
/// Mirrors `GLKMetricName` in the Swift port. Adding a new metric
/// here is the only place the name is authored — prevents drift across files.
pub mod metric_names {
    /// A per-estate mount state transition (mounted/quiesced/draining/unmounted).
    /// Tagged: `estate_id`, `state`.
    pub const MOUNT_STATE_TRANSITION: &str = "geniuslocus.estate.mount_state_transition";

    /// A provisioning event (create + open + wiring) for a new estate.
    /// Tagged: `estate_id`, `kind`.
    pub const PROVISION: &str = "geniuslocus.estate.provision";

    /// Snapshot of the estate's active drawer count at admission time.
    /// Tagged: `estate_id`.
    pub const NOUN_COUNT: &str = "geniuslocus.estate.noun_count";

    /// A verb error crossing the GLK estate boundary in `remap`.
    /// Tagged: `estate_id`, `verb`.
    pub const VERB_ERROR: &str = "geniuslocus.estate.verb_error";

    /// The dense float lane (Lane D) was dark for a recall query.
    ///
    /// Emitted by `recall_scored_multi_lane` (Step 4.5) when
    /// `float_nearest` returns any outcome other than `Hits`. The
    /// `reason` tag carries the dark-lane classification:
    /// `providerOptOut`, `noFloatRows`, or `storeError`. Use this
    /// counter to detect misconfigured estates where the dense lane
    /// is expected but consistently dark. Mirrors Swift
    /// `GLKMetricName.denseLaneDark`. Tagged: `estate_id`, `reason`.
    pub const DENSE_LANE_DARK: &str = "glk.recall.dense_lane_dark";

    // ── Stage-degradation counters (P1 fail-loud degradation contract) ──
    //
    // Each counter mirrors the corresponding Swift `GLKMetricName.*Degraded`
    // constant. Names are identical across ports so cross-fleet dashboards
    // can aggregate Swift and Rust estate counters without aliasing.

    /// The Hamming vector lane's `find_nearest` call threw.
    ///
    /// Emitted by `recall_scored_multi_lane` when `VectorStore::find_nearest`
    /// fails (hybrid or unionBest lane with a registered vector store). The
    /// query survives on locus and BM25 signals; the vector column is absent
    /// from hit scores. Mirrors Swift `GLKMetricName.vectorHammingDegraded`.
    /// Tagged: `estate_id`, `lane` (hybrid | unionBest).
    pub const VECTOR_HAMMING_DEGRADED: &str = "glk.recall.vectorHamming.findNearest_degraded";

    /// The embedding call inside `recall_scored_multi_lane` threw.
    ///
    /// Emitted when `Corpus::embed` fails during query-sketch preparation.
    /// The vector lane is dark for this query — same downstream effect as
    /// `VECTOR_HAMMING_DEGRADED`, but the failure happened one step earlier
    /// (before `find_nearest` was called). Mirrors Swift
    /// `GLKMetricName.corpusEmbedDegraded`. Tagged: `estate_id`, `lane`.
    pub const CORPUS_EMBED_DEGRADED: &str = "glk.recall.corpus.embed_degraded";

    // ── Scoring-fallback degradation counters ──
    //
    // These name a REQUESTED-SCORING fallback (not an exceptional stage
    // failure): the requested scoring strategy is not a distinct implementation
    // in that lane, so a simpler combiner was applied. The query succeeds; the
    // result envelope names the fallback in `degraded_stages` so the caller
    // knows the requested scoring was not the one applied. Names are identical
    // across ports. The genuinely-implemented combos (UnionBest+MatrixAware;
    // Hybrid/CorpusOnly+Rrf) do NOT emit. Mirror Swift `GLKMetricName`.

    /// `MatrixAware` requested on `LocusOnly` (no matrix pass) → raw ordering.
    /// Mirrors Swift `GLKMetricName.locusOnlyMatrixAwareFallback`. Tagged: `estate_id`.
    pub const LOCUS_ONLY_MATRIX_AWARE_FALLBACK: &str = "glk.recall.locusOnly.matrixAware_degraded";

    /// `MatrixAware` requested on `CorpusOnly` (no matrix pass) → RRF fusion.
    /// Mirrors Swift `GLKMetricName.corpusOnlyMatrixAwareFallback`. Tagged: `estate_id`.
    pub const CORPUS_ONLY_MATRIX_AWARE_FALLBACK: &str = "glk.recall.corpusOnly.matrixAware_degraded";

    /// `MatrixAware` requested on `Hybrid` (no matrix pass) → three-way RRF.
    /// Mirrors Swift `GLKMetricName.hybridMatrixAwareFallback`. Tagged: `estate_id`.
    pub const HYBRID_MATRIX_AWARE_FALLBACK: &str = "glk.recall.hybrid.matrixAware_degraded";

    /// `Rrf` requested on `UnionBest` (no distinct RRF fusion) → raw lane score.
    /// Mirrors Swift `GLKMetricName.unionBestRRFFallback`. Tagged: `estate_id`.
    pub const UNION_BEST_RRF_FALLBACK: &str = "glk.recall.unionBest.rrf_degraded";
}

/// Produce the current time as epoch seconds (f64) for telemetry timestamps.
///
/// Used inside `report!` argument expressions — only evaluated when monitoring
/// is enabled. Never called on the disabled path.
#[inline(always)]
pub fn now_secs() -> f64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// Emit a `geniuslocus.estate.*` metric through `Intellectus`.
///
/// This is a convenience wrapper around the `report!` macro. The `tags`
/// parameter is built at the call site so it is NOT inside the macro argument
/// — which is fine because HashMap allocation only happens when monitoring is
/// enabled (the macro guard fires first). Callers that want zero allocation on
/// the disabled path should inline `report!` with a HashMap constructed inside
/// the macro argument.
///
/// All current call sites use this convenience form; the comment above
/// documents the tradeoff for future callers.
#[macro_export]
macro_rules! glk_emit {
    ($name:expr, $value:expr, $tags:expr) => {
        intellectus_lib::report!({
            intellectus_lib::StatSample::metric(
                $name.to_string(),
                $value,
                $tags,
                $crate::telemetry::now_secs(),
            )
        })
    };
}
