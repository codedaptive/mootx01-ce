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

use corpus_kit::corpus::Corpus;
use vectorkit::VectorStore;

use crate::brain::scheduler::api::*;

pub struct VectorSimilaritySignal;

impl VectorSimilaritySignal {
    /// Default cadence in seconds (300 = 5 minutes). Cookbook §15.2.
    pub const DEFAULT_CADENCE_SECONDS: u64 = 300;

    /// Stable name surfaced in `SignalReport.name`.
    pub const SIGNAL_NAME: &'static str = "vector-similarity";

    /// Maximum Hamming distance (0-256) for a proximity candidate.
    /// 64 = 25% of 256 bits. Mirrors Swift's defaultProximityThreshold.
    pub const DEFAULT_PROXIMITY_THRESHOLD: i32 = 64;

    /// Maximum drawer IDs sampled per pass. Bounds the scan to O(N·K)
    /// comparisons per fire. Mirrors Swift's maxProbeCount.
    const MAX_PROBE_COUNT: usize = 50;

    /// Neighbours requested per probe via find_nearest. Mirrors Swift's
    /// neighboursPerProbe.
    const NEIGHBOURS_PER_PROBE: usize = 5;

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
    /// - `corpus`: the estate's `Corpus`, when one is registered. Enables
    ///   the chunk-keyed corpus lane — the row population production
    ///   estates actually hold. `None` scans only the drawer-keyed lane,
    ///   which is correct for tests that plant drawer-keyed vectors.
    pub fn spec(
        vector_store: Arc<VectorStore>,
        model_id: String,
        proximity_threshold: i32,
        corpus: Option<Arc<Corpus>>,
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
                    corpus.as_deref(),
                    context,
                )
            }),
        }
    }

    /// Execute one proximity scan pass.
    ///
    /// Samples the MAX_PROBE_COUNT most recently filed item IDs via
    /// recent_item_ids, retrieves each row's engram, calls find_nearest to
    /// locate nearby rows, deduplicates pairs, and emits AssociateFrames.
    fn proximity_pass(
        vector_store: &VectorStore,
        model_id: &str,
        proximity_threshold: i32,
        corpus: Option<&Corpus>,
        context: &SignalContext,
    ) -> Vec<SignalEmission> {
        let mut emissions = Vec::new();

        // Newest-first probe sample: the MAX_PROBE_COUNT most recently
        // filed items. New captures are what need association screening;
        // the prior ascending-item_id enumeration was a static UUID-ordered
        // window that new content rarely entered on a large estate.
        let drawer_ids = match vector_store.recent_item_ids(Self::MAX_PROBE_COUNT) {
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

        let mut candidate_pairs: Vec<(String, String, f64)> = Vec::new();
        // Canonical pair key: lexicographically smaller ID first so
        // (A,B) and (B,A) map to the same set element. Both lanes below
        // key on DRAWER ids, so they dedupe together.
        let mut seen_pairs: HashSet<String> = HashSet::new();

        // Lane 1 — drawer-keyed rows under the caller's `model_id`. Rows
        // whose item is not in this lane fail `get_vector` and fall through.
        for drawer_id in &drawer_ids {
            let probe_engram = match vector_store.get_vector(drawer_id, model_id) {
                Ok(Some(e)) => e,
                _ => continue,
            };

            let matches = match vector_store.find_nearest(
                &probe_engram,
                model_id,
                Self::NEIGHBOURS_PER_PROBE,
            ) {
                Ok(m) => m,
                Err(_) => continue,
            };

            for m in matches {
                if m.item_id == *drawer_id {
                    continue; // skip self-match
                }
                if m.distance > proximity_threshold {
                    continue;
                }
                // Lane F rename: VectorMatch.drawer_id → item_id (arch spec §4.1).
                let (a, b) = if drawer_id.as_str() < m.item_id.as_str() {
                    (drawer_id.clone(), m.item_id.clone())
                } else {
                    (m.item_id.clone(), drawer_id.clone())
                };
                let pair_key = format!("{}||{}", a, b);
                if seen_pairs.insert(pair_key) {
                    // Weight: 1.0 - distance/256. Identical vectors → 1.0.
                    // ADMIN — entrance gate: weight is derived FREE from the
                    // already-computed proximity-gate distance (no extra origin
                    // work). It is carried on the AssociationFrame but is
                    // VESTIGIAL past the `associate` verb, which has no weight
                    // column to persist it into (see verbs.rs `associate`, the
                    // drop site). Retained on purpose for a pre-2.0 gauntlet
                    // experiment on whether weight improves recall. Mirrors
                    // Swift `VectorSimilaritySignal`.
                    let weight = 1.0 - (m.distance as f64 / 256.0);
                    candidate_pairs.push((a, b, weight));
                }
            }
        }

        // Lane 2 — chunk-keyed corpus rows. On a production estate this is
        // the ONLY populated lane: the encode drain keys every vector row by
        // chunk UUID under the corpus provider's model_id, so lane 1 finds
        // nothing there. Mine the same probe sample on the corpus lane and
        // map chunk hits back to their owning drawers (chunk → source_id via
        // the corpus's warm map). Chunk pairs from the SAME drawer collapse.
        // First hit wins per drawer pair — find_nearest returns matches in
        // ascending distance, so the first hit for a pair is its closest
        // chunk evidence. Mirrors the contradiction hunter's lane split and
        // the Swift lane-2 block in `VectorSimilaritySignal.swift`.
        if let Some(corpus) = corpus {
            let corpus_model_id = corpus.model_id().to_string();
            let mut chunk_matches: Vec<(String, String, f64)> = Vec::new();
            let mut involved_chunk_ids: HashSet<uuid::Uuid> = HashSet::new();
            for item_id in &drawer_ids {
                let probe_uuid = match uuid::Uuid::parse_str(item_id) {
                    Ok(u) => u,
                    Err(_) => continue,
                };
                let probe_engram = match vector_store.get_vector(item_id, &corpus_model_id) {
                    Ok(Some(e)) => e,
                    _ => continue,
                };
                let matches = match vector_store.find_nearest(
                    &probe_engram,
                    &corpus_model_id,
                    Self::NEIGHBOURS_PER_PROBE,
                ) {
                    Ok(m) => m,
                    Err(_) => continue,
                };
                for m in matches {
                    if m.item_id == *item_id || m.distance > proximity_threshold {
                        continue;
                    }
                    let match_uuid = match uuid::Uuid::parse_str(&m.item_id) {
                        Ok(u) => u,
                        Err(_) => continue,
                    };
                    involved_chunk_ids.insert(probe_uuid);
                    involved_chunk_ids.insert(match_uuid);
                    chunk_matches.push((
                        item_id.clone(),
                        m.item_id.clone(),
                        1.0 - (m.distance as f64 / 256.0),
                    ));
                }
            }
            if !chunk_matches.is_empty() {
                let ids: Vec<uuid::Uuid> = involved_chunk_ids.into_iter().collect();
                let owners = corpus.source_ids_for_chunks(&ids);
                for (chunk_a, chunk_b, weight) in chunk_matches {
                    let (ua, ub) = match (
                        uuid::Uuid::parse_str(&chunk_a),
                        uuid::Uuid::parse_str(&chunk_b),
                    ) {
                        (Ok(a), Ok(b)) => (a, b),
                        _ => continue,
                    };
                    let (source_a, source_b) = match (owners.get(&ua), owners.get(&ub)) {
                        (Some(a), Some(b)) if a != b => (a.clone(), b.clone()),
                        _ => continue,
                    };
                    let (a, b) = if source_a < source_b {
                        (source_a, source_b)
                    } else {
                        (source_b, source_a)
                    };
                    let pair_key = format!("{}||{}", a, b);
                    if seen_pairs.insert(pair_key) {
                        candidate_pairs.push((a, b, weight));
                    }
                }
            }
        }

        for (a, b, weight) in &candidate_pairs {
            emissions.push(SignalEmission::Associate(AssociationFrame {
                a: a.clone(),
                b: b.clone(),
                weight: *weight,
            }));
        }

        emissions.push(SignalEmission::Diagnostic(DiagnosticReport {
            title: "vector_similarity.scan.summary".into(),
            detail: format!(
                "5-minute proximity pass found {} candidate pair(s); signal={}",
                candidate_pairs.len(),
                context.signal_id.0
            ),
            observed_at_nanos: context.now_nanos,
        }));

        emissions
    }
}
