// float_lane.rs: the whole-record float query surface of `Corpus`.
//
// Holds the observable
// `FloatLaneOutcome`, the per-query `FloatDiscriminationSignal`, and the
// nearest / farthest per-signal recall over the stored float rows
// (vector_index 1). The default build has none of this: the span stage is
// the one dense provider (ruling 2026-09-07). Swift twin:
// Sources/CorpusKitWholeRecordDense/Corpus+FloatLane.swift and
// FloatLaneOutcome.swift.

use super::*;
use intellectus_lib::{report, StatSample};
use synapsekit::SearchDirection;

/// Observable outcome of a `Corpus::float_nearest` call.
///
/// Mirrors Swift `FloatLaneOutcome`. Dark outcomes are EXPECTED degradations;
/// the caller degrades gracefully. `StoreError` is NOT expected: the error
/// description is emitted via `eprintln!` (Rust has no OSLog equivalent) and
/// counted via `corpus.float_lane.store_error` so failures are never swallowed.
///
/// Callers must never treat a dark outcome as a failure. A dark dense lane
/// means the query continues on other lanes only.
#[derive(Debug)]
pub enum FloatLaneOutcome {
    /// Lane ran and returned at least one ranked hit.
    ///
    /// Contains `(item_id, cosine_similarity)` pairs nearest-first.
    /// `item_id` == `source_id` at ingest time (drawer ID in the GLK context).
    /// Similarity ∈ \[−1, 1\], 1.0 = identical direction.
    Hits(Vec<(String, f32)>),

    /// Provider opted out — expected, not an error.
    ///
    /// The provider's `embed_float` errored (it has no float lane). This is
    /// the normal outcome for `EmbeddingModelConfig::Deterministic` on
    /// providers that do not override `embed_float`. The dense lane is dark;
    /// all other lanes are unaffected.
    UnavailableProviderOptOut,

    /// No float rows stored — expected when ingest has not run with a
    /// float-capable provider. Dense lane is dark; other lanes unaffected.
    UnavailableNoFloatRows,

    /// Trained distributional provider, but all query tokens were
    /// out-of-vocabulary (OOV) — expected, not an error.
    ///
    /// The provider HAS a trained basis (vocab is non-empty) but none of
    /// the query's tokens appear in it. The recall result is identical to
    /// `UnavailableProviderOptOut` (empty dense lane), but the reason is
    /// different: the provider CAN produce float vectors; the query simply
    /// did not hit the vocabulary.
    ///
    /// Surface string: `dense_lane:dark:vocabMiss`.
    UnavailableNoVocabHit,

    /// Query was empty or `limit` was zero — the call was a no-op.
    ///
    /// No telemetry emitted: the guard fired before any store access.
    EmptyQuery,

    /// Vector store threw during `find_nearest_float`.
    ///
    /// NOT an expected degradation. The error is printed via `eprintln!`
    /// (Rust has no OSLog; this mirrors Swift's `corpusLog.error`) and
    /// counted via `corpus.float_lane.store_error` so dashboards surface it.
    /// The query continues on other lanes — this degrades, never fails.
    StoreError(String),
}

// MARK: - FloatDiscriminationSignal

/// Per-query discrimination signal from the dense float lane.
///
/// Mirrors Swift `FloatDiscriminationSignal`. Measures how spread the top-K
/// cosine similarity scores are, distinguishing a contrastive regime (clear
/// semantic winner) from a saturated regime (all scores near-uniform, as
/// observed with short chat turns dominated by stopword mass —
/// pairwise document cosines 0.93–0.98 collapse query-to-document cosines
/// to a similarly narrow band).
///
/// **Statistic:** `relative_spread = (max_sim − min_sim) / max(max_sim, 0.001)`
/// - Saturated: spread ≈ 0.05 (no clear winner).
/// - Contrastive: spread ≥ 0.15.
/// - O(1) from the already-sorted `.Hits` list (first and last elements).
/// - Degrades safely when `max_sim ≤ 0`: returns 0.0 (treat as saturated).
///
/// **Design boundary:** CorpusKit measures; GLK (coordinator) applies policy.
/// No behaviour change inside CorpusKit — measurement only.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FloatDiscriminationSignal {
    /// Relative spread of top-K hit cosines: (max − min) / max (or 0 when max ≤ 0).
    ///
    /// 0.0 = perfectly saturated; 1.0 = maximally discriminating.
    ///
    /// Threshold guidance for GLK consumers (defined in coordinator.rs):
    ///   < 0.10 → clearly saturated — strong discount.
    ///   0.10–0.15 → transition band — partial discount.
    ///   ≥ 0.15 → contrastive — no discount (discrimination_factor = 1.0).
    pub relative_spread: f32,
    /// Hit count K used to compute the spread (top-K hits, after limit truncation).
    pub hit_count: usize,
}

