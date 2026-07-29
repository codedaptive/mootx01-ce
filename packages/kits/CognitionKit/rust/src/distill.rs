// distill.rs — Rust mirror of CognitionKit/Distill.swift.
//
// Per-item distillation sweep recipe (SPEC_DISTILLATION_STORAGE §3/§7.1):
// input parameters, output fields, and the `run_distill` recipe body.
//
// The sweep writes the four representation columns on each eligible SOURCE
// drawer row plus its distillation-features-v1 lane entry (§7.2). No
// factoid drawers, no tunnels (§11). Idempotent by the NULL predicate.
//
// This module mirrors the full Swift recipe shape:
//
//   1. `DistillInput`  — per-call parameters (cluster_id, include_held are
//      accepted for API stability but unused by the per-item sweep).
//      Mirrors `Distill.Input` in Swift.
//
//   2. `DistillOutput` — sweep result (items_distilled: drawer rows whose
//      representation columns were populated). Mirrors `Distill.Output`.
//
//   3. `run_distill`   — recipe body delegating to
//      `EstateCoordinator::distill_items_sweep`, matching Swift's
//      `Distill.run(input:estate:kit:now:)` shape.

// MARK: - DistillInput

/// Parameters controlling a distillation sweep.
///
/// Mirrors `Distill.Input` in the Swift port.
///
/// - `cluster_id`: accepted for API stability; unused by the per-item model.
/// - `include_held`: accepted for API stability; unused by the per-item model.
#[derive(Debug, Clone, PartialEq)]
pub struct DistillInput {
    /// Reserved for future per-item filtering.
    /// Currently unused — the sweep processes all eligible items.
    pub cluster_id: Option<String>,

    /// Reserved for future use. Currently unused in the per-item model.
    pub include_held: bool,
}

impl Default for DistillInput {
    /// Default: no filtering; mirrors `Distill.Input(clusterID: nil, includeHeld: false)`.
    fn default() -> Self {
        DistillInput {
            cluster_id: None,
            include_held: false,
        }
    }
}

// MARK: - DistillOutput

/// Result of a distillation sweep.
///
/// Mirrors `Distill.Output` in the Swift port.
#[derive(Debug, Clone, PartialEq)]
pub struct DistillOutput {
    /// Count of drawer rows whose representation columns were populated
    /// this sweep (SPEC §3 — factoid drawers no longer exist, so the
    /// production metric is items distilled).
    pub items_distilled: usize,
}

// MARK: - Recipe body

