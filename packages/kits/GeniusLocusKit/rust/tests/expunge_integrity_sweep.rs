// expunge_integrity_sweep.rs
//
// Tests for GLK's `run_expunge_integrity_sweep` maintenance function.
//
// The sweep detects tombstoned rows that have no sealed "tombstone" or
// "expungeOrphan" audit event — the crash-window scenario where step 1
// (LocusKit storage expunge: tombstone+scrub) ran but the process crashed
// before step 3 (the §B-2a audit seal) completed. The sweep re-attempts
// the cross-kit vector+corpus delete and seals a synthetic "expungeOrphan"
// audit to close the audit gap.
//
// Tests:
//   S1 — crash-window: tombstoned row with no audit is detected, re-deleted
//        from corpus, and sealed as expungeOrphan. remediated_count == 1.
//   S2 — no-op: when all tombstoned rows have audits, the sweep is a clean
//        no-op (zero counts, zero errors).
//   S3 — locusOnly crash-window: tombstoned row with no audit, no Corpus or
//        VectorStore registered. Re-delete is a no-op (nothing to delete);
//        the row is sealed as expungeOrphan with remediated_count == 1
//        (the audit gap is closed, even though no vector was ever written).

use std::sync::Arc;

use corpus_kit::{Corpus, EmbeddingModelConfig};
use genius_locus_kit::{EstateCoordinator, ExpungeIntegritySweepResult};
use locus_kit::{
    drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::OwnerCredentials,
};
use locus_kit::{
    estate_types::LatticeAnchor,
    frames::CaptureFrame,
};
use locus_kit::drawer_operational::CaptureChannel;
use persistence_kit::{inmemory::InMemoryStorage, BackendConfiguration, EstateConfiguration, Storage};

const NOW: i64 = 1_700_000_000;
const NOW2: i64 = 1_700_000_001;

fn make_storage() -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    Arc::new(InMemoryStorage::new(config))
}

fn open_one() -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("owner"), 0, 100)
        .expect("open");
    (coord, handle)
}

fn cap_frame(content: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "sweep-tests",
        LatticeAnchor::udc("000"),
        "test-agent",
        "test-embed-v1",
    )
}

fn make_corpus() -> Arc<Corpus> {
    let storage = make_storage();
    Arc::new(Corpus::open(storage, EmbeddingModelConfig::Deterministic).expect("Corpus::open"))
}

// ---------------------------------------------------------------------------
// Helper: tombstone a row WITHOUT sealing any audit event.
//
// This simulates the crash-window: step 1 (LocusKit tombstone+scrub) ran,
// but the process crashed before step 3 (audit seal). The row is tombstoned
// and content is zeroed; no "tombstone" or "expungeOrphan" audit exists.
// ---------------------------------------------------------------------------

fn seed_crash_window(
    coord: &EstateCoordinator,
    handle: &genius_locus_kit::handle::EstateHandle,
    content: &str,
) -> String {
    let drawer = coord
        .capture(handle, cap_frame(content), NOW)
        .expect("capture for crash-window seed");

    let estate = coord.estate_for(handle).expect("estate for crash-window seed");
    // `seal_audit: false` — tombstones and scrubs the row but holds the event
    // unsealed (the GLK coordinator path). We immediately discard the event
    // to simulate a crash before the seal call.
    let _unsealed = estate
        .expunge(&drawer.id, "crash-window-sim", true, NOW2, false)
        .expect("estate expunge (no seal) for crash-window seed");

    drawer.id
}

// ---------------------------------------------------------------------------
// S1: crash-window row is detected and remediated
// ---------------------------------------------------------------------------