/// Compute a `FloatDiscriminationSignal` from a `FloatLaneOutcome`.
///
/// Returns `Some` only for `Hits` with at least one result. The `relative_spread`
/// `(max_sim − min_sim) / max(max_sim, 0.001)` is computed from the first and last
/// elements of the already-sorted similarity list — O(1), zero extra I/O.
///
/// This function is `pub(crate)` so both `Corpus` and `CorpusContentEngine` use
/// it without duplicating the measurement logic.
pub(crate) fn discrimination_signal_from_outcome(
    outcome: &FloatLaneOutcome,
) -> Option<FloatDiscriminationSignal> {
    if let FloatLaneOutcome::Hits(hits) = outcome {
        if hits.is_empty() {
            return None;
        }
        // `hits` is sorted nearest-first (highest cosine first).
        let max_sim = hits[0].1;
        let min_sim = hits[hits.len() - 1].1;
        let spread = if max_sim > 0.001 {
            (max_sim - min_sim) / max_sim
        } else {
            0.0
        };
        Some(FloatDiscriminationSignal {
            relative_spread: spread.max(0.0),
            hit_count: hits.len(),
        })
    } else {
        None
    }
}

// MARK: - EmbeddingModelConfig

impl Corpus {
    /// Dense float nearest-neighbour recall (Lane D): embed `query` to its
    /// pooled float vector and rank stored chunks by cosine over the in-house
    /// `FloatBruteForceIndex`. Returns a `FloatLaneOutcome` that is always
    /// observable — dark lanes carry a typed reason, store errors are printed
    /// and counted via telemetry, never swallowed.
    ///
    /// Mirrors Swift `Corpus.floatNearest(query:limit:)`.
    ///
    /// **Degradation contract:** this method never panics. A dark lane is
    /// represented as `UnavailableProviderOptOut`, `UnavailableNoFloatRows`,
    /// or `EmptyQuery` — all expected. `StoreError` is NOT expected: the
    /// error is printed via `eprintln!` and emitted as
    /// `corpus.float_lane.store_error` telemetry so the failure is always
    /// observable. The query continues on other lanes.
    ///
    /// **Telemetry** (off by default — single `AtomicBool::load(Acquire)` when disabled):
    /// - `corpus.float_lane.hit`           — lane ran and returned ≥1 result.
    /// - `corpus.float_lane.dark_provider` — provider opted out.
    /// - `corpus.float_lane.dark_no_rows`  — no float rows stored.
    /// - `corpus.float_lane.store_error`   — unexpected store failure.
    pub fn float_nearest(&self, query: &str, limit: usize) -> FloatLaneOutcome {
        if limit == 0 || query.is_empty() {
            // Empty query or zero limit — no telemetry: this is a no-op call.
            return FloatLaneOutcome::EmptyQuery;
        }

        // Test-only hook: if a forced error is installed, consume it and return
        // StoreError immediately — mirrors the Swift `_forcedFloatError` seam.
        // Compiled in only when the `test-seams` feature is active; the block
        // is completely absent from production builds.
        #[cfg(any(test, feature = "test-seams"))]
        {
            let mut guard = self.forced_float_error.lock()
                .unwrap_or_else(|p| p.into_inner());
            if let Some(err_str) = guard.take() {
                drop(guard);
                eprintln!("corpus.float_nearest: find_nearest_float failed (forced) — {}", err_str);
                report!(StatSample::metric(
                    "corpus.float_lane.store_error".to_string(),
                    1.0,
                    [("kit".to_string(), "CorpusKit".to_string())]
                        .into_iter().collect(),
                    {
                        use std::time::{SystemTime, UNIX_EPOCH};
                        SystemTime::now().duration_since(UNIX_EPOCH)
                            .map(|d| d.as_secs_f64()).unwrap_or(0.0)
                    },
                ));
                return FloatLaneOutcome::StoreError(err_str);
            }
        }

        // Single-signal entry point: run the dense float lane on the DEFAULT
        // signal. The per-provider mechanics live in `float_nearest_for_slot` so
        // `float_nearest_per_signal` can reuse them unchanged.
        self.float_nearest_for_slot(self.default_slot(), query, limit, SearchDirection::Nearest)
    }

