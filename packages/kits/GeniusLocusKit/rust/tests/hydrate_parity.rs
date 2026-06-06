// hydrate_parity.rs — GLK hydrate round-trip conformance tests (Rust port).
//
// Contract: mirrors HydrateRoundTripTests.swift in the Swift test suite.
//
// Two tests:
//   1. hydrate_round_trip_drawers_and_kg_facts
//      Build a non-trivial GLK estate in-memory (drawers + KGFacts).
//      Flush to SQLite via glk_flush. Open a FRESH in-memory GLK estate
//      hydrating from SQLite. Assert logical equivalence — same drawer
//      count, same contents, same KGFact triples.
//
//   2. hydrate_round_trip_matrix_tier_equivalence
//      After hydration, assert that the MatrixTier's live_row_count matches,
//      last_hlc is non-zero, and temporal_watermark_hlc is non-zero.
//      A zero temporal_watermark_hlc means rebuild_temporal did NOT run —
//      a correctness bug in full_rebuild ordering.
//
// SQLite files are written to /tmp with unique names and cleaned up after
// each test via a Drop guard.
//
// Note on HLC round-trip: the SQLite backend has a known pre-existing
// pack/unpack asymmetry (F-HLC-01). These tests do NOT assert exact HLC
// column values through the SQLite→InMemory path; they assert counts and
// structural equivalence. This matches the Swift §9 correctness contract
// (logical equivalence, not byte-identity).

use std::sync::Arc;

use genius_locus_kit::{
    bridge_audit_event, glk_flush, open_hydrating, EstateCoordinator, MatrixTier,
};
use locus_kit::{
    drawer_operational::CaptureChannel,
    drawer_store_inmemory::InMemoryDrawerStore,
    estate::Estate,
    estate_types::{LatticeAnchor, OwnerCredentials},
    filter::{Filter, HydrationLevel, Ordering, RecallFrame},
    frames::CaptureFrame,
};
use genius_locus_kit::audit::UnifiedAuditLog;
use persistence_kit::{
    inmemory::InMemoryStorage,
    BackendConfiguration, EstateConfiguration, SqliteStorage,
};
use substrate_types::hlc::HLC;
use uuid::Uuid;

// Fixed epoch-seconds timestamp for deterministic tests.
// Never call std::time inside a test — all time enters through `now`.
const NOW: i64 = 1_750_000_000;

// MARK: - Helpers

/// Build a fresh Arc<InMemoryStorage> with a new estate UUID.
/// Not pre-opened with any schema — GLK lifecycle handles that.
fn make_in_memory() -> Arc<InMemoryStorage> {
    Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()))
}

/// Build a SqliteStorage at a unique temp path.
/// Returns (storage, path) so the caller can clean up after the test.
fn make_sqlite() -> (SqliteStorage, std::path::PathBuf) {
    let path = std::env::temp_dir()
        .join(format!("glk-hydrate-parity-{}.sqlite", Uuid::new_v4()));
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string_lossy().into_owned(),
            busy_timeout_secs: 5.0,
        },
    );
    let storage = SqliteStorage::new(config).expect("open sqlite for hydrate parity test");
    (storage, path)
}

/// Remove SQLite file and WAL/SHM sidecars.
fn cleanup_sqlite(path: &std::path::Path) {
    let _ = std::fs::remove_file(path);
    // WAL and SHM are appended to the base path
    let _ = std::fs::remove_file(format!("{}-wal", path.display()));
    let _ = std::fs::remove_file(format!("{}-shm", path.display()));
}

/// Drop guard that removes SQLite files on scope exit (even on panic).
struct SqliteCleanup(std::path::PathBuf);
impl Drop for SqliteCleanup {
    fn drop(&mut self) {
        cleanup_sqlite(&self.0);
    }
}

/// Build an unconfirmed RecallFrame with structured hydration and a
/// cap of 20 rows. Mirrors the Swift test helper.
fn unconfirmed_frame() -> RecallFrame {
    let mut f = RecallFrame::new(vec![Filter::Unconfirmed]);
    f.hydration_level = HydrationLevel::Structured;
    f.ordering = Ordering::ByCaptureTimeDesc;
    f.limit = Some(20);
    f
}

/// Open a LocusKit estate directly on `storage` and register it in a
/// fresh `EstateCoordinator`. Returns (coordinator, handle).
///
/// Uses `open_estate_directly` (the hydration path's registration method)
/// so the estate is backed by the given storage without a second schema open.
fn open_estate_on_storage(
    storage: Arc<InMemoryStorage>,
    owner: OwnerCredentials,
) -> (EstateCoordinator, genius_locus_kit::EstateHandle) {
    let store = Arc::new(
        InMemoryDrawerStore::with_storage(storage, NOW, None)
            .expect("InMemoryDrawerStore::with_storage"),
    );
    let estate = Estate::open(store, owner).expect("Estate::open");
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open_estate_directly(estate, 0, i64::MAX)
        .expect("open_estate_directly");
    (coord, handle)
}

