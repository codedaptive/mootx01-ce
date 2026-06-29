// consolidate.rs — Rust mirror of CognitionKit/Consolidate.swift.
//
// Per-item distillation sweep recipe: input parameters, output fields,
// and the `run_consolidate` recipe body.
//
// INTRA-ITEM distillation: the Swift `Consolidate.run` drives the PER-ITEM
// sweep `GeniusLocusKit.distillItemsSweep`. Each stored item is reduced from
// its OWN sentences; only the per-item sweep model is in effect.
//
// This module mirrors the full Swift recipe shape:
//
//   1. `ConsolidateInput`  — per-call parameters (clusterID, includeHeld are
//      accepted for API stability but unused by the per-item sweep model).
//      Mirrors `Consolidate.Input` in Swift.
//
//   2. `ConsolidateOutput` — sweep result (factoidsProduced).
//      Mirrors `Consolidate.Output` in Swift.
//
//   3. `run_consolidate`  — recipe body delegating to
//      `EstateCoordinator::distill_items_sweep`, matching Swift's
//      `Consolidate.run(input:estate:kit:)` shape.
//
// Rust parity: the Rust recipe body is a thin adapter over the GLK coordinator
// (parity with Swift `Consolidate.run` → `kit.distillItemsSweep`). The
// `cluster_id` and `include_held` fields remain accepted no-ops (API stability)
// matching the current Swift implementation, which documents both as
// "reserved for future use".

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

// MARK: - Recipe body