    /// Dense float nearest-neighbour recall for ONE slot — the per-signal
    /// mechanics shared by `float_nearest` (default signal) and
    /// `float_nearest_per_signal` (every held signal).
    ///
    /// Embeds `query` via the slot provider's `embed_float`, ranks stored chunks
    /// for that slot's model_id by cosine over the in-house `FloatBruteForceIndex`,
    /// aggregates chunk hits to source (drawer) level, and returns an observable
    /// `FloatLaneOutcome`. The telemetry counters and the degradation contract
    /// are identical to the original single-provider `float_nearest`; the only
    /// change is that the slot is a parameter rather than the sole field, so for
    /// N=1 (default signal) the behaviour is byte-identical. The caller is
    /// responsible for the empty-query guard and the forced-error test hook (both
    /// live on the `float_nearest` entry point only).
    ///
    /// `direction` selects the objective (mission 6b-modifiers-antisim):
    ///   - `Nearest`  — surface the most SIMILAR sources. The store returns the
    ///     nearest chunks; a source's score is its BEST (max) chunk cosine;
    ///     sources rank similarity DESCENDING. Byte-identical to the pre-antisim
    ///     behaviour.
    ///   - `Farthest` — surface the most DISSIMILAR sources ("find things UNLIKE
    ///     this"). The store returns the farthest chunks; a source's score is its
    ///     WORST (min) chunk cosine (a source is unlike the query only if even
    ///     its closest chunk is far); sources rank similarity ASCENDING.
    fn float_nearest_for_slot(
        &self,
        slot: &ProviderSlot,
        query: &str,
        limit: usize,
        direction: SearchDirection,
    ) -> FloatLaneOutcome {
        // Attempt to embed the query via the float lane. A provider without a
        // float lane will error here — this is the expected opt-out path (not a
        // store error). Emit the dark_provider counter so callers can observe it.
        // float_nearest returns a FloatLaneOutcome (no Result), so the provider
        // Mutex is locked with a poison-tolerant fallback rather than `?`.
        let probe_result = {
            let guard = slot
                .handle
                .lock()
                .unwrap_or_else(|p| p.into_inner());
            guard.provider().embed_float(query)
        };
        let probe = match probe_result {
            Ok(p) if !p.is_empty() => p,
            Ok(_) => {
                // Provider returned an empty vector without throwing — structural
                // opt-out (provider has no float lane or no trained basis).
                report!(StatSample::metric(
                    "corpus.float_lane.dark_provider".to_string(),
                    1.0,
                    [("kit".to_string(), "CorpusKit".to_string())]
                        .into_iter().collect(),
                    {
                        use std::time::{SystemTime, UNIX_EPOCH};
                        SystemTime::now().duration_since(UNIX_EPOCH)
                            .map(|d| d.as_secs_f64()).unwrap_or(0.0)
                    },
                ));
                return FloatLaneOutcome::UnavailableProviderOptOut;
            }
            Err(SynapseKitError::EmbedFloatVocabMiss(_)) => {
                // Trained distributional provider: all query tokens were OOV.
                // Truthful relabel: the provider HAS a basis but none of the
                // query terms are in it — this is vocabMiss, not providerOptOut.
                report!(StatSample::metric(
                    "corpus.float_lane.dark_vocab_miss".to_string(),
                    1.0,
                    [("kit".to_string(), "CorpusKit".to_string())]
                        .into_iter().collect(),
                    {
                        use std::time::{SystemTime, UNIX_EPOCH};
                        SystemTime::now().duration_since(UNIX_EPOCH)
                            .map(|d| d.as_secs_f64()).unwrap_or(0.0)
                    },
                ));
                return FloatLaneOutcome::UnavailableNoVocabHit;
            }
            Err(_) => {
                // Any other error — structural opt-out (no float lane).
                report!(StatSample::metric(
                    "corpus.float_lane.dark_provider".to_string(),
                    1.0,
                    [("kit".to_string(), "CorpusKit".to_string())]
                        .into_iter().collect(),
                    {
                        use std::time::{SystemTime, UNIX_EPOCH};
                        SystemTime::now().duration_since(UNIX_EPOCH)
                            .map(|d| d.as_secs_f64()).unwrap_or(0.0)
                    },
                ));
                return FloatLaneOutcome::UnavailableProviderOptOut;
            }
        };

        // Over-fetch 4× at CHUNK granularity so after source-level aggregation
        // we still have at least `limit` sources — mirrors bm25_top_k_by_source.
        // Direction selects which end of the cosine ranking the store returns;
        // farthest is NOT a reordering of nearest (the dissimilar chunks are not
        // in the nearest top-K), so the store runs the farthest scan.
        let store_result = match direction {
            // Corpus (old type) always uses cosine — metric selection is on CorpusContentEngine.
            SearchDirection::Nearest => self.vector_store.find_nearest_float(
                &probe,
                &slot.model_id,
                limit.saturating_mul(4),
                synapsekit::engine::metric::FloatMetric::Cosine,
            ),
            SearchDirection::Farthest => self.vector_store.find_farthest_float(
                &probe,
                &slot.model_id,
                limit.saturating_mul(4),
                synapsekit::engine::metric::FloatMetric::Cosine,
            ),
        };
        let matches = match store_result {
            Ok(m) => m,
            Err(e) => {
                // Store threw — NOT expected. Print so the error is never
                // silent (mirrors Swift's corpusLog.error via OSLog). Emit
                // the store_error counter so dashboards surface the failure.
                let err_str = format!("{:?}", e);
                eprintln!("corpus.float_nearest: find_nearest_float failed — {}", err_str);
                report!(StatSample::metric(
                    "corpus.float_lane.store_error".to_string(),
                    1.0,
                    [("kit".to_string(), "CorpusKit".to_string())]
                        .into_iter().collect(),
                    {
                        use std::time::{SystemTime, UNIX_EPOCH};
                        SystemTime::now().duration_since(UNIX_EPOCH)
                            .map(|d| d.as_secs_f64()).unwrap_or(0.0)
                    },
                ));
                return FloatLaneOutcome::StoreError(err_str);
            }
        };

        // Empty matches — no float rows stored. Expected dark outcome.
        if matches.is_empty() {
            report!(StatSample::metric(
                "corpus.float_lane.dark_no_rows".to_string(),
                1.0,
                [("kit".to_string(), "CorpusKit".to_string())]
                    .into_iter().collect(),
                {
                    use std::time::{SystemTime, UNIX_EPOCH};
                    SystemTime::now().duration_since(UNIX_EPOCH)
                        .map(|d| d.as_secs_f64()).unwrap_or(0.0)
                },
            ));
            return FloatLaneOutcome::UnavailableNoFloatRows;
        }

        // Aggregate chunk-level cosine to SOURCE (drawer) level via the in-memory
        // reverse map: the vector item_id is the chunk uuid string;
        // chunk_source_map resolves it to the sourceID ingested under (the drawer
        // id in the GLK context), exactly as bm25_top_k_by_source does, so float
        // hits hydrate back to the real Drawer row.
        //   Nearest  — a source's similarity is its BEST (max) chunk cosine.
        //   Farthest — a source's anti-similarity is governed by its WORST (min)
        //              chunk cosine: a source is "unlike the query" only if even
        //              its closest chunk is far. Picking max here would surface
        //              sources with one near chunk — the opposite objective.
        // VectorMatch.distance is the cosine DISTANCE (1 − sim) ×10_000; recover
        // sim = 1 − dist/10_000.
        let csm = match self.chunk_source_map.lock() {
            Ok(guard) => guard,
            Err(_) => return FloatLaneOutcome::UnavailableNoFloatRows,
        };
        let mut by_source: std::collections::HashMap<String, f32> =
            std::collections::HashMap::new();
        for m in &matches {
            let chunk_uuid = match uuid::Uuid::parse_str(&m.item_id) {
                Ok(u) => u,
                Err(_) => continue,
            };
            if let Some(source_id) = csm.get(&chunk_uuid) {
                let similarity = 1.0 - m.distance as f32 / 10_000.0;
                match direction {
                    SearchDirection::Nearest => {
                        let entry = by_source
                            .entry(source_id.clone())
                            .or_insert(f32::NEG_INFINITY);
                        *entry = entry.max(similarity);
                    }
                    SearchDirection::Farthest => {
                        let entry = by_source
                            .entry(source_id.clone())
                            .or_insert(f32::INFINITY);
                        *entry = entry.min(similarity);
                    }
                }
            }
        }
        drop(csm);

        // After aggregation: empty by_source means no chunks in the reverse
        // map (all chunks removed). Treat as no-rows dark.
        if by_source.is_empty() {
            report!(StatSample::metric(
                "corpus.float_lane.dark_no_rows".to_string(),
                1.0,
                [("kit".to_string(), "CorpusKit".to_string())]
                    .into_iter().collect(),
                {
                    use std::time::{SystemTime, UNIX_EPOCH};
                    SystemTime::now().duration_since(UNIX_EPOCH)
                        .map(|d| d.as_secs_f64()).unwrap_or(0.0)
                },
            ));
            return FloatLaneOutcome::UnavailableNoFloatRows;
        }

        // Sort by similarity, source_id ascending on tie — the universal
        // deterministic tie-break — and return the top `limit`.
        //   Nearest  — similarity DESCENDING (most similar first).
        //   Farthest — similarity ASCENDING (most dissimilar first).
        // The tie-break (source_id ascending) is identical in both directions.
        let mut ranked: Vec<(String, f32)> = by_source.into_iter().collect();
        ranked.sort_by(|a, b| {
            let primary = match direction {
                SearchDirection::Nearest => b.1.partial_cmp(&a.1),
                SearchDirection::Farthest => a.1.partial_cmp(&b.1),
            }
            .unwrap_or(std::cmp::Ordering::Equal);
            primary.then_with(|| a.0.cmp(&b.0))
        });
        ranked.truncate(limit);

        // Happy path — lane ran. Emit hit counter.
        let hit_count = ranked.len();
        report!(StatSample::metric(
            "corpus.float_lane.hit".to_string(),
            hit_count as f64,
            [("kit".to_string(), "CorpusKit".to_string())]
                .into_iter().collect(),
            {
                use std::time::{SystemTime, UNIX_EPOCH};
                SystemTime::now().duration_since(UNIX_EPOCH)
                    .map(|d| d.as_secs_f64()).unwrap_or(0.0)
            },
        ));
        FloatLaneOutcome::Hits(ranked)
    }

