// brain/signals/vector_similarity.rs — Rust mirror of
// `VectorSimilaritySignal.swift`.
//
// Architecture spec §11.2 row 6. Scans the estate's VectorStore on each
// five-minute fire, finds row pairs whose Hamming distance fell below the
// proximity threshold, and emits one `Associate` proposal per candidate
// pair plus a scan-summary diagnostic.
//
// TWO row populations are mined (same lane split as the contradiction
// hunter): drawer-keyed rows under the caller's `model_id`, and — when a
// Corpus is supplied — chunk-keyed rows under the corpus's own model_id,
// the ONLY lane production estates populate (the estate lifecycle
// registers the corpus's shared vector store; the encode drain keys every
// row by chunk UUID). Chunk hits map back to owning drawers via
// `Corpus::source_ids_for_chunks`, so every emitted AssociationFrame
// carries DRAWER ids.

use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use corpus_kit::CorpusContentEngine;
use vectorkit::VectorStore;

use crate::brain::scheduler::api::*;

/// Optional pre-emission check: returns `true` if an active association
/// edge already exists between the two drawer IDs (either direction).
/// When `Some`, pairs that return `true` are suppressed before frames are
/// emitted — prevents VectorSimilaritySignal from churning redundant
/// `Associate` frames every 300 seconds on an unchanged neighbourhood.
/// Fail-open: returning `false` (e.g. on error) is safe because the
/// DB-level uniqueness constraint (LocusKit v10) still blocks duplicate
/// persistence. Mirrors Swift `AssociationEdgeChecker`.
pub type AssociationEdgeChecker = Arc<dyn Fn(&str, &str) -> bool + Send + Sync>;

pub struct VectorSimilaritySignal;

impl VectorSimilaritySignal {
    /// Default cadence in seconds (300 = 5 minutes). Cookbook §15.2.
    pub const DEFAULT_CADENCE_SECONDS: u64 = 300;

    /// Stable name surfaced in `SignalReport.name`.
    pub const SIGNAL_NAME: &'static str = "vector-similarity";

    /// Maximum Hamming distance (0-256) for a proximity candidate.
    /// 64 = 25% of 256 bits. Mirrors Swift's defaultProximityThreshold.
    pub const DEFAULT_PROXIMITY_THRESHOLD: i32 = 64;

    /// Default number of item IDs sampled per pass from the VectorStore.
    /// Bounds the scan to O(N·K) comparisons per fire: 50 probes ×
    /// 5 neighbours = 250 distance comparisons. Callers that need a
    /// wider or narrower window pass an explicit `probe_limit` to
    /// `spec(...)`. Mirrors Swift's `defaultProbeLimit`.
    pub const DEFAULT_PROBE_LIMIT: usize = 50;

    /// Neighbours requested per probe via find_nearest. Shared constant
    /// used by `proximity_scan_candidates` and `associate_sweep`. Mirrors
    /// Swift's `ProximityScanCore.neighboursPerProbe`.
    pub(crate) const NEIGHBOURS_PER_PROBE: usize = 5;