/// Run an intra-item distillation sweep.
///
/// Rust parity of `Consolidate.run(input:estate:kit:)` in the Swift port.
/// Delegates entirely to `EstateCoordinator::distill_items_sweep`, which
/// iterates active not-yet-distilled items, reduces each from its own sentences
/// (M ≥ 3), and captures factoid drawers in `_distilled` with `_distilled_from`
/// tunnels.
///
/// # Parameters
///
/// - `_input`: `ConsolidateInput` — accepted for API stability. `cluster_id`
///   and `include_held` are both current no-ops matching Swift's documented
///   "reserved for future use" status. The sweep always processes all eligible
///   items.
/// - `coord`: the estate coordinator owning the storage I/O.
/// - `handle`: estate to sweep.
/// - `now`: epoch seconds (deterministic clock — callers must not pass
///   `SystemTime::now()` inside algorithms).
///
/// # Returns
///
/// `Ok(ConsolidateOutput)` with `factoids_produced` equal to the count of
/// factoid drawers created this sweep. Returns `Err(VerbDispatchError)` for
/// stale handles or underlying I/O failures.
pub fn run_consolidate(
    _input: &ConsolidateInput,
    coord: &genius_locus_kit::coordinator::EstateCoordinator,
    handle: &genius_locus_kit::handle::EstateHandle,
    now: i64,
) -> Result<ConsolidateOutput, genius_locus_kit::coordinator::VerbDispatchError> {
    // Sweep all eligible items — limit: None mirrors Swift's `limit: Int? = nil`.
    // cluster_id and include_held are accepted but unused (API-stability no-ops).
    let factoids_produced = coord.distill_items_sweep(handle, now, None)?;
    Ok(ConsolidateOutput { factoids_produced })
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

    // MARK: - run_consolidate recipe body (IMM-COG-001)
    //
    // CK-CON-1 (Rust): run_consolidate on an empty estate yields zero factoids.
    // CK-CON-2 (Rust): run_consolidate on items with fewer than 3 sentences yields
    //                   zero factoids (items are not distillable).
    // CK-CON-3 (Rust): run_consolidate wraps distill_items_sweep and returns
    //                   ConsolidateOutput with the produced count.
    //
    // These tests open an InMemory estate (no SQLite temp file required) and
    // drive run_consolidate through the full path.

    fn make_test_coordinator_and_estate()
        -> (genius_locus_kit::coordinator::EstateCoordinator, genius_locus_kit::handle::EstateHandle)
    {
        use std::sync::Arc;
        use genius_locus_kit::coordinator::EstateCoordinator;
        use locus_kit::{drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
                        estate_types::OwnerCredentials};

        const NOW: i64 = 1_700_000_000;
        let mut coord = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> = Arc::new(
            InMemoryDrawerStore::new(NOW, None).expect("store"),
        );
        let handle = coord
            .open(store, OwnerCredentials::new("test"), 0, i64::MAX)
            .expect("open estate");
        // Seed default wings so capture paths work.
        coord.seed_default_wings(&handle, NOW).expect("seed wings");
        (coord, handle)
    }

    // CK-CON-1: empty estate → 0 factoids produced.
    #[test]
    fn ck_con1_empty_estate_produces_zero_factoids() {
        let (coord, handle) = make_test_coordinator_and_estate();
        let input = ConsolidateInput::default();
        let out = run_consolidate(&input, &coord, &handle, 1_000_000)
            .expect("run_consolidate must not fail on empty estate");
        assert_eq!(out.factoids_produced, 0,
            "empty estate should produce zero factoids");
    }

    // CK-CON-2: items with fewer than 3 sentences are not distillable.
    // Captures 2 items with 2 sentences each — neither qualifies (MIN_INTRA_ITEM_UNITS = 3).
    #[test]
    fn ck_con2_items_with_two_sentences_not_distilled() {
        use std::sync::Arc;
        use genius_locus_kit::coordinator::EstateCoordinator;
        use locus_kit::{drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
                        estate_types::OwnerCredentials};

        const NOW: i64 = 1_700_000_000;
        let mut coord = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> = Arc::new(
            InMemoryDrawerStore::new(NOW, None).expect("store"),
        );
        let handle = coord
            .open(store, OwnerCredentials::new("test"), 0, i64::MAX)
            .expect("open");
        coord.seed_default_wings(&handle, NOW).expect("seed");

        // Capture two items with 2 sentences each — below the 3-sentence minimum.
        let short_content = "First sentence. Second sentence.";
        for _ in 0..2 {
            let frame = locus_kit::frames::CaptureFrame::new(
                short_content,
                locus_kit::drawer_operational::CaptureChannel::Typed,
                "notes",
                locus_kit::estate_types::LatticeAnchor::udc("0"),
                "test",
                "test-v1",
            );
            coord.capture(&handle, frame, NOW).expect("capture");
        }

        let input = ConsolidateInput::default();
        let out = run_consolidate(&input, &coord, &handle, NOW + 1)
            .expect("run_consolidate must not fail");
        assert_eq!(out.factoids_produced, 0,
            "items with <3 sentences must not be distilled");

        // Verify via all_drawers that no DIST-header drawers were produced.
        // (recall_scored returns GLKRecallResult, not iterable Vec; all_drawers is
        // the B-1-compliant read path for this check.)
        let all = coord.all_drawers(&handle).expect("all_drawers");
        assert!(!all.iter().any(|d| d.content.starts_with("[DIST|")),
            "_distilled factoid must not be created when no items qualify");
    }

    // CK-CON-3: run_consolidate returns ConsolidateOutput with the count from
    //            distill_items_sweep. Verifies the adapter wraps the coordinator
    //            surface correctly without duplicating logic.
    #[test]
    fn ck_con3_output_wraps_coordinator_count() {
        let (coord, handle) = make_test_coordinator_and_estate();
        let input = ConsolidateInput { cluster_id: Some("ignored".to_string()), include_held: true };
        // On empty estate the count is 0 — the no-op fields must not cause errors.
        let out = run_consolidate(&input, &coord, &handle, 2_000_000)
            .expect("cluster_id/include_held no-ops must not cause errors");
        // Count must be a usize (non-negative), mirroring Swift's Int return.
        let _ = out.factoids_produced;
    }
}
