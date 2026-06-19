// brain/cluster_status.rs — Rust mirror of ClusterStatusReads.swift.
//
// Pure read-only query helpers for the memory_clusters status surface.
//
// The Swift side queries SQLite directly in `ClusterStatusReads.swift`.
// In the Rust coordinator the storage I/O lives at the coordinator level
// (where the DrawerStore is accessible). This module defines:
//
//   1. The string constants for valid cluster status values (mirrors
//      the status strings used in DistillationCycle.swift / coordinator.rs).
//
//   2. `SweepTargetingParams` — the per-call filter parameters that mirror
//      `Consolidate.Input.clusterID` and `Consolidate.Input.includeHeld`.
//      The coordinator passes these into `run_distillation_sweep` so the
//      sweep query can be narrowed before touching storage.
//
//   3. `filter_cluster_for_sweep` — pure function that decides whether a
//      cluster row (identified by cluster_id and status) is eligible for
//      inclusion in a sweep given a set of `SweepTargetingParams`. Mirrors
//      the WHERE clause logic in Swift's extended `runDistillationSweep`.
//
//   4. `cluster_status_from_outcome` — maps `SweepOutcome` to a `&'static str`
//      status for the `updateClusterStatus` storage write. Mirrors the three
//      branches in Swift's `runDistillationSweep` for loop.
//
// The storage-level `cluster_ids_with_status` query is an inherent method
// on `EstateCoordinator` (reads through the registered DrawerStore). This
// module provides the pure algorithmic surface that coordinators delegate to.

use crate::brain::distillation_cycle::SweepOutcome;

// MARK: - Cluster status string constants

/// Status value for clusters ready for distillation (member_count ≥ 3,
/// awaiting the next sweep fire). Matches "open" in memory_clusters.
pub const STATUS_OPEN: &str = "open";

/// Status value for clusters gated by the SNR threshold (SNR < 2.0).
/// These clusters need more members before a successful distillation.
/// Matches "held" in memory_clusters.
pub const STATUS_HELD: &str = "held";

/// Status value for clusters that failed distillation (confidence < 0.4
/// or explicit pipeline failure). Matches "failed" in memory_clusters.
pub const STATUS_FAILED: &str = "failed";

/// Status value for clusters that successfully produced a factoid drawer.
/// Matches "distilled" in memory_clusters.
pub const STATUS_DISTILLED: &str = "distilled";

// MARK: - Sweep targeting parameters

/// Per-call parameters that control which clusters are included in a
/// `run_distillation_sweep` call.
///
/// Mirrors `Consolidate.Input.clusterID` and `Consolidate.Input.includeHeld`:
///   - `cluster_id`: when `Some`, only the named cluster is eligible.
///   - `include_held`: when true, clusters with `status = 'held'` are
///     included alongside `status = 'open'` clusters.
#[derive(Debug, Clone)]
pub struct SweepTargetingParams {
    /// Restrict the sweep to a single cluster by UUID string.
    /// `None` sweeps all eligible clusters (the default full-sweep mode).
    pub cluster_id: Option<String>,

    /// Include SNR-gated held clusters in the sweep.
    ///
    /// When false (default), only `status = 'open'` clusters are swept.
    /// When true, both `status = 'open'` and `status = 'held'` clusters
    /// are swept, giving held clusters another distillation attempt.
    pub include_held: bool,
}

impl Default for SweepTargetingParams {
    /// Default targeting: sweep all open clusters, do not include held.
    /// Matches `runDistillationSweep(handle:distillFn:now:)` with no
    /// extra parameters — the original full-sweep behavior.
    fn default() -> Self {
        SweepTargetingParams {
            cluster_id: None,
            include_held: false,
        }
    }
}

// MARK: - Cluster eligibility filter

/// Decide whether a cluster row is eligible for inclusion in a sweep
/// given the `SweepTargetingParams`.
///
/// Pure function — no I/O. The coordinator queries storage for matching
/// rows and passes each `(cluster_id, status)` pair to this function
/// before including the cluster in the sweep batch.
///
/// Returns `true` when:
///   - The status is `STATUS_OPEN`, AND (if `params.cluster_id` is Some)
///     `row_cluster_id` matches it.
///   - The status is `STATUS_HELD` AND `params.include_held` is true AND
///     (if `params.cluster_id` is Some) `row_cluster_id` matches it.
///
/// Returns `false` for all other statuses ("distilled", "failed") or when
/// `params.cluster_id` is Some and does not match.
///
/// Mirrors the composite WHERE clause in Swift's extended runDistillationSweep:
///   - `status IN ('open')` or `status IN ('open', 'held')`
///   - AND optionally `id = params.cluster_id`
pub fn filter_cluster_for_sweep(
    row_cluster_id: &str,
    row_status: &str,
    params: &SweepTargetingParams,
) -> bool {
    // Status eligibility: open is always eligible; held is eligible only
    // when include_held is true.
    let status_ok = match row_status {
        STATUS_OPEN => true,
        STATUS_HELD => params.include_held,
        _ => false,
    };
    if !status_ok {
        return false;
    }
    // ID filter: when a specific cluster is targeted, only that cluster passes.
    if let Some(ref target_id) = params.cluster_id {
        row_cluster_id == target_id
    } else {
        true
    }
}