/// Build a CaptureFrame using locus_kit types throughout.
fn make_capture_frame(content: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "hydrate-rt",
        LatticeAnchor::udc("000.000"),
        "hydrate-test",
        "test-model-v1",
    )
}

// MARK: - Test 1: Drawers + KGFacts recall equivalence

/// Build a non-trivial in-memory estate, flush to SQLite, hydrate back into a
/// fresh in-memory backend, assert that recall returns the same drawers and
/// KGFacts.
///
/// Equivalence contract:
///   - Drawer count matches source.
///   - All source drawer contents appear in hydrated recall.
///   - KGFact count matches.
///   - KGFact triples (subject|predicate|object) match exactly.
#[test]
fn hydrate_round_trip_drawers_and_kg_facts() {
    let (sqlite, sqlite_path) = make_sqlite();
    let _guard = SqliteCleanup(sqlite_path.clone());

    let owner = OwnerCredentials::new("owner-hydrate-rt-1");

    // ── Build source estate ────────────────────────────────────────────
    let source_storage = make_in_memory();
    let (source_coord, source_handle) =
        open_estate_on_storage(source_storage.clone(), owner.clone());

    // Capture three drawers with deterministic content.
    let contents = [
        "rust GLK hydrate parity test alpha",
        "bitmap accumulate recall round-trip beta",
        "vector ANN hamming logical equivalence gamma",
    ];
    let mut last_drawer_id = String::new();
    for content in &contents {
        let drawer = source_coord
            .capture(&source_handle, make_capture_frame(content), NOW)
            .expect("capture");
        last_drawer_id = drawer.id.clone();
    }

    // Add two KGFacts linked to the last captured drawer.
    // sourceDrawerID must not be empty — the LocusKit estate enforces this.
    source_coord
        .add_kg_fact(&source_handle, "GLK", "hydrates", "estate", &last_drawer_id, NOW)
        .expect("add_kg_fact 1");
    source_coord
        .add_kg_fact(&source_handle, "MatrixTier", "rebuilds", "fromAuditLog", &last_drawer_id, NOW)
        .expect("add_kg_fact 2");

    // Recall baseline from source estate.
    let source_drawers = source_coord
        .recall(&source_handle, unconfirmed_frame(), NOW)
        .expect("source recall");
    let source_kg_facts = source_coord
        .recall_kg_facts(&source_handle)
        .expect("source recall_kg_facts");

    // ── Flush to SQLite ────────────────────────────────────────────────
    // glk_flush opens both backends with the composite GLK schema before
    // calling replication::flush, satisfying the schema gate on both sides.
    glk_flush(source_storage.as_ref(), &sqlite)
        .expect("glk_flush source → sqlite");

    // ── Hydrate into fresh in-memory ───────────────────────────────────
    let fresh_storage = make_in_memory();
    let hydrated = open_hydrating(fresh_storage, &sqlite, owner.clone(), NOW)
        .expect("open_hydrating");

    // Register the hydrated estate in a coordinator to use recall.
    let mut hydrated_coord = EstateCoordinator::new();
    let hydrated_handle = hydrated_coord
        .open_estate_directly(hydrated.estate, 0, i64::MAX)
        .expect("register hydrated estate");

    // ── Assert logical equivalence ─────────────────────────────────────

    let hydrated_drawers = hydrated_coord
        .recall(&hydrated_handle, unconfirmed_frame(), NOW)
        .expect("hydrated recall");
    let hydrated_kg_facts = hydrated_coord
        .recall_kg_facts(&hydrated_handle)
        .expect("hydrated recall_kg_facts");

    // Drawer count.
    assert_eq!(
        hydrated_drawers.len(),
        source_drawers.len(),
        "drawer count mismatch after hydration: source={} hydrated={}",
        source_drawers.len(),
        hydrated_drawers.len(),
    );

    // All source contents present in hydrated recall.
    let hydrated_contents: std::collections::HashSet<&str> =
        hydrated_drawers.iter().map(|d| d.content.as_str()).collect();
    for content in &contents {
        assert!(
            hydrated_contents.contains(*content),
            "content missing after hydration: {content}"
        );
    }

    // KGFact count.
    assert_eq!(
        hydrated_kg_facts.len(),
        source_kg_facts.len(),
        "KGFact count mismatch after hydration: source={} hydrated={}",
        source_kg_facts.len(),
        hydrated_kg_facts.len(),
    );

    // KGFact triples (subject|predicate|object).
    let source_triples: std::collections::HashSet<String> = source_kg_facts
        .iter()
        .map(|f| format!("{}|{}|{}", f.subject, f.predicate, f.object))
        .collect();
    let hydrated_triples: std::collections::HashSet<String> = hydrated_kg_facts
        .iter()
        .map(|f| format!("{}|{}|{}", f.subject, f.predicate, f.object))
        .collect();
    assert_eq!(
        hydrated_triples, source_triples,
        "KGFact triples mismatch after hydration"
    );
}

