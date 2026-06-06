// viz_graph_signals.rs
//
// Canonical metric names for the Topology VizGraph telemetry layer.
//
// Parity with Swift's VizGraphSignals.swift: same metric name strings,
// same tag semantics, same call contract. Any change here must be
// mirrored in the Swift file.
//
// Signal semantics (see Swift file for full documentation):
//   community.assignment  — Louvain partition complete
//   centrality.score      — power-iteration complete
//   nmf.factor            — NMF factorisation complete
//   anomaly.flag          — rolling z-score complete
//   edge.decayed_weight   — matrix decay pass complete
//
// Caller contract:
//   - Pass `estate` and `ts` from the call site.
//   - Never read a clock inside substrate-ml. The `ts` argument is
//     forwarded directly to report!().
//
// Dependency authority: DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28.

/// Canonical metric names for the VizGraph telemetry layer.
///
/// Each constant is a `&'static str` used as the `name` field of
/// `StatSample::Metric`. Using a single authoritative module prevents
/// typos from producing orphaned metrics.
///
/// The module is named `VizGraphSignals` to mirror the Swift enum
/// `VizGraphSignals` at the call sites (`VizGraphSignals::COMMUNITY_ASSIGNMENT`
/// etc.) — same visual pattern as Swift's `VizGraphSignals.communityAssignment`.
/// Rust convention prefers snake_case module names; we suppress the lint here
/// intentionally for Swift parity.
#[allow(non_snake_case)]
pub mod VizGraphSignals {
    /// Emitted when `CommunityDetection::detect` completes.
    /// Value = number of communities found. Tags: estate, node_count, community_count.
    pub const COMMUNITY_ASSIGNMENT: &str = "community.assignment";

    /// Emitted when `EigenvalueCentrality::compute` completes.
    /// Value = 1.0 (completion indicator). Tags: estate, node_count, iterations_to_convergence.
    pub const CENTRALITY_SCORE: &str = "centrality.score";

    /// Emitted when `NMFAlternatingLeastSquares::factorize` completes.
    /// Value = final reconstruction error. Tags: estate, rows, cols, rank.
    pub const NMF_FACTOR: &str = "nmf.factor";

    /// Emitted when `AnomalyDetection::rolling_z_score` or
    /// `rolling_modified_z_score` completes.
    /// Value = abs(z-score). Tags: estate, method, window_size.
    pub const ANOMALY_FLAG: &str = "anomaly.flag";

    /// Emitted when `MatrixDecay::apply` completes.
    /// Value = applied decay factor. Tags: estate, matrix_rows, matrix_cols, elapsed_seconds.
    pub const EDGE_DECAYED_WEIGHT: &str = "edge.decayed_weight";
}
