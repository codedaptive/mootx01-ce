// brain/anomaly_flag_sweep.rs — Rust twin of AnomalyFlagSweep.swift.
//
// Room-cohesion anomaly-flag sweep for GeniusLocusKit (§11.18,
// anomalous-flag recall prefilter).
//
// Scores each drawer's mean shingle-similarity to its room peers,
// derives z-scores from the room's cohesion distribution, and
// sets/clears bit 26 (`is_anomalous()`) of `operational_bitmap`.
//
// Design mirrors the Swift reference exactly:
//   • Room minimum size: 3 drawers (z-score not meaningful for < 3 peers)
//   • Cohesion metric: mean char-3-shingle Jaccard to all room peers
//   • Gate: z-score ≤ −threshold (low-cohesion outlier) → is_anomalous = true
//   • Default threshold: 2.0 (≈ 2σ below-mean cutoff)
//   • Derived signal: no audit event, no lifecycle/lineage field touched
//   • Complexity: O(n²) per room — acceptable on the maintenance path
//   • Idempotent: skip-write when bit is already in the correct state
//
// SubstrateML provides `AnomalyDetection::z_score` and
// `shingle_similarity::similarity` — both are conformance-gated,
// byte-identical with the Swift port.
//
// GOLDEN PIN (cross-port): the planted-outlier fixture in
// `tests/anomaly_sweep_parity.rs` asserts that a known outlier room
// produces exactly 1 changed drawer on both Swift and Rust with the same
// content. The fixture uses the same cohort content from
// AnomalyFlagSweepTests.swift so both ports assert the same invariant
// against the same input.

/// Minimum drawers per room to run the z-score computation (§11.18).
///
/// Below this threshold the standard deviation is either zero or
/// statistically unstable. All drawers in under-threshold rooms have
/// bit 26 cleared — not anomalous by definition. Mirrors Swift
/// `GeniusLocusKit.anomalySweepMinRoomSize`.
pub const ANOMALY_SWEEP_MIN_ROOM_SIZE: usize = 3;

/// Default z-score threshold for the negative-cohesion anomaly gate (§11.18).
///
/// A drawer is flagged anomalous when its cohesion z-score ≤ −threshold.
/// Default 2.0 balances sensitivity against false-positive rate. Mirrors
/// Swift `GeniusLocusKit.anomalySweepDefaultThreshold`.
pub const ANOMALY_SWEEP_DEFAULT_THRESHOLD: f32 = 2.0;