    /// Build the production VectorSimilaritySignal spec.
    ///
    /// The VectorStore is captured by the emit closure (via `Arc`) and
    /// queried via `recent_item_ids` + `get_vector` + `find_nearest` on
    /// each five-minute pass. An empty store produces zero candidate pairs
    /// and emits only a scan-summary diagnostic.
    ///
    /// - `vector_store`: the estate's `VectorStore`, wrapped in `Arc` so
    ///   the closure can hold it across the scheduler's lifetime.
    /// - `model_id`: the embedding model whose stored vectors are scanned
    ///   on the drawer-keyed lane.
    /// - `proximity_threshold`: max Hamming distance (0-256) for a pair to
    ///   qualify as an association candidate. Default 64.
    /// - `probe_limit`: maximum number of item IDs sampled from the
    ///   VectorStore on each pass via `recent_item_ids`. Use
    ///   `DEFAULT_PROBE_LIMIT` (50) to keep resident behavior unchanged.
    ///   Widen for callers that need a broader recency window — the dream
    ///   associate step and benchmark protocol v2 are the expected
    ///   non-default users. The probe window is one-sided: probes are
    ///   recency-sampled (newest first), while neighbors search the whole
    ///   estate; two dormant old items never pair unless one was probed
    ///   while recent — this is the limitation widening `probe_limit`
    ///   relieves. Mirrors Swift's `probeLimit` parameter on `spec(...)`.
    /// - `corpus`: the estate's `Corpus`, when one is registered. Enables
    ///   the chunk-keyed corpus lane — the row population production
    ///   estates actually hold. `None` scans only the drawer-keyed lane,
    ///   which is correct for tests that plant drawer-keyed vectors.
    /// - `edge_checker`: optional pre-emission filter. When `Some`, each
    ///   candidate pair is tested with `checker(a, b)` before an
    ///   `Associate` frame is emitted; pairs that already have a persisted
    ///   active edge are suppressed. Fail-open: a checker that returns
    ///   `false` on error is safe because the DB-level uniqueness
    ///   constraint (LocusKit v10, FINDING-3) still blocks duplicate
    ///   persistence. `None` is the default — the uniqueness constraint
    ///   alone is sufficient correctness; the checker is an optimization
    ///   that avoids churning frames when the neighbourhood is stable.
    pub fn spec(
        vector_store: Arc<VectorStore>,
        model_id: String,
        proximity_threshold: i32,
        probe_limit: usize,
        corpus: Option<Arc<CorpusContentEngine>>,
        edge_checker: Option<AssociationEdgeChecker>,
    ) -> SignalSpec {
        SignalSpec {
            name: Self::SIGNAL_NAME.to_string(),
            trigger: SignalTrigger::Interval {
                seconds: Duration::from_secs(Self::DEFAULT_CADENCE_SECONDS),
            },
            resource_cost: ResourceCostEstimate::ZERO,
            freshness_target: Duration::from_secs(Self::DEFAULT_CADENCE_SECONDS * 2),
            concurrency_policy: ConcurrencyPolicy::Single,
            emit: Arc::new(move |context: &SignalContext| {
                Self::proximity_pass(
                    &vector_store,
                    &model_id,
                    proximity_threshold,
                    probe_limit,
                    corpus.as_deref(),
                    edge_checker.as_deref(),
                    context,
                )
            }),
        }
    }

    /// Execute one proximity scan pass.
    ///
    /// The two-lane kNN scan is delegated to `proximity_scan_candidates`
    /// (shared with `EstateCoordinator::associate_sweep`) so the scan logic
    /// lives in exactly one place.
    ///
    /// If `edge_checker` is provided, pairs with a persisted active edge
    /// are filtered out before emission (FINDING-3 optimization).
    fn proximity_pass(
        vector_store: &VectorStore,
        model_id: &str,
        proximity_threshold: i32,
        probe_limit: usize,
        corpus: Option<&CorpusContentEngine>,
        edge_checker: Option<&(dyn Fn(&str, &str) -> bool + Send + Sync)>,
        context: &SignalContext,
    ) -> Vec<SignalEmission> {
        let mut emissions = Vec::new();

        // Newest-first probe sample bounded by `probe_limit`. New captures
        // are what need association screening; the prior ascending-item_id
        // enumeration was a static UUID-ordered window that new content
        // rarely entered on a large estate. The probe window is one-sided:
        // neighbors search the whole estate, so two dormant old items never
        // pair unless one was probed while recent — widening `probe_limit`
        // is how callers relieve that constraint.
        let item_ids = match vector_store.recent_item_ids(probe_limit) {
            Ok(ids) => ids,
            Err(e) => {
                emissions.push(SignalEmission::Diagnostic(DiagnosticReport {
                    title: "vector_similarity.scan.summary".into(),
                    detail: format!(
                        "probe-source scan failed: {:?}; signal={}",
                        e, context.signal_id.0
                    ),
                    observed_at_nanos: context.now_nanos,
                }));
                return emissions;
            }
        };

        // Two-lane kNN scan via shared core (also used by associate_sweep verb).
        // proximity_scan_candidates applies within-pass symmetric pair dedup
        // and returns unique (a, b, weight) candidates.
        let candidate_pairs = proximity_scan_candidates(
            vector_store,
            &item_ids,
            model_id,
            proximity_threshold,
            corpus,
            Self::NEIGHBOURS_PER_PROBE,
        );

        // FINDING-3: filter pairs that already have a persisted active edge
        // so VectorSimilaritySignal does not churn redundant Associate frames
        // on every 300-second pass when the vector neighbourhood is stable.
        // Fail-open: if the checker returns false on error the DB-level
        // uniqueness constraint (LocusKit v10) still blocks duplicate persistence.
        let emittable_pairs: Vec<(String, String, f64)> = if let Some(check) = edge_checker {
            candidate_pairs
                .iter()
                .filter(|(a, b, _)| !check(a.as_str(), b.as_str()))
                .cloned()
                .collect()
        } else {
            candidate_pairs.clone()
        };

        for (a, b, weight) in &emittable_pairs {
            emissions.push(SignalEmission::Associate(AssociationFrame {
                a: a.clone(),
                b: b.clone(),
                weight: *weight,
            }));
        }

        emissions.push(SignalEmission::Diagnostic(DiagnosticReport {
            title: "vector_similarity.scan.summary".into(),
            detail: format!(
                "5-minute proximity pass found {} candidate pair(s), emitting {}; signal={}",
                candidate_pairs.len(),
                emittable_pairs.len(),
                context.signal_id.0
            ),
            observed_at_nanos: context.now_nanos,
        }));

        emissions
    }
}

