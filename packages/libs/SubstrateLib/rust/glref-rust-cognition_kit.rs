// cognition_kit.rs
//
// Eighteen retrieval primitives per cookbook § 11. Mirror of
// glref-swift-CognitionKit.swift.
//
// Five classes (paper § 10.2):
//   A direct retrieval: by_id, by_fingerprint, by_lattice,
//                       by_predicate, recent, as_of
//   B similarity:       about, similar_moments,
//                       similar_moments_by_summary, partial_match,
//                       by_latent_factor, loading_on_factor
//   C graph-derived:    keystone, community (v0.37),
//                       exploratory (v0.37)
//   D federation-aware: federated, about_peer
//   E audit/explain:    explain
//
// Composition rules: no hidden state, every output is an
// exposable RecallResult, composition is associative.

use std::collections::{HashMap, HashSet};
use crate::hlc::HLC;
use crate::fingerprint256::Fingerprint256;
use crate::tier_query::RecallScoreLite as RecallScore;

#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct DistanceBreakdown {
    pub lattice: f32,
    pub fingerprint: f32,
    pub temporal: f32,
    pub bitmap: f32,
}

#[derive(Debug, Clone)]
pub struct RecallResult {
    pub rows: Vec<RecallScore>,
    pub breakdown: DistanceBreakdown,
    pub confidence_interval: Option<(f32, f32)>,
    pub primitive_name: String,
}

#[derive(Debug, Clone)]
pub struct RowProjection {
    pub row_id: u128,
    pub capture_hlc: HLC,
    pub fingerprint: Fingerprint256,
    pub lattice_udc: String,
    pub bitmaps: (u64, u64, u64),    // adjective, operational, provenance
    pub row_state: u8,
}

pub struct CompositeWeights {
    pub lattice: f32,
    pub fingerprint: f32,
    pub temporal: f32,
    pub bitmap: f32,
}

pub struct BitmapPredicate {
    pub adjective_mask: u64,
    pub adjective_value: u64,
    pub operational_mask: u64,
    pub operational_value: u64,
    pub provenance_mask: u64,
    pub provenance_value: u64,
}

pub struct CognitionKit;

impl CognitionKit {
    // -----------------------------------------------------------
    // CLASS A: Direct retrieval
    // -----------------------------------------------------------

    /// 1. recall_by_id — single row lookup, score 1.0 if found.
    pub fn recall_by_id(row_id: u128, store: &[RowProjection]) -> RecallResult {
        if let Some(row) = store.iter().find(|r| r.row_id == row_id) {
            return RecallResult {
                rows: vec![RecallScore { row_id: row.row_id, score: 1.0 }],
                breakdown: DistanceBreakdown::default(),
                confidence_interval: None,
                primitive_name: "recall_by_id".to_string(),
            };
        }
        RecallResult {
            rows: vec![],
            breakdown: DistanceBreakdown::default(),
            confidence_interval: None,
            primitive_name: "recall_by_id".to_string(),
        }
    }