/// Run a per-item distillation sweep.
///
/// Rust parity of `Distill.run(input:estate:kit:now:)` in the Swift port.
/// Delegates entirely to `EstateCoordinator::distill_items_sweep`, which
/// distills every active drawer with non-empty content whose representation
/// is NULL or was produced under a stale pipeline contract — matrix path
/// for ≥3 sentences, token compaction for shorter items (§7.5).
///
/// # Parameters
///
/// - `_input`: `DistillInput` — accepted for API stability. `cluster_id`
///   and `include_held` are both current no-ops matching Swift's documented
///   "reserved for future use" status. The sweep always processes all
///   eligible items.
/// - `coord`: the estate coordinator owning the storage I/O.
/// - `handle`: estate to sweep.
/// - `now`: epoch millis (deterministic clock — callers must not read the
///   wall clock inside algorithms).
///
/// # Returns
///
/// `Ok(DistillOutput)` with `items_distilled` equal to the count of drawer
/// rows distilled this sweep. Returns `Err(VerbDispatchError)` for stale
/// handles or underlying I/O failures.
pub fn run_distill(
    _input: &DistillInput,
    coord: &genius_locus_kit::coordinator::EstateCoordinator,
    handle: &genius_locus_kit::handle::EstateHandle,
    now: i64,
) -> Result<DistillOutput, genius_locus_kit::coordinator::VerbDispatchError> {
    // Sweep all eligible items — limit: None mirrors Swift's `limit: Int? = nil`.
    // cluster_id and include_held are accepted but unused (API-stability no-ops).
    let items_distilled = coord.distill_items_sweep(handle, now, None)?;
    Ok(DistillOutput { items_distilled })
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    // MARK: - DistillInput defaults

    #[test]
    fn default_input_has_no_targeting() {
        let input = DistillInput::default();
        assert!(input.cluster_id.is_none());
        assert!(!input.include_held);
    }

    #[test]
    fn input_fields_round_trip() {
        let input = DistillInput {
            cluster_id: Some("abc".to_string()),
            include_held: true,
        };
        assert_eq!(input.cluster_id.as_deref(), Some("abc"));
        assert!(input.include_held);
    }

    // MARK: - DistillOutput

    #[test]
    fn output_fields_accessible() {
        let output = DistillOutput { items_distilled: 3 };
        assert_eq!(output.items_distilled, 3);
    }

    // MARK: - run_distill recipe body
    //
    // CK-DI-R1: run_distill on an empty estate yields zero items.
    // CK-DI-R2: a SHORT item (<3 sentences) distills via token compaction —
    //           the old skip is retired (§13.1); the representation lands on
    //           the source row and no factoid drawer is created.
    // CK-DI-R3: cluster_id/include_held no-ops must not cause errors.

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

    // CK-DI-R1: truly empty estate (no seeded wings, no drawers) → 0 items.
    #[test]
    fn ck_di_r1_empty_estate_distills_zero_items() {
        use std::sync::Arc;
        use genius_locus_kit::coordinator::EstateCoordinator;
        use locus_kit::{drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
                        estate_types::OwnerCredentials};
        let mut coord = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> = Arc::new(
            InMemoryDrawerStore::new(1_700_000_000, None).expect("store"));
        let handle = coord
            .open(store, OwnerCredentials::new("test"), 0, i64::MAX)
            .expect("open estate");
        let input = DistillInput::default();
        let out = run_distill(&input, &coord, &handle, 1_000_000)
            .expect("run_distill must not fail on empty estate");
        assert_eq!(out.items_distilled, 0, "empty estate should distill zero items");
    }

    // CK-DI-R2: short items distill via the §7.5 compaction path.
    #[test]
    fn ck_di_r2_short_items_distill_via_compaction() {
        let (coord, handle) = make_test_coordinator_and_estate();
        const NOW: i64 = 1_700_000_000;

        // Two items with 2 sentences each — below the matrix threshold, but
        // §13.1 covers them via the token-compaction path.
        let short_content = "First sentence stands. Second sentence stands.";
        let mut ids = Vec::new();
        for _ in 0..2 {
            let frame = locus_kit::frames::CaptureFrame::new(
                short_content,
                locus_kit::drawer_operational::CaptureChannel::Typed,
                "notes",
                locus_kit::estate_types::LatticeAnchor::udc("0"),
                "test",
                "test-v1",
            );
            ids.push(coord.capture(&handle, frame, NOW).expect("capture").id);
        }

        let input = DistillInput::default();
        let out = run_distill(&input, &coord, &handle, NOW + 1)
            .expect("run_distill must not fail");
        // ≥ 2, not == 2: seed_default_wings creates system drawers with
        // non-empty content, and §13.1 covers EVERY active item.
        assert!(out.items_distilled >= 2, "short items distill via compaction (§7.5)");

        // The representation rides the SOURCE rows; no factoid drawers.
        let all = coord.all_drawers(&handle).expect("all_drawers");
        assert!(!all.iter().any(|d| d.content.starts_with("[DIST|")));
        assert!(!all.iter().any(|d| d.added_by == "distillation-daemon"));
        for id in &ids {
            let row = all.iter().find(|d| &d.id == id).expect("source row");
            assert_eq!(row.distilled.as_deref(), Some("First sentence stands. Second sentence stands."));
            assert_eq!(
                row.distilled_pipeline_version.as_deref(),
                Some(substrate_ml::token_compaction::DISTILLATION_PIPELINE_VERSION)
            );
        }

        // Idempotent by the NULL predicate.
        let again = run_distill(&input, &coord, &handle, NOW + 2)
            .expect("second run must not fail");
        assert_eq!(again.items_distilled, 0, "distilled rows are skipped on re-run");
    }

    // CK-DI-R3: no-op fields must not cause errors.
    #[test]
    fn ck_di_r3_noop_fields_do_not_error() {
        let (coord, handle) = make_test_coordinator_and_estate();
        let input = DistillInput { cluster_id: Some("ignored".to_string()), include_held: true };
        // First run distills the seeded system drawers (§13.1); the no-op
        // fields must not error. The second run proves idempotency.
        let _ = run_distill(&input, &coord, &handle, 2_000_000)
            .expect("cluster_id/include_held no-ops must not cause errors");
        let second = run_distill(&input, &coord, &handle, 2_000_001)
            .expect("second run must not fail");
        assert_eq!(second.items_distilled, 0);
    }
}
