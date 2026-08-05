//! PR-09 verification for the subject-backfill rider seam — Rust twin of
//! `SubjectBackfillCycleTests.swift`, plus the DARK-LANE gate pin: the
//! Rust lane ships with NO producer, the sweep refuses by default, and
//! the drain lane does not render. Everything pinned is DETERMINISTIC;
//! producer output text is never pinned (stubs are fixtures, not model
//! claims).

use std::sync::Arc;

use genius_locus_kit::{
    DrainStatus, EstateCoordinator, SubjectProducer,
};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::LatticeAnchor;
use locus_kit::frames::CaptureFrame;
use locus_kit::estate_types::OwnerCredentials;

const NOW: i64 = 1_700_000_000;

/// Deterministic stub: derives a valid register subject from the
/// content's first line.
struct StubProducer;
impl SubjectProducer for StubProducer {
    fn pipeline_version(&self) -> &str { "stub-v1" }
    fn subject_for_content(&self, content: &str) -> Result<String, String> {
        Ok(content.lines().next().unwrap_or("").chars().take(120).collect())
    }
}

/// Always violates the register (narrative frame) — proves inadmissible
/// output is skipped, never stored.
struct InadmissibleProducer;
impl SubjectProducer for InadmissibleProducer {
    fn pipeline_version(&self) -> &str { "bad-v1" }
    fn subject_for_content(&self, _content: &str) -> Result<String, String> {
        Ok("This is a summary that violates the register.".to_string())
    }
}

fn open_estate() -> (EstateCoordinator, genius_locus_kit::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("subject-backfill-tests"), 0, 100)
        .expect("open must succeed");
    (coord, handle)
}

fn seed_debt(coord: &EstateCoordinator, handle: &genius_locus_kit::EstateHandle, count: usize) {
    for i in 1..=count {
        let frame = CaptureFrame::new(
            format!("Debt row number {i} awaiting a subject."),
            CaptureChannel::Typed,
            "backfill-tests",
            LatticeAnchor::udc("000"),
            "subject-backfill-tests",
            "test-model-v1",
        );
        coord.capture(handle, frame, NOW).expect("capture must succeed");
    }
}

#[test]
fn dark_lane_default_sweep_refuses_and_lane_absent() {
    let (coord, handle) = open_estate();
    seed_debt(&coord, &handle, 2);
    // DARK-LANE PIN: by default no producer is registered anywhere in
    // production Rust — the sweep refuses…
    let err = coord.subject_backfill_sweep(&handle, 10, NOW);
    assert!(err.is_err(), "sweep must refuse while the lane is dark");
    // …and the drain lane does not render (barrier safety).
    let drains = coord.drain_statuses(&handle).expect("drain_statuses");
    assert!(
        !drains.iter().any(|d| d.name == DrainStatus::SUBJECT_BACKFILL_NAME),
        "subject_backfill lane must not render without a rider: {drains:?}"
    );
}

#[test]
fn sweep_drains_debt_with_registered_producer_and_lane_renders() {
    let (mut coord, handle) = open_estate();
    seed_debt(&coord, &handle, 5);
    {
        let estate = coord.estate_for(&handle).unwrap();
        assert_eq!(estate.count_subject_debt().unwrap(), 5);
    }
    coord
        .register_subject_producer(&handle, Arc::new(StubProducer))
        .expect("register must succeed");
    // Lane renders once the rider is registered, pending = debt.
    let drains = coord.drain_statuses(&handle).expect("drain_statuses");
    let lane = drains
        .iter()
        .find(|d| d.name == DrainStatus::SUBJECT_BACKFILL_NAME)
        .expect("lane must render with a rider");
    assert_eq!(lane.pending, 5);
    assert_eq!(lane.detail.as_deref(), Some("pipeline: stub-v1"));

    // Bounded batch: limit 3 writes 3, leaves 2.
    let first = coord.subject_backfill_sweep(&handle, 3, NOW + 10).unwrap();
    assert_eq!(first.written, 3);
    assert_eq!(first.skipped_inadmissible, 0);
    assert_eq!(first.remaining_debt, 2);
    // Settled-skip is structural: the second sweep drains the REST.
    let second = coord.subject_backfill_sweep(&handle, 10, NOW + 20).unwrap();
    assert_eq!(second.written, 2);
    assert_eq!(second.remaining_debt, 0);
    // Provenance: every written subject carries the producer's tier.
    let estate = coord.estate_for(&handle).unwrap();
    let stamped = estate
        .all_drawers()
        .unwrap()
        .into_iter()
        .filter(|d| d.subject_pipeline_version.as_deref() == Some("stub-v1"))
        .count();
    assert_eq!(stamped, 5);
    // Idempotent rerun: nothing left to enumerate.
    let third = coord.subject_backfill_sweep(&handle, 10, NOW + 30).unwrap();
    assert_eq!(third.written, 0);
}