    /// 2. recall_by_fingerprint — Hamming-NN top-k.
    pub fn recall_by_fingerprint(probe: &Fingerprint256,
                                 k: usize,
                                 store: &[RowProjection]) -> RecallResult {
        let mut scored: Vec<RecallScore> = store.iter()
            .map(|r| {
                let d = hamming256(probe, &r.fingerprint);
                RecallScore { row_id: r.row_id, score: 1.0 - d as f32 / 256.0 }
            })
            .collect();
        scored.sort_by(|a, b| {
            b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal)
                .then(a.row_id.cmp(&b.row_id))
        });
        scored.truncate(k);
        RecallResult {
            rows: scored,
            breakdown: DistanceBreakdown { fingerprint: 1.0, ..Default::default() },
            confidence_interval: None,
            primitive_name: "recall_by_fingerprint".to_string(),
        }
    }

    /// 3. recall_by_lattice — rows under a lattice anchor.
    pub fn recall_by_lattice(anchor: &str,
                             include_subtree: bool,
                             store: &[RowProjection]) -> RecallResult {
        let hits: Vec<RecallScore> = store.iter()
            .filter(|r| if include_subtree {
                r.lattice_udc.starts_with(anchor)
            } else {
                r.lattice_udc == anchor
            })
            .map(|r| RecallScore { row_id: r.row_id, score: 1.0 })
            .collect();
        RecallResult {
            rows: hits,
            breakdown: DistanceBreakdown { lattice: 1.0, ..Default::default() },
            confidence_interval: None,
            primitive_name: "recall_by_lattice".to_string(),
        }
    }

    /// 4. recall_by_predicate — bitmap-pattern match.
    pub fn recall_by_predicate(pred: &BitmapPredicate,
                               store: &[RowProjection]) -> RecallResult {
        let hits: Vec<RecallScore> = store.iter()
            .filter(|r| {
                (r.bitmaps.0 & pred.adjective_mask) == pred.adjective_value
                && (r.bitmaps.1 & pred.operational_mask) == pred.operational_value
                && (r.bitmaps.2 & pred.provenance_mask) == pred.provenance_value
            })
            .map(|r| RecallScore { row_id: r.row_id, score: 1.0 })
            .collect();
        RecallResult {
            rows: hits,
            breakdown: DistanceBreakdown { bitmap: 1.0, ..Default::default() },
            confidence_interval: None,
            primitive_name: "recall_by_predicate".to_string(),
        }
    }

    /// 5. recall_recent — rows captured in HLC window.
    pub fn recall_recent(start: HLC, end: HLC, store: &[RowProjection]) -> RecallResult {
        let mut hits: Vec<&RowProjection> = store.iter()
            .filter(|r| r.capture_hlc >= start && r.capture_hlc <= end)
            .collect();
        hits.sort_by(|a, b| b.capture_hlc.cmp(&a.capture_hlc));
        let rows = hits.into_iter()
            .map(|r| RecallScore { row_id: r.row_id, score: 1.0 })
            .collect();
        RecallResult {
            rows,
            breakdown: DistanceBreakdown { temporal: 1.0, ..Default::default() },
            confidence_interval: None,
            primitive_name: "recall_recent".to_string(),
        }
    }

    /// 6. recall_as_of — substrate state at hlc. Wrapper over
    /// AuditLogFold; expects caller to supply already-projected rows.
    pub fn recall_as_of(_hlc: HLC, active_rows: &[u128]) -> RecallResult {
        let rows = active_rows.iter()
            .map(|&row_id| RecallScore { row_id, score: 1.0 })
            .collect();
        RecallResult {
            rows,
            breakdown: DistanceBreakdown::default(),
            confidence_interval: None,
            primitive_name: "recall_as_of".to_string(),
        }
    }

    // -----------------------------------------------------------
    // CLASS B: Similarity composition
    // -----------------------------------------------------------

    /// 7. recall_about — composite distance top-k.
    pub fn recall_about(probe: &RowProjection,
                        weights: &CompositeWeights,
                        k: usize,
                        store: &[RowProjection]) -> RecallResult {
        let mut scored: Vec<(RecallScore, f32, f32)> = store.iter()
            .map(|r| {
                let lat = lattice_distance(&probe.lattice_udc, &r.lattice_udc);
                let fp = hamming256(&probe.fingerprint, &r.fingerprint) as f32 / 256.0;
                let composite = weights.lattice * lat + weights.fingerprint * fp;
                (RecallScore { row_id: r.row_id, score: 1.0 - composite }, lat, fp)
            })
            .collect();
        scored.sort_by(|a, b| {
            b.0.score.partial_cmp(&a.0.score).unwrap_or(std::cmp::Ordering::Equal)
                .then(a.0.row_id.cmp(&b.0.row_id))
        });
        scored.truncate(k);
        let n = scored.len().max(1) as f32;
        let avg_lat: f32 = scored.iter().map(|(_, l, _)| *l).sum::<f32>() / n;
        let avg_fp: f32 = scored.iter().map(|(_, _, f)| *f).sum::<f32>() / n;
        RecallResult {
            rows: scored.into_iter().map(|(s, _, _)| s).collect(),
            breakdown: DistanceBreakdown {
                lattice: avg_lat, fingerprint: avg_fp,
                temporal: 0.0, bitmap: 0.0,
            },
            confidence_interval: None,
            primitive_name: "recall_about".to_string(),
        }
    }

    /// 8. recall_similar_moments — fingerprint similarity over
    /// moment-summary fingerprints.
    pub fn recall_similar_moments(probe: &Fingerprint256,
                                  moment_fps: &[(u128, Fingerprint256)],
                                  k: usize) -> RecallResult {
        let mut scored: Vec<RecallScore> = moment_fps.iter()
            .map(|(rid, fp)| {
                let d = hamming256(probe, fp);
                RecallScore { row_id: *rid, score: 1.0 - d as f32 / 256.0 }
            })
            .collect();
        scored.sort_by(|a, b| {
            b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal)
                .then(a.row_id.cmp(&b.row_id))
        });
        scored.truncate(k);
        RecallResult {
            rows: scored,
            breakdown: DistanceBreakdown { fingerprint: 1.0, ..Default::default() },
            confidence_interval: None,
            primitive_name: "recall_similar_moments".to_string(),
        }
    }

    /// 9. recall_similar_moments_by_summary — same shape, indexed
    /// over precomputed window summaries from TemporalCompression.
    pub fn recall_similar_moments_by_summary(probe: &Fingerprint256,
                                             window_summaries: &[(u128, Fingerprint256)],
                                             k: usize) -> RecallResult {
        let r = Self::recall_similar_moments(probe, window_summaries, k);
        RecallResult { primitive_name: "recall_similar_moments_by_summary".to_string(), ..r }
    }

    /// 10. recall_partial_match — match-blocks similar, differ-blocks
    /// dissimilar.
    pub fn recall_partial_match(probe: &Fingerprint256,
                                match_blocks: &HashSet<usize>,
                                differ_blocks: &HashSet<usize>,
                                k: usize,
                                store: &[RowProjection]) -> RecallResult {
        let mut scored: Vec<RecallScore> = store.iter()
            .map(|r| {
                let mut score = 0.0_f32;
                for b in match_blocks {
                    let dist = block_hamming(probe, &r.fingerprint, *b);
                    score += 1.0 - dist as f32 / 64.0;
                }
                for b in differ_blocks {
                    let dist = block_hamming(probe, &r.fingerprint, *b);
                    score += dist as f32 / 64.0;
                }
                let denom = (match_blocks.len() + differ_blocks.len()).max(1) as f32;
                RecallScore { row_id: r.row_id, score: score / denom }
            })
            .collect();
        scored.sort_by(|a, b| {
            b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal)
                .then(a.row_id.cmp(&b.row_id))
        });
        scored.truncate(k);
        RecallResult {
            rows: scored,
            breakdown: DistanceBreakdown { fingerprint: 1.0, ..Default::default() },
            confidence_interval: None,
            primitive_name: "recall_partial_match".to_string(),
        }
    }

    /// 11. recall_by_latent_factor — rows above threshold on factor.
    pub fn recall_by_latent_factor(w: &[Vec<f32>],
                                   factor_idx: usize,
                                   threshold: f32,
                                   row_ids: &[u128]) -> RecallResult {
        assert_eq!(w.len(), row_ids.len(), "W rows match row_ids");
        let mut hits: Vec<RecallScore> = (0..w.len())
            .filter(|i| w[*i][factor_idx] >= threshold)
            .map(|i| RecallScore { row_id: row_ids[i], score: w[i][factor_idx] })
            .collect();
        hits.sort_by(|a, b| {
            b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal)
                .then(a.row_id.cmp(&b.row_id))
        });
        RecallResult {
            rows: hits,
            breakdown: DistanceBreakdown::default(),
            confidence_interval: None,
            primitive_name: "recall_by_latent_factor".to_string(),
        }
    }

    /// 12. recall_loading_on_factor — top-k by factor loading.
    pub fn recall_loading_on_factor(w: &[Vec<f32>],
                                    factor_idx: usize,
                                    k: usize,
                                    row_ids: &[u128]) -> RecallResult {
        assert_eq!(w.len(), row_ids.len(), "W rows match row_ids");
        let mut scored: Vec<RecallScore> = (0..w.len())
            .map(|i| RecallScore { row_id: row_ids[i], score: w[i][factor_idx] })
            .collect();
        scored.sort_by(|a, b| {
            b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal)
                .then(a.row_id.cmp(&b.row_id))
        });
        scored.truncate(k);
        RecallResult {
            rows: scored,
            breakdown: DistanceBreakdown::default(),
            confidence_interval: None,
            primitive_name: "recall_loading_on_factor".to_string(),
        }
    }

    // -----------------------------------------------------------
    // CLASS C: Graph-derived retrieval
    // -----------------------------------------------------------

    /// 13. recall_keystone — top-k by eigenvalue centrality.
    pub fn recall_keystone(centrality: &HashMap<u128, f32>, k: usize) -> RecallResult {
        let mut scored: Vec<RecallScore> = centrality.iter()
            .map(|(rid, c)| RecallScore { row_id: *rid, score: *c })
            .collect();
        scored.sort_by(|a, b| {
            b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal)
                .then(a.row_id.cmp(&b.row_id))
        });
        scored.truncate(k);
        RecallResult {
            rows: scored,
            breakdown: DistanceBreakdown::default(),
            confidence_interval: None,
            primitive_name: "recall_keystone".to_string(),
        }
    }

    /// 14. recall_community — DEFERRED to v0.37 (Louvain phase 2).
    pub fn recall_community(probe: u128,
                            community_labels: &HashMap<u128, i32>) -> RecallResult {
        let probe_label = match community_labels.get(&probe) {
            Some(l) => *l,
            None => return RecallResult {
                rows: vec![],
                breakdown: DistanceBreakdown::default(),
                confidence_interval: None,
                primitive_name: "recall_community".to_string(),
            },
        };
        let mut hits: Vec<RecallScore> = community_labels.iter()
            .filter(|(rid, lbl)| **lbl == probe_label && **rid != probe)
            .map(|(rid, _)| RecallScore { row_id: *rid, score: 1.0 })
            .collect();
        hits.sort_by(|a, b| a.row_id.cmp(&b.row_id));
        RecallResult {
            rows: hits,
            breakdown: DistanceBreakdown::default(),
            confidence_interval: None,
            primitive_name: "recall_community".to_string(),
        }
    }

    /// 15. recall_exploratory — DEFERRED to v0.37. Random walk
    /// with restart aggregate.
    pub fn recall_exploratory(visits: &HashMap<u128, u32>) -> RecallResult {
        let total: u32 = visits.values().sum();
        let mut scored: Vec<RecallScore> = visits.iter()
            .map(|(rid, count)| {
                let prob = if total > 0 { *count as f32 / total as f32 } else { 0.0 };
                RecallScore { row_id: *rid, score: prob }
            })
            .collect();
        scored.sort_by(|a, b| {
            b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal)
                .then(a.row_id.cmp(&b.row_id))
        });
        RecallResult {
            rows: scored,
            breakdown: DistanceBreakdown::default(),
            confidence_interval: None,
            primitive_name: "recall_exploratory".to_string(),
        }
    }

    // -----------------------------------------------------------
    // CLASS D: Federation-aware retrieval
    // -----------------------------------------------------------

    /// 16. recall_federated — combine local exact + noisy peer.
    pub fn recall_federated(local_result: &RecallResult,
                            peer_results: &[RecallResult],
                            privacy_epsilon: f32) -> RecallResult {
        let mut combined: HashMap<u128, f32> = HashMap::new();
        for s in &local_result.rows {
            *combined.entry(s.row_id).or_insert(0.0) += s.score;
        }
        for peer in peer_results {
            for s in &peer.rows {
                *combined.entry(s.row_id).or_insert(0.0) += s.score;
            }
        }
        let mut merged: Vec<RecallScore> = combined.into_iter()
            .map(|(row_id, score)| RecallScore { row_id, score })
            .collect();
        merged.sort_by(|a, b| {
            b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal)
                .then(a.row_id.cmp(&b.row_id))
        });
        let scale = 1.0 / privacy_epsilon;
        RecallResult {
            rows: merged,
            breakdown: local_result.breakdown,
            confidence_interval: Some((-1.96 * scale, 1.96 * scale)),
            primitive_name: "recall_federated".to_string(),
        }
    }

    /// 17. recall_about_peer — recall_about across paired peer's
    /// shareable rows under shared family.
    pub fn recall_about_peer(probe: &RowProjection,
                             peer_store: &[RowProjection],
                             weights: &CompositeWeights,
                             k: usize) -> RecallResult {
        let r = Self::recall_about(probe, weights, k, peer_store);
        RecallResult { primitive_name: "recall_about_peer".to_string(), ..r }
    }

    // -----------------------------------------------------------
    // CLASS E: Audit and explanation
    // -----------------------------------------------------------

    /// 18. explain_recall — expose intermediate state behind a
    /// prior recall result. I-13 forbids hiding state from cognition.
    pub fn explain_recall(prior: &RecallResult,
                          candidates: Vec<RecallScore>,
                          applied_weights: Option<CompositeWeights>) -> Explanation {
        Explanation {
            primitive: prior.primitive_name.clone(),
            candidates,
            breakdown: prior.breakdown,
            applied_weights,
            confidence_interval: prior.confidence_interval,
        }
    }
}

