// consolidate.rs — Rust mirror of CognitionKit/Consolidate.swift.
//
// Pure data types for the `consolidate` recipe: input parameters and output
// fields. Mirrors `Consolidate.Input` and `Consolidate.Output` from the Swift
// port.
//
// INTRA-ITEM distillation: the Swift `Consolidate.run` drives the PER-ITEM
// sweep `GeniusLocusKit.distillItemsSweep`. Each stored item is reduced from
// its OWN sentences; only the per-item sweep model is in effect.
//
// The Rust port does not run a live distillation sweep — `EstateCoordinator`
// in GeniusLocusKit Rust owns the storage I/O. This module defines:
//
//   1. `ConsolidateInput`  — per-call parameters (clusterID, includeHeld are
//      accepted for API stability but unused by the per-item sweep model).
//      Mirrors `Consolidate.Input` in Swift.
//
//   2. `ConsolidateOutput` — sweep result (factoidsProduced).
//      Mirrors `Consolidate.Output` in Swift.
//
// Rust callers that want to run a live sweep instantiate `EstateCoordinator`
// from GeniusLocusKit Rust and call the coordinator's sweep entry point
// directly.

// MARK: - ConsolidateInput

/// Parameters controlling a consolidation sweep.
///
/// Mirrors `Consolidate.Input` in the Swift port.
///
/// - `cluster_id`: accepted for API stability; unused by the per-item model.
/// - `include_held`: accepted for API stability; unused by the per-item model.
#[derive(Debug, Clone, PartialEq)]
pub struct ConsolidateInput {
    /// Reserved for future per-item filtering.
    /// Currently unused — the sweep processes all eligible items.
    pub cluster_id: Option<String>,

    /// Reserved for future use. Currently unused in the per-item model.
    pub include_held: bool,
}

impl Default for ConsolidateInput {
    /// Default: no filtering; mirrors `Consolidate.Input(clusterID: nil, includeHeld: false)`.
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
///   this sweep (one per intra-item-distilled item).
#[derive(Debug, Clone, PartialEq)]
pub struct ConsolidateOutput {
    /// Number of distilled factoid drawers produced this sweep.
    pub factoids_produced: usize,
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    // MARK: - ConsolidateInput defaults

    #[test]
    fn default_input_has_no_targeting() {
        let input = ConsolidateInput::default();
        assert!(input.cluster_id.is_none());
        assert!(!input.include_held);
    }

    #[test]
    fn input_fields_round_trip() {
        let input = ConsolidateInput {
            cluster_id: Some("abc".to_string()),
            include_held: true,
        };
        assert_eq!(input.cluster_id.as_deref(), Some("abc"));
        assert!(input.include_held);
    }

    // MARK: - ConsolidateOutput

    #[test]
    fn output_fields_accessible() {
        let output = ConsolidateOutput { factoids_produced: 3 };
        assert_eq!(output.factoids_produced, 3);
    }

    #[test]
    fn output_zero_is_valid() {
        let output = ConsolidateOutput { factoids_produced: 0 };
        assert_eq!(output.factoids_produced, 0);
    }
}