#[test]
fn inadmissible_producer_output_is_skipped_never_stored() {
    let (mut coord, handle) = open_estate();
    seed_debt(&coord, &handle, 2);
    coord
        .register_subject_producer(&handle, Arc::new(InadmissibleProducer))
        .expect("register must succeed");
    let report = coord.subject_backfill_sweep(&handle, 10, NOW + 10).unwrap();
    assert_eq!(report.written, 0);
    assert_eq!(report.skipped_inadmissible, 2);
    assert_eq!(report.remaining_debt, 2, "skipped rows remain debt");
    let estate = coord.estate_for(&handle).unwrap();
    assert!(
        !estate
            .all_drawers()
            .unwrap()
            .iter()
            .any(|d| d.subject_pipeline_version.as_deref() == Some("bad-v1")),
        "inadmissible output must never be stored"
    );
}

/// Producer with regeneration tiers (PR-10 shape) — regenerates the
/// deterministic tiers, never ai-v1. Twin of Swift TieredStubProducer.
struct TieredStubProducer;
impl SubjectProducer for TieredStubProducer {
    fn pipeline_version(&self) -> &str { "tiered-stub-v1" }
    fn subject_for_content(&self, content: &str) -> Result<String, String> {
        Ok(content.lines().next().unwrap_or("").chars().take(120).collect())
    }
    fn regenerates_pipelines(&self) -> Vec<String> {
        vec!["consolidation-v1".to_string(), "seed-v1".to_string()]
    }
}

#[test]
fn tiered_sweep_regenerates_below_tiers_and_never_ai_v1() {
    let (mut coord, handle) = open_estate();
    // One NULL row.
    seed_debt(&coord, &handle, 1);
    // One ai-v1 row (subject at capture) and one consolidation-v1 row.
    let ai_id = {
        use locus_kit::drawer_operational::CaptureChannel;
        use locus_kit::estate_types::LatticeAnchor;
        use locus_kit::frames::CaptureFrame;
        let mut frame = CaptureFrame::new(
            "Filing-AI authored row.",
            CaptureChannel::Typed,
            "backfill-tests",
            LatticeAnchor::udc("000"),
            "subject-backfill-tests",
            "test-model-v1",
        );
        frame.subject = Some("Filing-AI subject stays untouched.".to_string());
        coord.capture(&handle, frame, NOW).unwrap().id
    };
    let cons_id = {
        use locus_kit::drawer_operational::CaptureChannel;
        use locus_kit::estate_types::LatticeAnchor;
        use locus_kit::frames::CaptureFrame;
        let frame = CaptureFrame::new(
            "Deterministic writer row.",
            CaptureChannel::Typed,
            "backfill-tests",
            LatticeAnchor::udc("000"),
            "subject-backfill-tests",
            "test-model-v1",
        );
        let id = coord.capture(&handle, frame, NOW).unwrap().id;
        let estate = coord.estate_for(&handle).unwrap();
        estate
            .set_subject_representation(&id, "Deterministic vague subject.", "consolidation-v1", NOW + 1)
            .unwrap();
        id
    };

    coord
        .register_subject_producer(&handle, Arc::new(TieredStubProducer))
        .unwrap();
    let report = coord.subject_backfill_sweep(&handle, 10, NOW + 10).unwrap();
    assert_eq!(report.written, 2, "NULL + consolidation-v1 regenerate: {report:?}");
    assert_eq!(report.remaining_debt, 0);

    let estate = coord.estate_for(&handle).unwrap();
    let after = estate.all_drawers().unwrap();
    let by_id: std::collections::BTreeMap<&str, &locus_kit::drawer::Drawer> =
        after.iter().map(|d| (d.id.as_str(), d)).collect();
    assert_eq!(
        by_id[ai_id.as_str()].subject_pipeline_version.as_deref(),
        Some("ai-v1"),
        "ai-v1 outranks the model — never overwritten"
    );
    assert_eq!(
        by_id[ai_id.as_str()].subject.as_deref(),
        Some("Filing-AI subject stays untouched.")
    );
    assert_eq!(
        by_id[cons_id.as_str()].subject_pipeline_version.as_deref(),
        Some("tiered-stub-v1")
    );
}