// MARK: - Shared proximity scan core

/// Execute one two-lane kNN proximity scan over the given probe item IDs.
///
/// Shared core for `VectorSimilaritySignal::proximity_pass` (resident five-minute
/// cadence) and `EstateCoordinator::associate_sweep` (on-demand verb). One
/// implementation, two callers — mirrors the Swift `ProximityScanCore` pattern.
///
/// Returns candidate pairs `(a, b, weight)` with within-pass symmetric dedup
/// applied (`a < b` lexicographically). Does NOT filter against existing
/// associations — callers apply their own settled-set or edge-checker filter.
///
/// Two lanes are mined:
///   - Lane 1: drawer-keyed rows under the caller's `model_id`.
///   - Lane 2: drawer-keyed rows under the corpus provider's own model_id,
///     when a corpus is supplied. Shared-content 1.1 keys every row by
///     Drawer ID directly, so no chunk→drawer remap is needed.
///
/// Weight = 1.0 − (distance / 256). Identical vectors → 1.0.
///
/// ADMIN — weight is derived free from the already-computed proximity-gate
/// Hamming distance. It is carried on the AssociationFrame but VESTIGIAL
/// past the `associate` verb, which has no weight column to persist it into
/// (see coordinator.rs `associate`, the drop site). Retained for a pre-2.0
/// gauntlet experiment on whether weight improves recall. Mirrors Swift
/// `ProximityScanCore.candidates`.
pub(crate) fn proximity_scan_candidates(
    vector_store: &VectorStore,
    item_ids: &[String],
    model_id: &str,
    proximity_threshold: i32,
    corpus: Option<&CorpusContentEngine>,
    neighbours_per_probe: usize,
) -> Vec<(String, String, f64)> {
    let mut result: Vec<(String, String, f64)> = Vec::new();
    // Canonical pair key: lexicographically smaller ID first so (A,B) and
    // (B,A) map to the same set element. Both lanes key on DRAWER ids.
    let mut seen_pairs: HashSet<String> = HashSet::new();

    // Lane 1 — drawer-keyed rows under the caller's `model_id`. Rows whose
    // item is not in this lane fail `get_vector` and fall through silently.
    for item_id in item_ids {
        let probe_engram = match vector_store.get_vector(item_id, model_id) {
            Ok(Some(e)) => e,
            _ => continue,
        };

        let matches = match vector_store.find_nearest(&probe_engram, model_id, neighbours_per_probe) {
            Ok(m) => m,
            Err(_) => continue,
        };

        for m in matches {
            if m.item_id == *item_id {
                continue; // skip self-match
            }
            if m.distance > proximity_threshold {
                continue;
            }
            let (a, b) = if item_id.as_str() < m.item_id.as_str() {
                (item_id.clone(), m.item_id.clone())
            } else {
                (m.item_id.clone(), item_id.clone())
            };
            let pair_key = format!("{}||{}", a, b);
            if seen_pairs.insert(pair_key) {
                let weight = 1.0 - (m.distance as f64 / 256.0);
                result.push((a, b, weight));
            }
        }
    }

    // Lane 2 — the corpus provider's rows. Shared-content 1.1: the engine
    // keys every vector row by DRAWER ID, so a hit's item_id is the owning
    // drawer directly — no chunk→drawer remap. Mirrors the Swift Lane 2 block.
    if let Some(corpus) = corpus {
        let corpus_model_id = corpus.model_id();
        for item_id in item_ids {
            let probe_engram = match vector_store.get_vector(item_id, &corpus_model_id) {
                Ok(Some(e)) => e,
                _ => continue,
            };
            let matches = match vector_store.find_nearest(
                &probe_engram,
                &corpus_model_id,
                neighbours_per_probe,
            ) {
                Ok(m) => m,
                Err(_) => continue,
            };
            for m in matches {
                if m.item_id == *item_id || m.distance > proximity_threshold {
                    continue;
                }
                let (a, b) = if *item_id < m.item_id {
                    (item_id.clone(), m.item_id.clone())
                } else {
                    (m.item_id.clone(), item_id.clone())
                };
                let pair_key = format!("{}||{}", a, b);
                if seen_pairs.insert(pair_key) {
                    result.push((a, b, 1.0 - (m.distance as f64 / 256.0)));
                }
            }
        }
    }

    result
}
