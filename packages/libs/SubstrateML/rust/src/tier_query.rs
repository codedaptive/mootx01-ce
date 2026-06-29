// tier_query.rs
//
// Tier-ascending query protocol per cookbook § 12.4. Mirror of
// TierAscendingQuery.swift.
//
// Five-step: local exact compute, sign with shared key, forward to
// peers/aggregator, peer applies DP, originator combines.
//
// RECALL-RESULT TYPES: This module uses the canonical recall vocabulary
// (RecallScore, RecallResult, DistanceBreakdown) from substrate-types,
// which is the canonical Rust mirror of the Swift recall vocabulary in
// SubstrateTypes/RecallTypes.swift. The force-mirror ruling (PAR-3A-SM,
// 2026-06-05) replaces the prior Swift/Rust asymmetry comment; the Lite
// stand-ins (RecallScoreLite, RecallResultLite) have been removed.

use std::collections::HashMap;
use substrate_types::hlc::HLC;
use substrate_types::{RecallScore, RecallResult, DistanceBreakdown};
use substrate_types::row::RowId;
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
pub struct PeerResponse {
    pub peer_estate: [u8; 16],
    /// Contribution from this peer. Uses the canonical RecallResult from
    /// substrate-types, which carries rows (Vec<RecallScore>), a
    /// DistanceBreakdown, an optional confidence interval, and a
    /// primitive_name. Mirrors Swift PeerResponse.contribution: RecallResult.
    pub contribution: RecallResult,
    pub consumed_epsilon: f64,
    pub consumed_delta: f64,
}

pub struct TierAscendingQueryProtocol;

impl TierAscendingQueryProtocol {
    /// Step 4 (peer side): apply Laplace noise to scores before
    /// returning. Confidence interval reflects noise scale.
    ///
    /// Mirrors Swift TierAscendingQueryProtocol.applyDPToContribution.
    pub fn apply_dp_to_contribution(
        result: &RecallResult,
        budget: &DPParameters,
        rng_seed: u64,
    ) -> RecallResult {
        let mut rng = SplitMix64::new(rng_seed);
        let scale = 1.0 / budget.epsilon;
        let noised: Vec<RecallScore> = result.rows.iter()
            .map(|s| {
                let noise = DPORReduction::laplace_noise(scale, &mut rng) as f32;
                RecallScore::new(s.row_id, s.score + noise)
            })
            .collect();
        let ci_half = 1.96_f32 * scale as f32;
        RecallResult::new(
            noised,
            // Zero out the per-component breakdown. Forwarding the exact
            // breakdown (lattice, fingerprint, temporal, bitmap contributions)
            // leaks precise lane-level distances back to the originator even
            // though the scores were noised. Suppressing the breakdown at the
            // DP boundary prevents that side-channel. The originator's combine
            // step uses local.breakdown for its own exact breakdown, so
            // consumers that need attribution still have it for local results.
            DistanceBreakdown::ZERO,
            Some((-ci_half, ci_half)),
            result.primitive_name.clone(),
        )
    }

    /// Step 5: combine local exact + noisy peer responses. Union by
    /// RowId, sum scores, take widest CI. Mirrors Swift
    /// TierAscendingQueryProtocol.combine(local:peers:).
    pub fn combine(local: &RecallResult, peers: &[PeerResponse]) -> RecallResult {
        // Accumulate scores keyed by RowId. RowId(u128) is Copy.
        let mut combined: HashMap<RowId, f32> = HashMap::new();
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
        let mut merged: Vec<RecallScore> = combined
            .into_iter()
            .map(|(row_id, score)| RecallScore::new(row_id, score))
            .collect();
        // Sort descending by score; tie-break by row_id ascending so
        // output is deterministic. Mirrors Swift combine sort.
        merged.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(a.row_id.0.cmp(&b.row_id.0))
        });
        RecallResult::new(
            merged,
            local.breakdown,
            widest_ci,
            local.primitive_name.clone(),
        )
    }
}