pub struct Explanation {
    pub primitive: String,
    pub candidates: Vec<RecallScore>,
    pub breakdown: DistanceBreakdown,
    pub applied_weights: Option<CompositeWeights>,
    pub confidence_interval: Option<(f32, f32)>,
}

// MARK: - Helpers

fn hamming256(a: &Fingerprint256, b: &Fingerprint256) -> u32 {
    (a.block0 ^ b.block0).count_ones()
        + (a.block1 ^ b.block1).count_ones()
        + (a.block2 ^ b.block2).count_ones()
        + (a.block3 ^ b.block3).count_ones()
}

fn block_hamming(a: &Fingerprint256, b: &Fingerprint256, block: usize) -> u32 {
    let xor = match block {
        0 => a.block0 ^ b.block0,
        1 => a.block1 ^ b.block1,
        2 => a.block2 ^ b.block2,
        _ => a.block3 ^ b.block3,
    };
    xor.count_ones()
}

/// Lattice distance via shared-prefix length. UDC codes share the
/// hierarchy under common prefixes (e.g., "613.71" and "613.81"
/// share "613" prefix). Returns 0.0 for identical, 1.0 for no
/// shared prefix.
fn lattice_distance(a: &str, b: &str) -> f32 {
    if a == b { return 0.0; }
    let prefix_len = a.chars().zip(b.chars()).take_while(|(x, y)| x == y).count();
    let max_len = a.len().max(b.len()).max(1);
    1.0 - (prefix_len as f32 / max_len as f32)
}
