// consolidate.rs — Rust mirror of CognitionKit/Consolidate.swift.
//
// Pure data types for the `consolidate` recipe: input parameters and
// output fields. Mirrors `Consolidate.Input` and `Consolidate.Output`
// from the Swift port.
//
// The Rust port does not run a live distillation sweep (EstateCoordinator
// lives in GeniusLocusKit Rust and owns the storage I/O). This module
// defines:
//
//   1. `ConsolidateInput`  — per-call sweep parameters, mirrors
//      `Consolidate.Input` (clusterID, includeHeld).
//
//   2. `ConsolidateOutput` — sweep result, mirrors `Consolidate.Output`
//      (factoidsProduced, heldClusterIDs, failedClusterIDs).
//
//   3. `consolidate_input_to_sweep_params` — maps a `ConsolidateInput`
//      to the `SweepTargetingParams` that `run_distillation_sweep` (or
//      the coordinator's equivalent) expects. This pure mapping keeps
//      the recipe layer decoupled from the storage layer.
//
// The coordinator-level sweep is not called from here — Rust callers
// that want to run a live sweep instantiate `EstateCoordinator` from
// GeniusLocusKit Rust and pass `SweepTargetingParams` directly.

use genius_locus_kit::brain::cluster_status::SweepTargetingParams;

// MARK: - ConsolidateInput

/// Parameters controlling a consolidation sweep.
///
/// Mirrors `Consolidate.Input` in the Swift port.
///
/// - `cluster_id`: target a specific cluster by UUID string.
///   `None` sweeps all ready clusters (the default full-sweep mode).
/// - `include_held`: when `true`, include SNR-gated held clusters in
///   the sweep so they get another distillation attempt.
#[derive(Debug, Clone, PartialEq)]
pub struct ConsolidateInput {
    /// Restrict the sweep to a single cluster by UUID string.
    /// `None` sweeps all eligible open (and optionally held) clusters.
    pub cluster_id: Option<String>,

    /// Include SNR-gated held clusters in the sweep.
    ///
    /// When `false` (default), only `status = 'open'` clusters are swept.
    /// When `true`, both `status = 'open'` and `status = 'held'` clusters
    /// are swept, giving held clusters another distillation attempt.
    pub include_held: bool,
}

impl Default for ConsolidateInput {
    /// Default: sweep all open clusters; do not include held.
    /// Matches `Consolidate.Input(clusterID: nil, includeHeld: false)`.
    fn default() -> Self {
        ConsolidateInput {
            cluster_id: None,
            include_held: false,
        }
    }
}

// MARK: - ConsolidateOutput

/// Result of a consolidation sweep.
///
/// Mirrors `Consolidate.Output` in the Swift port.
///
/// - `factoids_produced`: count of distilled factoid drawers produced
///   this sweep.
/// - `held_cluster_ids`: cluster UUIDs with `status = 'held'` after the
///   sweep — those gated by the SNR threshold (SNR < 2.0).
/// - `failed_cluster_ids`: cluster UUIDs with `status = 'failed'` after
///   the sweep — those where confidence fell below 0.4 or a pipeline
///   error occurred.
#[derive(Debug, Clone, PartialEq)]
pub struct ConsolidateOutput {
    /// Number of distilled factoid drawers produced this sweep.
    pub factoids_produced: usize,

    /// Cluster UUIDs with `status = 'held'` after the sweep.
    pub held_cluster_ids: Vec<String>,

    /// Cluster UUIDs with `status = 'failed'` after the sweep.
    pub failed_cluster_ids: Vec<String>,
}

// MARK: - Input → SweepTargetingParams mapping

/// Map a `ConsolidateInput` to the `SweepTargetingParams` consumed by
/// the GLK sweep.
///
/// Pure function — no I/O. The coordinator applies targeting params to
/// decide which clusters enter the distillation batch. This mapping
/// keeps the recipe layer decoupled from the GLK storage surface.
///
/// Mirrors the forwarding in `Consolidate.run` (Swift):
///   `kit.runDistillationSweep(…, clusterID: input.clusterID, includeHeld: input.includeHeld)`
pub fn consolidate_input_to_sweep_params(input: &ConsolidateInput) -> SweepTargetingParams {
    SweepTargetingParams {
        cluster_id: input.cluster_id.clone(),
        include_held: input.include_held,
    }
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;
    use genius_locus_kit::brain::cluster_status::{STATUS_HELD, STATUS_OPEN, filter_cluster_for_sweep};

    // MARK: - ConsolidateInput defaults

    #[test]
    fn default_input_sweeps_all_open_no_held() {
        let input = ConsolidateInput::default();
        assert!(input.cluster_id.is_none());
        assert!(!input.include_held);
    }

    // MARK: - consolidate_input_to_sweep_params

    #[test]
    fn params_from_default_input_sweeps_open_not_held() {
        let input = ConsolidateInput::default();
        let params = consolidate_input_to_sweep_params(&input);
        // open cluster passes
        assert!(filter_cluster_for_sweep("cluster-1", STATUS_OPEN, &params));
        // held cluster does not pass
        assert!(!filter_cluster_for_sweep("cluster-1", STATUS_HELD, &params));
    }

    #[test]
    fn params_from_include_held_true_allows_held() {
        let input = ConsolidateInput {
            cluster_id: None,
            include_held: true,
        };
        let params = consolidate_input_to_sweep_params(&input);
        assert!(filter_cluster_for_sweep("cluster-1", STATUS_HELD, &params));
        assert!(filter_cluster_for_sweep("cluster-1", STATUS_OPEN, &params));
    }

    #[test]
    fn params_from_targeted_cluster_id_filters_correctly() {
        let input = ConsolidateInput {
            cluster_id: Some("target-uuid".to_string()),
            include_held: false,
        };
        let params = consolidate_input_to_sweep_params(&input);
        // matching open cluster passes
        assert!(filter_cluster_for_sweep("target-uuid", STATUS_OPEN, &params));
        // non-matching open cluster fails
        assert!(!filter_cluster_for_sweep("other-uuid", STATUS_OPEN, &params));
    }

    #[test]
    fn params_cluster_id_is_cloned_not_moved() {
        let input = ConsolidateInput {
            cluster_id: Some("abc".to_string()),
            include_held: false,
        };
        let params = consolidate_input_to_sweep_params(&input);
        // input is still accessible after mapping (no move)
        assert_eq!(input.cluster_id.as_deref(), Some("abc"));
        assert_eq!(params.cluster_id.as_deref(), Some("abc"));
    }

    // MARK: - ConsolidateOutput

    #[test]
    fn output_fields_accessible() {
        let output = ConsolidateOutput {
            factoids_produced: 3,
            held_cluster_ids: vec!["h1".to_string()],
            failed_cluster_ids: vec!["f1".to_string(), "f2".to_string()],
        };
        assert_eq!(output.factoids_produced, 3);
        assert_eq!(output.held_cluster_ids, vec!["h1"]);
        assert_eq!(output.failed_cluster_ids.len(), 2);
    }

    #[test]
    fn output_empty_is_valid() {
        let output = ConsolidateOutput {
            factoids_produced: 0,
            held_cluster_ids: vec![],
            failed_cluster_ids: vec![],
        };
        assert_eq!(output.factoids_produced, 0);
        assert!(output.held_cluster_ids.is_empty());
        assert!(output.failed_cluster_ids.is_empty());
    }
}