/// Privacy ledger: per-peer cumulative (ε, δ) consumed. Reset daily.
/// Mirrors Swift PrivacyLedger.
#[derive(Debug, Clone)]
pub struct PrivacyLedger {
    /// Cumulative (epsilon, delta) spent per peer (identified by 16-byte
    /// estate ID).
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use substrate_types::row::RowId;
    use substrate_types::DistanceBreakdown;

    fn dp(epsilon: f64) -> DPParameters {
        // k_anonymity: 1 is the minimum valid value; tests focus on
        // epsilon/delta budget behavior, not k-anonymity thresholding.
        DPParameters { epsilon, delta: 0.0, k_anonymity: 1 }
    }

    fn dp_with_delta(epsilon: f64, delta: f64) -> DPParameters {
        DPParameters { epsilon, delta, k_anonymity: 1 }
    }

    fn score(id: u128, s: f32) -> RecallScore {
        RecallScore::new(RowId(id), s)
    }

    fn simple_result(rows: Vec<RecallScore>, name: &str) -> RecallResult {
        RecallResult::simple(rows, name)
    }

    // --- apply_dp_to_contribution ---

    #[test]
    fn dp_noise_is_seed_deterministic() {
        let id = 0x0000_0000_0000_0000_0000_0000_0000_0001u128;
        let result = simple_result(vec![score(id, 1.0)], "p");
        let budget = dp(1.0);
        let a = TierAscendingQueryProtocol::apply_dp_to_contribution(&result, &budget, 0xABCDEF);
        let b = TierAscendingQueryProtocol::apply_dp_to_contribution(&result, &budget, 0xABCDEF);
        assert_eq!(a.rows[0].score, b.rows[0].score);
        // Different seed should (with overwhelming probability) noise differently.
        let c = TierAscendingQueryProtocol::apply_dp_to_contribution(&result, &budget, 0x123456);
        assert_ne!(a.rows[0].score, c.rows[0].score);
    }

    #[test]
    fn dp_noise_sets_confidence_interval() {
        let result = simple_result(vec![], "p");
        let budget = dp(1.0);
        let noised = TierAscendingQueryProtocol::apply_dp_to_contribution(&result, &budget, 42);
        let ci = noised.confidence_interval.expect("CI should be set after DP");
        assert!((ci.0 + 1.96).abs() < 1e-5, "lower bound ~= -1.96 for scale=1");
        assert!((ci.1 - 1.96).abs() < 1e-5, "upper bound ~=  1.96 for scale=1");
    }

    #[test]
    fn dp_noise_preserves_primitive_name() {
        let result = simple_result(vec![], "recall_hybrid");
        let budget = dp(0.5);
        let noised = TierAscendingQueryProtocol::apply_dp_to_contribution(&result, &budget, 0);
        assert_eq!(noised.primitive_name, "recall_hybrid");
    }

    /// apply_dp_to_contribution must zero out the DistanceBreakdown.
    ///
    /// Forwarding the exact per-component breakdown (lattice, fingerprint,
    /// temporal, bitmap contributions) leaks precise lane-level distances
    /// to the originator even though scores are noised. The DP boundary
    /// must suppress the breakdown by returning DistanceBreakdown::ZERO.
    #[test]
    fn dp_noise_zeroes_distance_breakdown() {
        let non_zero = DistanceBreakdown::new(0.1, 0.2, 0.3, 0.4);
        let result = RecallResult::new(
            vec![score(1, 1.0)],
            non_zero,
            None,
            "recall_vector",
        );
        let budget = dp(1.0);
        let noised = TierAscendingQueryProtocol::apply_dp_to_contribution(&result, &budget, 42);
        // Breakdown must be zeroed — the exact distances must not leak.
        assert_eq!(noised.breakdown, DistanceBreakdown::ZERO,
            "DP boundary must zero the breakdown to prevent exact-distance side-channel");
    }

    // --- combine ---