    /// Per-signal dense float nearest-neighbour recall (the 6b RRF-fusion seam).
    ///
    /// Runs the dense float lane independently for EVERY held provider slot, each
    /// queried against its own model_id float index, and returns one ranked
    /// `FloatLaneOutcome` per signal tagged by that signal's `model_id`. The
    /// outcome ordering follows slot (construction) order, so `[0]` is always the
    /// default signal. Mirrors Swift `Corpus.floatNearestPerSignal`.
    ///
    /// This is the seam the 6b mission's RRF/consensus fusion consumes: each
    /// signal's per-source similarity ranking is exposed separately, preserving
    /// the `FloatLaneOutcome` dark-lane observability per signal. NO fusion
    /// happens here — the caller (6b) decides how to combine the per-signal
    /// lists.
    ///
    /// For N=1 this returns a single-element vec whose only outcome equals what
    /// `float_nearest(query, limit)` would return — same default-signal mechanics.
    /// An empty query or zero limit returns one `EmptyQuery` outcome per signal
    /// (no store access), mirroring the single-signal no-op guard. The forced-error
    /// test hook is NOT consulted here (it lives on `float_nearest` only).
    ///
    /// - Returns: `(model_id, outcome)` pairs, one per held signal, in slot order.
    pub fn float_nearest_per_signal(
        &self,
        query: &str,
        limit: usize,
    ) -> Vec<(String, FloatLaneOutcome)> {
        // No-op guard mirrors float_nearest: an empty query / zero limit yields a
        // per-signal EmptyQuery without touching the store. One entry per signal
        // keeps the result shape stable (the caller can still see every model_id).
        if limit == 0 || query.is_empty() {
            return self
                .slots
                .iter()
                .map(|s| (s.model_id.clone(), FloatLaneOutcome::EmptyQuery))
                .collect();
        }

        // Test-only hook: a forced store error is consumed for the DEFAULT slot
        // (slot 0), mirroring the single-signal `float_nearest` contract and the
        // Swift `floatNearestPerSignal` seam. GLK's dense lane consumes this method,
        // so the store-error dark contract must remain observable through the
        // per-signal path: the default signal reports StoreError, other slots run
        // normally. Single-use; consumed here exactly as the single-signal entry.
        // `FloatLaneOutcome` is not `Clone`, so the forced error description is held
        // as a `String` and a fresh `StoreError` is constructed for slot 0 below.
        #[cfg(any(test, feature = "test-seams"))]
        let forced_default_store_error: Option<String> = {
            let mut guard = self.forced_float_error.lock()
                .unwrap_or_else(|p| p.into_inner());
            if let Some(err_str) = guard.take() {
                drop(guard);
                eprintln!("corpus.float_nearest_per_signal: find_nearest_float failed (default signal, forced) — {}", err_str);
                report!(StatSample::metric(
                    "corpus.float_lane.store_error".to_string(),
                    1.0,
                    [("kit".to_string(), "CorpusKit".to_string())]
                        .into_iter().collect(),
                    {
                        use std::time::{SystemTime, UNIX_EPOCH};
                        SystemTime::now().duration_since(UNIX_EPOCH)
                            .map(|d| d.as_secs_f64()).unwrap_or(0.0)
                    },
                ));
                Some(err_str)
            } else {
                None
            }
        };

        let mut results: Vec<(String, FloatLaneOutcome)> = Vec::with_capacity(self.slots.len());
        for (_index, slot) in self.slots.iter().enumerate() {
            // Slot 0 honours the forced-error seam if installed; all other slots —
            // and slot 0 when no seam is set — run the real lane.
            #[cfg(any(test, feature = "test-seams"))]
            if _index == 0 {
                if let Some(ref err_str) = forced_default_store_error {
                    results.push((slot.model_id.clone(),
                                  FloatLaneOutcome::StoreError(err_str.clone())));
                    continue;
                }
            }
            let outcome = self.float_nearest_for_slot(slot, query, limit, SearchDirection::Nearest);
            results.push((slot.model_id.clone(), outcome));
        }
        results
    }

