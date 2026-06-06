// VizGraphSignals.swift
//
// Canonical metric names for the Topology VizGraph telemetry layer.
//
// Each of the five graph-analytic algorithms in SubstrateML emits one
// metric per invocation via IntellectusLib. The metric is emitted ONLY
// when monitoring is enabled (Intellectus.isEnabled == true). When
// monitoring is off (the default), the emit is a lock-free atomic-bool
// load + branch — no clock read, no allocation, no sink call.
//
// Signal semantics for the Topology view:
//
//   community.assignment
//     What it means: Louvain community detection completed; the node→
//     community partition is available for graph rendering (nodes in
//     the same community share a colour cluster).
//     Tags: "estate" (estate id), "node_count" (Int), "community_count" (Int).
//     Value: total number of communities discovered.
//
//   centrality.score
//     What it means: Eigenvalue centrality (power iteration) completed;
//     each node has a fresh authority score for keystone highlighting.
//     Tags: "estate" (estate id), "node_count" (Int), "iterations_to_convergence" (Int).
//     Value: 1.0 (completion indicator; the actual per-node scores are
//     not serialisable to a scalar metric — the caller stores them in
//     the row_keystone_score column per cookbook § 11.11).
//
//   nmf.factor
//     What it means: NMF factorisation (V ≈ W × H) completed; latent
//     themes are available for the Topology theme-overlay layer.
//     Tags: "estate" (estate id), "rows" (Int), "cols" (Int), "rank" (Int).
//     Value: final reconstruction error (Float32 cast to Double).
//
//   anomaly.flag
//     What it means: rolling z-score computation completed; the caller
//     should inspect the return value to decide whether to mark the
//     node/edge as anomalous in the Topology view.
//     Tags: "estate" (estate id), "method" ("z_score" | "modified_z_score"),
//           "window_size" (Int).
//     Value: the absolute z-score (always ≥ 0).
//
//   edge.decayed_weight
//     What it means: matrix decay pass completed; edge weights in the
//     Topology view should be refreshed from the now-decayed matrix.
//     Tags: "estate" (estate id), "matrix_rows" (Int), "matrix_cols" (Int),
//           "elapsed_seconds" (Int).
//     Value: the applied decay factor (0 < factor ≤ 1.0; 1.0 means no-op
//     because elapsed time was zero).
//
// Caller contract (mirrors IntellectusLib's determinism rule):
//   - Callers supply `estate`, `ts`, and any node/edge ID tags.
//   - Never read a clock inside SubstrateML. The `ts` argument is passed
//     in from the call site and forwarded directly to Intellectus.report.
//
// Dependency authority: DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28.

import Foundation
import IntellectusLib

/// Canonical metric names for the VizGraph telemetry layer.
///
/// Each constant is a dot-separated string used as the `name` argument
/// to `Intellectus.report(.metric(name:value:tags:ts:))`. Using a single
/// authoritative file prevents typos from producing orphaned metrics.
public enum VizGraphSignals {

    /// Emitted when `CommunityDetection.detect` completes.
    /// Value = number of communities found. Tags: estate, node_count, community_count.
    public static let communityAssignment = "community.assignment"

    /// Emitted when `EigenvalueCentrality.compute` completes.
    /// Value = 1.0 (completion indicator). Tags: estate, node_count, iterations_to_convergence.
    public static let centralityScore = "centrality.score"

    /// Emitted when `NMFAlternatingLeastSquares.factorize` completes.
    /// Value = final reconstruction error. Tags: estate, rows, cols, rank.
    public static let nmfFactor = "nmf.factor"

    /// Emitted when `AnomalyDetection.rollingZScore` or
    /// `rollingModifiedZScore` completes.
    /// Value = abs(z-score). Tags: estate, method, window_size.
    public static let anomalyFlag = "anomaly.flag"

    /// Emitted when `MatrixDecay.apply` completes.
    /// Value = applied decay factor. Tags: estate, matrix_rows, matrix_cols, elapsed_seconds.
    public static let edgeDecayedWeight = "edge.decayed_weight"
}