    #[test]
    fn combine_unions_rows_summing_scores() {
        let r1 = 1u128; let r2 = 2u128; let r3 = 3u128;
        let local = simple_result(vec![score(r1, 1.0), score(r2, 2.0)], "p");
        let peer = PeerResponse {
            peer_estate: [0u8; 16],
            contribution: simple_result(vec![score(r2, 0.5), score(r3, 3.0)], "p"),
            consumed_epsilon: 0.1,
            consumed_delta: 0.0,
        };
        let combined = TierAscendingQueryProtocol::combine(&local, &[peer]);
        let by_id: HashMap<u128, f32> = combined.rows.iter()
            .map(|s| (s.row_id.0, s.score))
            .collect();
        assert!((by_id[&r1] - 1.0).abs() < 1e-5);
        assert!((by_id[&r2] - 2.5).abs() < 1e-5);
        assert!((by_id[&r3] - 3.0).abs() < 1e-5);
        assert_eq!(combined.rows.len(), 3);
    }

    #[test]
    fn combine_returns_rows_sorted_descending_by_score() {
        let r1 = 1u128; let r2 = 2u128; let r3 = 3u128;
        let local = simple_result(vec![score(r1, 1.0), score(r2, 5.0), score(r3, 3.0)], "p");
        let combined = TierAscendingQueryProtocol::combine(&local, &[]);
        let scores: Vec<f32> = combined.rows.iter().map(|s| s.score).collect();
        let mut expected = scores.clone();
        expected.sort_by(|a, b| b.partial_cmp(a).unwrap());
        assert_eq!(scores, expected);
        assert_eq!(combined.rows[0].row_id.0, r2); // highest score
    }

    #[test]
    fn combine_carries_widest_peer_confidence_interval() {
        let local = simple_result(vec![score(1, 1.0)], "p");
        let narrow = PeerResponse {
            peer_estate: [0u8; 16],
            contribution: RecallResult::new(
                vec![], DistanceBreakdown::ZERO, Some((-0.1, 0.1)), "p"),
            consumed_epsilon: 0.1,
            consumed_delta: 0.0,
        };
        let wide = PeerResponse {
            peer_estate: [1u8; 16],
            contribution: RecallResult::new(
                vec![], DistanceBreakdown::ZERO, Some((-2.0, 2.0)), "p"),
            consumed_epsilon: 0.1,
            consumed_delta: 0.0,
        };
        let combined = TierAscendingQueryProtocol::combine(&local, &[narrow, wide]);
        let ci = combined.confidence_interval.expect("CI required");
        assert!((ci.0 + 2.0).abs() < 1e-5);
        assert!((ci.1 - 2.0).abs() < 1e-5);
    }

    // --- PrivacyLedger ---

    #[test]
    fn fresh_ledger_reports_full_daily_budget() {
        let peer = [0u8; 16];
        let ledger = PrivacyLedger::new(dp_with_delta(1.0, 1e-6));
        let rem = ledger.remaining(peer);
        assert!((rem.0 - 1.0).abs() < 1e-9);
        assert!((rem.1 - 1e-6).abs() < 1e-12);
        assert!(ledger.can_consume(peer, &dp(0.5)));
    }

    #[test]
    fn consume_debits_budget_and_refuses_over_budget_queries() {
        let peer = [0u8; 16];
        let mut ledger = PrivacyLedger::new(dp_with_delta(1.0, 1e-6));
        ledger.consume(peer, &dp(0.8));
        assert!((ledger.remaining(peer).0 - 0.2).abs() < 1e-9);
        // 0.8 already spent; a 0.5 query would exceed the 1.0 budget.
        assert!(!ledger.can_consume(peer, &dp(0.5)));
    }

    #[test]
    fn daily_reset_restores_full_budget() {
        let peer = [0u8; 16];
        let mut ledger = PrivacyLedger::new(dp_with_delta(1.0, 1e-6));
        ledger.consume(peer, &dp(0.9));
        ledger.daily_reset();
        assert!((ledger.remaining(peer).0 - 1.0).abs() < 1e-9);
    }
}