/// Seeds a crash-window tombstoned row (no audit), registers a Corpus, then
/// runs the sweep. The sweep must detect the row, re-attempt the corpus
/// delete, and seal an expungeOrphan audit. remediated_count == 1.
///
/// Also verifies that the corpus no longer recalls the drawer after the sweep
/// re-attempted the delete.
#[test]
fn s1_sweep_remediates_crash_window_row_with_corpus() {
    let (mut coord, h) = open_one();
    let corpus = make_corpus();

    // Capture and ingest into corpus BEFORE seeding the crash window so the
    // corpus has an entry to re-delete.
    let drawer = coord
        .capture(&h, cap_frame("sweep test content for s1"), NOW)
        .expect("capture");
    corpus.ingest(&drawer.content, &drawer.id, NOW).expect("ingest");
    coord.register_corpus(&h, corpus.clone());

    // Tombstone the row WITHOUT sealing any audit (crash-window simulation).
    let estate = coord.estate_for(&h).expect("estate");
    let _unsealed = estate
        .expunge(&drawer.id, "crash-window-sim", true, NOW2, false)
        .expect("estate expunge no seal");

    // Verify pre-condition: no tombstone or expungeOrphan audit event yet.
    let trail_before = estate.audit_trail(&drawer.id).expect("audit_trail before");
    let has_expunge_audit = trail_before
        .iter()
        .any(|e| e.verb == "tombstone" || e.verb == "expungeOrphan");
    assert!(
        !has_expunge_audit,
        "crash-window row must have no expunge audit before sweep; got verbs {:?}",
        trail_before.iter().map(|e| &e.verb).collect::<Vec<_>>()
    );

    // Run the sweep. It should find the row, re-attempt corpus delete, and seal.
    let sweep_now = NOW2 + 1;
    let result = coord
        .run_expunge_integrity_sweep(&h, sweep_now)
        .expect("sweep must not fail fatally");

    assert_eq!(
        result.remediated_count, 1,
        "sweep must remediate exactly one crash-window row; got {:?}",
        result
    );
    assert_eq!(
        result.orphaned_count, 0,
        "no rows should remain un-remediated; got {:?}",
        result
    );
    assert!(
        result.per_row_errors.is_empty(),
        "no per-row errors expected; got {:?}",
        result.per_row_errors
    );

    // Verify: audit trail now has exactly one expungeOrphan event.
    let estate = coord.estate_for(&h).expect("estate after sweep");
    let trail_after = estate.audit_trail(&drawer.id).expect("audit_trail after sweep");
    let orphan_count = trail_after.iter().filter(|e| e.verb == "expungeOrphan").count();
    assert_eq!(
        orphan_count, 1,
        "exactly one expungeOrphan audit must exist after sweep; trail verbs: {:?}",
        trail_after.iter().map(|e| &e.verb).collect::<Vec<_>>()
    );

    // Verify: corpus no longer recalls the drawer after the sweep re-deleted it.
    let chunks_after = corpus
        .recall("sweep test content", 10, sweep_now)
        .expect("corpus recall after sweep");
    let vector_survived = chunks_after
        .iter()
        .any(|sc| sc.chunk.source_id == drawer.id);
    assert!(
        !vector_survived,
        "corpus must not recall the drawer after the sweep re-attempted the delete"
    );
}

// ---------------------------------------------------------------------------
// S2: no-op — all tombstoned rows already have audits
// ---------------------------------------------------------------------------

/// After a successful full expunge (which seals the "tombstone" success
/// audit), the sweep must be a no-op: zero remediated, zero orphaned, zero
/// errors. No false remediation on a healthy estate.
#[test]
fn s2_sweep_is_noop_when_all_tombstoned_rows_have_audits() {
    let (mut coord, h) = open_one();

    let corpus = make_corpus();
    let drawer = coord
        .capture(&h, cap_frame("sweep noop probe"), NOW)
        .expect("capture");
    corpus.ingest(&drawer.content, &drawer.id, NOW).expect("ingest");
    coord.register_corpus(&h, corpus);

    // Full expunge via GLK coordinator — seals the "tombstone" success audit.
    coord
        .expunge(&h, &drawer.id, "full expunge for noop test", true, NOW2)
        .expect("expunge");

    // Run the sweep. Must find nothing to remediate.
    let result = coord
        .run_expunge_integrity_sweep(&h, NOW2 + 1)
        .expect("sweep must not fail fatally");

    assert_eq!(
        result,
        ExpungeIntegritySweepResult::default(),
        "sweep must be a no-op when all tombstoned rows have audits; got {:?}",
        result
    );
}

// ---------------------------------------------------------------------------
// S3: locusOnly crash-window — no Corpus or VectorStore registered
// ---------------------------------------------------------------------------

/// Seeds a crash-window tombstoned row on a locusOnly estate (no Corpus,
/// no VectorStore registered). The sweep finds the row, the re-delete step
/// is a no-op (nothing to delete from — no cross-kit stores registered),
/// and the row is sealed with a synthetic expungeOrphan audit.
///
/// The audit gap is closed (remediated_count == 1) even though no vector
/// embedding was ever written for this row. This mirrors the happy-path
/// locusOnly expunge: it succeeds without attempting a cross-kit delete.
#[test]
fn s3_sweep_locusonly_closes_audit_gap_with_no_vector_store() {
    let (coord, h) = open_one();

    // No Corpus or VectorStore registered — locusOnly estate.
    let row_id = seed_crash_window(&coord, &h, "s3 locus-only crash window");

    // Run sweep on locusOnly estate.
    let result = coord
        .run_expunge_integrity_sweep(&h, NOW2 + 1)
        .expect("sweep must not fail fatally");

    // No corpus/VectorStore → re-delete is a no-op → closure returns Ok(())
    // → remediated_count is incremented (the audit gap is closed).
    assert_eq!(
        result.remediated_count, 1,
        "locusOnly sweep must close the audit gap (remediated_count == 1); got {:?}",
        result
    );
    assert_eq!(
        result.orphaned_count, 0,
        "orphaned_count must be zero for locusOnly estate; got {:?}",
        result
    );
    assert!(
        result.per_row_errors.is_empty(),
        "no per-row errors expected for locusOnly sweep; got {:?}",
        result.per_row_errors
    );

    // Verify: audit trail now has an expungeOrphan event.
    let estate = coord.estate_for(&h).expect("estate after sweep");
    let trail = estate.audit_trail(&row_id).expect("audit_trail after sweep");
    let orphan_count = trail.iter().filter(|e| e.verb == "expungeOrphan").count();
    assert_eq!(
        orphan_count, 1,
        "exactly one expungeOrphan audit must exist after locusOnly sweep; trail verbs: {:?}",
        trail.iter().map(|e| &e.verb).collect::<Vec<_>>()
    );
}
