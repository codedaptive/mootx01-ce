// tier_query.rs
//
// Tier-ascending query protocol per cookbook § 12.4. Mirror of
// glref-swift-TierAscendingQuery.swift.
//
// Five-step: local exact compute, sign with shared key, forward to
// peers/aggregator, peer applies DP, originator combines.
//
// RECALL-RESULT TYPES (Swift/Rust asymmetry — intentional). The Swift
// port keeps the full recall vocabulary (RecallScore, RecallResult,
// DistanceBreakdown, RowProjection) in
// substrate-types/RecallTypes.swift. This Rust port does not mirror that
// module; it materializes only the lean RecallScoreLite / RecallResultLite
// shapes the query path needs, here beside TierAscendingQuery.
// DistanceBreakdown and RowProjection have no Rust equivalent by design.
// Do not extract a recall_types module for parity — conformance covers
// the wire-gated path, not these convenience shapes.

use std::collections::HashMap;
use substrate_types::hlc::HLC;
use crate::dp_or_reduce::{DPParameters, DPORReduction};
use crate::random_walks::SplitMix64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TargetTier {
    Peer,
    FleetAggregate,
    IndustryAggregate,
}

#[derive(Debug, Clone)]
pub struct TierAscendingQuery {
    pub originating_estate: [u8; 16],
    pub primitive_name: String,
    pub primitive_input: Vec<u8>,
    pub target_tier: TargetTier,
    pub privacy_budget: DPParameters,
    pub query_hlc: HLC,
}

#[derive(Debug, Clone)]
pub struct RecallScoreLite {
    pub row_id: u128,
    pub score: f32,
}

#[derive(Debug, Clone)]
pub struct RecallResultLite {
    pub rows: Vec<RecallScoreLite>,
    pub confidence_interval: Option<(f32, f32)>,
    pub primitive_name: String,
}

#[derive(Debug, Clone)]
pub struct PeerResponse {
    pub peer_estate: [u8; 16],
    pub contribution: RecallResultLite,
    pub consumed_epsilon: f64,
    pub consumed_delta: f64,
}

pub struct TierAscendingQueryProtocol;

impl TierAscendingQueryProtocol {
    /// Step 4 (peer side): apply Laplace noise to scores before
    /// returning. Confidence interval reflects noise scale.
    pub fn apply_dp_to_contribution(result: &RecallResultLite,
                                    budget: &DPParameters,
                                    rng_seed: u64) -> RecallResultLite {
        let mut rng = SplitMix64::new(rng_seed);
        let scale = 1.0 / budget.epsilon;
        let noised: Vec<RecallScoreLite> = result.rows.iter()
            .map(|s| {
                let noise = DPORReduction::laplace_noise(scale, &mut rng) as f32;
                RecallScoreLite { row_id: s.row_id, score: s.score + noise }
            })
            .collect();
        let ci_half = 1.96_f32 * scale as f32;
        RecallResultLite {
            rows: noised,
            confidence_interval: Some((-ci_half, ci_half)),
            primitive_name: result.primitive_name.clone(),
        }
    }

    /// Step 5: combine local exact + noisy peer responses. Union by
    /// row id, sum scores, take widest CI.
    pub fn combine(local: &RecallResultLite,
                   peers: &[PeerResponse]) -> RecallResultLite {
        let mut combined: HashMap<u128, f32> = HashMap::new();
        for s in &local.rows {
            *combined.entry(s.row_id).or_insert(0.0) += s.score;
        }
        let mut widest_ci: Option<(f32, f32)> = None;
        for peer in peers {
            for s in &peer.contribution.rows {
                *combined.entry(s.row_id).or_insert(0.0) += s.score;
            }
            if let Some(ci) = peer.contribution.confidence_interval {
                let width = ci.1 - ci.0;
                let widest = widest_ci.map(|w| w.1 - w.0).unwrap_or(0.0);
                if widest_ci.is_none() || width > widest {
                    widest_ci = Some(ci);
                }
            }
        }
        let mut merged: Vec<RecallScoreLite> = combined.into_iter()
            .map(|(row_id, score)| RecallScoreLite { row_id, score })
            .collect();
        merged.sort_by(|a, b| {
            b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal)
                .then(a.row_id.cmp(&b.row_id))
        });
        RecallResultLite {
            rows: merged,
            confidence_interval: widest_ci,
            primitive_name: local.primitive_name.clone(),
        }
    }
}

/// Privacy ledger: per-peer cumulative (ε, δ) consumed. Reset daily.
#[derive(Debug, Clone)]
pub struct PrivacyLedger {
    pub entries: HashMap<[u8; 16], (f64, f64)>,
    pub daily_budget: DPParameters,
}

impl PrivacyLedger {
    pub fn new(daily_budget: DPParameters) -> Self {
        Self { entries: HashMap::new(), daily_budget }
    }

    pub fn remaining(&self, peer: [u8; 16]) -> (f64, f64) {
        let used = self.entries.get(&peer).copied().unwrap_or((0.0, 0.0));
        (
            (self.daily_budget.epsilon - used.0).max(0.0),
            (self.daily_budget.delta - used.1).max(0.0),
        )
    }

    pub fn can_consume(&self, peer: [u8; 16], query: &DPParameters) -> bool {
        let rem = self.remaining(peer);
        rem.0 >= query.epsilon && rem.1 >= query.delta
    }

    pub fn consume(&mut self, peer: [u8; 16], query: &DPParameters) {
        let used = self.entries.entry(peer).or_insert((0.0, 0.0));
        used.0 += query.epsilon;
        used.1 += query.delta;
    }

    pub fn daily_reset(&mut self) {
        self.entries.clear();
    }
}