// MARK: - Test 2: Matrix tier state equivalence

/// Assert that the matrix tier built from a hydrated estate has:
///   - live_row_count > 0 (rows were indexed)
///   - last_hlc != HLC::ZERO (audit events were processed)
///   - temporal_watermark_hlc != HLC::ZERO (rebuild_temporal ran)
///
/// A zero temporal_watermark_hlc indicates that MatrixTier::full_rebuild
/// only ran rebuild() (pass 1) but not rebuild_temporal() (pass 2) —
/// a correctness regression.
#[test]
fn hydrate_round_trip_matrix_tier_equivalence() {
    let (sqlite, sqlite_path) = make_sqlite();
    let _guard = SqliteCleanup(sqlite_path.clone());

    let owner = OwnerCredentials::new("owner-hydrate-rt-2");

    // ── Build source estate with 4 captures ───────────────────────────
    let source_storage = make_in_memory();
    let (source_coord, source_handle) =
        open_estate_on_storage(source_storage.clone(), owner.clone());

    for i in 0..4 {
        source_coord
            .capture(
                &source_handle,
                make_capture_frame(&format!("matrix tier parity test content row {i}")),
                // Increment `now` per capture so each gets a distinct HLC tick.
                NOW + i,
            )
            .expect("capture");
    }

    // Build source tier by feeding its audit log, for comparison.
    let source_drawers = source_coord
        .all_drawers(&source_handle)
        .expect("all_drawers");
    let mut source_log = UnifiedAuditLog::new();
    {
        let estate_ref = source_coord
            .estate_for(&source_handle)
            .expect("estate_for");
        for drawer in &source_drawers {
            let events = estate_ref.audit_trail(&drawer.id).expect("audit_trail");
            for event in &events {
                for entry in bridge_audit_event(event) {
                    source_log.add(entry);
                }
            }
        }
    }
    let source_tier = MatrixTier::full_rebuild(&source_log);

    // ── Flush to SQLite ────────────────────────────────────────────────
    glk_flush(source_storage.as_ref(), &sqlite)
        .expect("glk_flush source → sqlite");

    // ── Hydrate into fresh in-memory ───────────────────────────────────
    let fresh_storage = make_in_memory();
    let hydrated = open_hydrating(fresh_storage, &sqlite, owner.clone(), NOW)
        .expect("open_hydrating");

    let hydrated_tier = hydrated.matrix_tier;

    // ── Assert matrix tier equivalence ────────────────────────────────

    // live_row_count: both saw 4 captures.
    assert_eq!(
        hydrated_tier.live_row_count, source_tier.live_row_count,
        "live_row_count mismatch after hydration: source={} hydrated={}",
        source_tier.live_row_count, hydrated_tier.live_row_count,
    );

    // last_hlc must be non-zero on the source.
    // HLC::ZERO is the "no events processed" sentinel (MatrixTier default).
    assert_ne!(
        source_tier.last_hlc,
        HLC::ZERO,
        "source tier last_hlc should be non-zero after 4 captures"
    );

    // last_hlc must be non-zero on the hydrated tier after audit log rebuild.
    assert_ne!(
        hydrated_tier.last_hlc,
        HLC::ZERO,
        "hydrated tier last_hlc should be non-zero after rebuild from audit log"
    );

    // temporal_watermark_hlc must be non-zero on the hydrated tier.
    // This validates that full_rebuild ran BOTH passes:
    //   Pass 1 (rebuild)          → sets last_hlc, live_row_count, F/O/C
    //   Pass 2 (rebuild_temporal) → sets temporal_watermark_hlc, T
    // A zero value means pass 2 was skipped — that is a bug.
    assert_ne!(
        hydrated_tier.temporal_watermark_hlc,
        HLC::ZERO,
        "hydrated tier temporal_watermark_hlc must be non-zero; \
         a zero value means MatrixTier::full_rebuild skipped rebuild_temporal (pass 2)"
    );
}