    /// Per-signal dense float FARTHEST recall — the anti-similarity sibling of
    /// `float_nearest_per_signal` (mission 6b-modifiers-antisim). Mirrors Swift
    /// `Corpus.floatFarthestPerSignal`.
    ///
    /// Runs the dense float lane in the FARTHEST direction independently for
    /// EVERY held provider slot: each signal surfaces the most DISSIMILAR
    /// sources for its model_id ("find things UNLIKE this"), ranked least-similar
    /// first. The outcome shape, dark-lane observability, telemetry counters, and
    /// slot ordering are identical to `float_nearest_per_signal`; only the
    /// ranking objective differs (the store returns farthest chunks, and a
    /// source's score is its WORST chunk cosine — see `float_nearest_for_slot`).
    ///
    /// This is the seam GLK's RecallShape `anti_similar_lanes` consumes. The
    /// forced-error test hook is NOT consulted here (it is nearest-path
    /// infrastructure), so the farthest path always runs the real lane.
    ///
    /// An empty query or zero limit returns one `EmptyQuery` outcome per signal
    /// (no store access), mirroring the nearest no-op guard.
    pub fn float_farthest_per_signal(
        &self,
        query: &str,
        limit: usize,
    ) -> Vec<(String, FloatLaneOutcome)> {
        if limit == 0 || query.is_empty() {
            return self
                .slots
                .iter()
                .map(|s| (s.model_id.clone(), FloatLaneOutcome::EmptyQuery))
                .collect();
        }

        let mut results: Vec<(String, FloatLaneOutcome)> = Vec::with_capacity(self.slots.len());
        for slot in self.slots.iter() {
            let outcome = self.float_nearest_for_slot(slot, query, limit, SearchDirection::Farthest);
            results.push((slot.model_id.clone(), outcome));
        }
        results
    }