// MARK: - Status from sweep outcome

/// Map a `SweepOutcome` to the `status` string to write into `memory_clusters`.
///
/// Mirrors the three-branch status assignment in Swift's runDistillationSweep
/// for loop:
///   - `Succeeded` → "distilled"
///   - `Held`      → "held"
///   - `Failed`    → "failed"
pub fn status_from_outcome(outcome: &SweepOutcome) -> &'static str {
    match outcome {
        SweepOutcome::Succeeded { .. } => STATUS_DISTILLED,
        SweepOutcome::Held { .. } => STATUS_HELD,
        SweepOutcome::Failed { .. } => STATUS_FAILED,
    }
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;
    use crate::brain::distillation_cycle::SweepOutcome;
    use substrate_types::fingerprint256::Fingerprint256;

    // MARK: - SweepTargetingParams defaults

    #[test]
    fn default_params_sweep_all_open_no_held() {
        let params = SweepTargetingParams::default();
        assert!(params.cluster_id.is_none());
        assert!(!params.include_held);
    }

    // MARK: - filter_cluster_for_sweep

    #[test]
    fn open_cluster_passes_default_params() {
        let params = SweepTargetingParams::default();
        assert!(filter_cluster_for_sweep("cluster-1", STATUS_OPEN, &params));
    }

    #[test]
    fn held_cluster_excluded_by_default() {
        let params = SweepTargetingParams::default();
        assert!(!filter_cluster_for_sweep("cluster-1", STATUS_HELD, &params));
    }

    #[test]
    fn held_cluster_included_when_include_held_true() {
        let params = SweepTargetingParams {
            cluster_id: None,
            include_held: true,
        };
        assert!(filter_cluster_for_sweep("cluster-1", STATUS_HELD, &params));
    }

    #[test]
    fn distilled_cluster_always_excluded() {
        let params_default = SweepTargetingParams::default();
        let params_held = SweepTargetingParams { cluster_id: None, include_held: true };
        assert!(!filter_cluster_for_sweep("cluster-1", STATUS_DISTILLED, &params_default));
        assert!(!filter_cluster_for_sweep("cluster-1", STATUS_DISTILLED, &params_held));
    }

    #[test]
    fn failed_cluster_always_excluded() {
        let params_default = SweepTargetingParams::default();
        let params_held = SweepTargetingParams { cluster_id: None, include_held: true };
        assert!(!filter_cluster_for_sweep("cluster-1", STATUS_FAILED, &params_default));
        assert!(!filter_cluster_for_sweep("cluster-1", STATUS_FAILED, &params_held));
    }

    #[test]
    fn targeted_cluster_id_passes_for_matching_open() {
        let params = SweepTargetingParams {
            cluster_id: Some("target-uuid".to_string()),
            include_held: false,
        };
        assert!(filter_cluster_for_sweep("target-uuid", STATUS_OPEN, &params));
    }

    #[test]
    fn targeted_cluster_id_excludes_non_matching_open() {
        let params = SweepTargetingParams {
            cluster_id: Some("target-uuid".to_string()),
            include_held: false,
        };
        assert!(!filter_cluster_for_sweep("sibling-uuid", STATUS_OPEN, &params));
    }

    #[test]
    fn targeted_cluster_id_with_include_held_passes_matching_held() {
        let params = SweepTargetingParams {
            cluster_id: Some("held-target".to_string()),
            include_held: true,
        };
        assert!(filter_cluster_for_sweep("held-target", STATUS_HELD, &params));
    }

    #[test]
    fn targeted_cluster_id_with_include_held_excludes_non_matching_held() {
        let params = SweepTargetingParams {
            cluster_id: Some("held-target".to_string()),
            include_held: true,
        };
        assert!(!filter_cluster_for_sweep("other-held", STATUS_HELD, &params));
    }

    // MARK: - status_from_outcome

    #[test]
    fn succeeded_outcome_maps_to_distilled() {
        let outcome = SweepOutcome::Succeeded {
            drawer_content: "test".to_string(),
            feature_fingerprint: Fingerprint256::ZERO,
            snr: 3.5,
        };
        assert_eq!(status_from_outcome(&outcome), STATUS_DISTILLED);
    }

    #[test]
    fn held_outcome_maps_to_held() {
        let outcome = SweepOutcome::Held {
            snr: 1.0,
            held_reason: "SNR below gate".to_string(),
        };
        assert_eq!(status_from_outcome(&outcome), STATUS_HELD);
    }

    #[test]
    fn failed_outcome_maps_to_failed() {
        let outcome = SweepOutcome::Failed {
            snr: 2.5,
            failure_reason: Some("confidence too low".to_string()),
        };
        assert_eq!(status_from_outcome(&outcome), STATUS_FAILED);
    }
}