    /// Per-signal dense float nearest recall WITH per-query discrimination signal.
    ///
    /// Mirrors Swift `Corpus.floatNearestPerSignalWithDiscrimination`. Same semantics
    /// and return shape as `float_nearest_per_signal`, but each entry carries an
    /// optional `FloatDiscriminationSignal` alongside the outcome. Discrimination is
    /// `Some` exactly when the outcome is `Hits` with at least one result.
    ///
    /// **Measurement only:** no behaviour change inside `Corpus`.
    /// The coordinator (GLK) consumes the signal to discount the dense contribution
    /// when the lane self-reports degeneracy. Standalone consumers may use the signal
    /// for their own fusion decisions.
    ///
    /// See `FloatDiscriminationSignal` for the statistic definition.
    pub fn float_nearest_per_signal_with_discrimination(
        &self,
        query: &str,
        limit: usize,
    ) -> Vec<(String, FloatLaneOutcome, Option<FloatDiscriminationSignal>)> {
        // Delegate to the existing per-signal call, then compute discrimination from
        // each `Hits` outcome's already-sorted similarity list. The existing function
        // handles the forced-error seam and all dark-lane paths.
        self.float_nearest_per_signal(query, limit)
            .into_iter()
            .map(|(model_id, outcome)| {
                let disc = discrimination_signal_from_outcome(&outcome);
                (model_id, outcome, disc)
            })
            .collect()
    }
}
