//! A.2 verification fixture for the 1.0.x → 1.1.x distillation storage migration.
//! Rust twin of Swift `DistillationStorageMigrationTests.swift`.
//!
//! Builds a 1.0.x-shaped estate in-process and verifies acceptance criterion 13.8:
//!
//!   Fixture shape (1.0.x estate):
//!     sourceA — normal drawer, room "research" (addedBy "researcher")
//!     sourceB — normal drawer, room "research" (addedBy "researcher")
//!     factoidA → sourceA via _distilled_from (exactly 1 tunnel) + lane entry
//!     factoidB             (0 tunnels, lane entry exists — ambiguous provenance: drop)
//!     factoidC → sourceA, sourceB (2 tunnels — ambiguous provenance: drop)
//!     orphanEntry — lane entry for a UUID that has never existed in drawers
//!     shortItem — normal drawer, no factoid, no tunnel, no lane entry
//!
//!   Post-migration expected state:
//!     - 0 drawers with addedBy = "distillation-daemon"
//!     - 0 tunnels with label = "_distilled_from"
//!     - lane entry for sourceA.id exists, keyed by sourceA.id (re-keyed from factoidA)
//!     - no lane entry for factoidA, factoidB, factoidC, or orphanID
//!     - drawers table has distilled, distilled_pipeline_version,
//!       distilled_token_count, distilled_at columns (all NULL)
//!     - shortItem drawer is untouched

use std::collections::BTreeMap;
use std::sync::Arc;

use genius_locus_kit::EstateCoordinator;
use genius_locus_kit_migrations::{
    run_distillation_data_migration, DistillationStorageMigrationReport,
};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::CaptureFrame;
use persistence_kit::{Column, Storage, StoragePredicate, TypedValue};
use vectorkit::VectorStore;

const NOW: i64 = 1_750_000_000_000; // millis

// MARK: - Fixture helpers

fn capture_frame(content: &str, room: &str, added_by: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        room,
        LatticeAnchor::udc("004"),
        added_by,
        "test-v1",
    )
}

/// Minimal tunnel row values for a _distilled_from tunnel.
/// The migration reads only `sourceDrawerId`, `targetDrawerId`, and `label`.
/// Other TEXT-required fields are set to placeholder values.
fn distilled_from_tunnel_row(
    factoid_id: &str,
    source_id: &str,
) -> BTreeMap<String, TypedValue> {
    let mut row = BTreeMap::new();
    row.insert(
        "id".to_string(),
        TypedValue::Text(format!("tunnel-{factoid_id}-{source_id}")),
    );
    row.insert(
        "sourceWing".to_string(),
        TypedValue::Text("Agentic Memory".to_string()),
    );
    row.insert(
        "sourceRoom".to_string(),
        TypedValue::Text("_distilled".to_string()),
    );
    row.insert(
        "sourceDrawerId".to_string(),
        TypedValue::Text(factoid_id.to_string()),
    );
    row.insert(
        "targetWing".to_string(),
        TypedValue::Text("Agentic Memory".to_string()),
    );
    row.insert(
        "targetRoom".to_string(),
        TypedValue::Text("research".to_string()),
    );
    row.insert(
        "targetDrawerId".to_string(),
        TypedValue::Text(source_id.to_string()),
    );
    row.insert(
        "label".to_string(),
        TypedValue::Text("_distilled_from".to_string()),
    );
    row.insert(
        "addedBy".to_string(),
        TypedValue::Text("distillation-daemon".to_string()),
    );
    // filedAt: Timestamp is stored as TEXT (ISO-8601) in SQLite via
    // persistence_kit. Using TypedValue::Timestamp (epoch millis) which
    // the backend serialises to ISO-8601 internally.
    row.insert("filedAt".to_string(), TypedValue::Timestamp(NOW));
    row
}

/// Minimal vector lane row for the distillation-features-v1 model.
fn lane_vector_row(item_id: &str) -> BTreeMap<String, TypedValue> {
    let mut row = BTreeMap::new();
    row.insert(
        "id".to_string(),
        TypedValue::Uuid(uuid::Uuid::new_v4()),
    );
    row.insert(
        "item_id".to_string(),
        TypedValue::Text(item_id.to_string()),
    );
    row.insert("vector_index".to_string(), TypedValue::Int(0));
    row.insert(
        "model_id".to_string(),
        TypedValue::Text("distillation-features-v1".to_string()),
    );
    row.insert(
        "model_version".to_string(),
        TypedValue::Text("test-v1".to_string()),
    );
    row.insert("kind".to_string(), TypedValue::Int(0));
    row.insert("dim".to_string(), TypedValue::Int(256));
    // 32-byte zero blob (minimal binary vector, dim 256 = 256/8 bytes)
    row.insert("payload".to_string(), TypedValue::Blob(vec![0u8; 32]));
    row.insert("filed_at".to_string(), TypedValue::Timestamp(NOW));
    row
}

/// Build the 1.0.x fixture estate and return the storage and key drawer IDs.
///
/// The estate is backed by InMemoryDrawerStore. On return the storage has:
///   - drawers: sourceA, sourceB, factoidA, factoidB, factoidC, shortItem
///   - tunnels: factoidA→sourceA (×1), factoidC→sourceA (×1), factoidC→sourceB (×1)
///   - vectors (distillation-features-v1 lane): factoidA, factoidB, factoidC, orphan
struct Fixture {
    storage: Arc<dyn Storage>,
    source_a_id: String,
    source_b_id: String,
    factoid_a_id: String,
    factoid_b_id: String,
    factoid_c_id: String,
    short_item_id: String,
    orphan_id: String,
}

fn build_fixture() -> Fixture {
    let store = Arc::new(InMemoryDrawerStore::new(NOW, None).expect("inmemory store"));
    let storage: Arc<dyn Storage> = store
        .storage()
        .expect("InMemoryDrawerStore exposes storage");
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(
            Arc::clone(&store) as Arc<dyn locus_kit::drawer_store::DrawerStore>,
            OwnerCredentials::new("dsm-owner"),
            0,
            100,
        )
        .expect("open estate");

    // Source drawers — normal content, never distilled themselves.
    let source_a = coord
        .capture(&handle, capture_frame("Source content A.", "research", "researcher"), NOW)
        .expect("capture sourceA");
    let source_b = coord
        .capture(&handle, capture_frame("Source content B.", "research", "researcher"), NOW)
        .expect("capture sourceB");

    // Factoid drawers — retired distilled-view rows (addedBy "distillation-daemon").
    let factoid_a = coord
        .capture(
            &handle,
            capture_frame("Distilled insight from source A.", "_distilled", "distillation-daemon"),
            NOW,
        )
        .expect("capture factoidA");
    let factoid_b = coord
        .capture(
            &handle,
            capture_frame("Distilled insight with no provenance tunnel.", "_distilled", "distillation-daemon"),
            NOW,
        )
        .expect("capture factoidB");
    let factoid_c = coord
        .capture(
            &handle,
            capture_frame("Distilled insight with ambiguous provenance.", "_distilled", "distillation-daemon"),
            NOW,
        )
        .expect("capture factoidC");

    // Short item — never distilled, should survive migration intact.
    let short_item = coord
        .capture(
            &handle,
            capture_frame("Short note — below distillation threshold.", "short", "user"),
            NOW,
        )
        .expect("capture shortItem");

    // Register VectorKit schema so the vectors table exists before we insert.
    // The migration also calls this idempotently at the start of step (c).
    storage
        .migrate(&VectorStore::schema_declaration())
        .expect("register vectors schema");

    let row_store = storage.row_store();

    // Insert _distilled_from tunnels:
    //   factoidA → sourceA (exactly 1 → re-key)
    //   factoidB   has 0 tunnels (ambiguous → drop)
    //   factoidC → sourceA + sourceB (2 tunnels → ambiguous → drop)
    row_store
        .insert("tunnels", distilled_from_tunnel_row(&factoid_a.id, &source_a.id))
        .expect("insert tunnel factoidA→sourceA");
    row_store
        .insert("tunnels", distilled_from_tunnel_row(&factoid_c.id, &source_a.id))
        .expect("insert tunnel factoidC→sourceA");
    row_store
        .insert("tunnels", distilled_from_tunnel_row(&factoid_c.id, &source_b.id))
        .expect("insert tunnel factoidC→sourceB");

    // Insert distillation-features-v1 lane entries keyed by factoid IDs.
    row_store
        .insert("vectors", lane_vector_row(&factoid_a.id))
        .expect("insert lane factoidA");
    row_store
        .insert("vectors", lane_vector_row(&factoid_b.id))
        .expect("insert lane factoidB");
    row_store
        .insert("vectors", lane_vector_row(&factoid_c.id))
        .expect("insert lane factoidC");

    // Orphaned lane entry — a UUID that has NEVER been a drawer.
    let orphan_id = uuid::Uuid::new_v4().to_string();
    row_store
        .insert("vectors", lane_vector_row(&orphan_id))
        .expect("insert orphan lane entry");

    Fixture {
        storage,
        source_a_id: source_a.id,
        source_b_id: source_b.id,
        factoid_a_id: factoid_a.id,
        factoid_b_id: factoid_b.id,
        factoid_c_id: factoid_c.id,
        short_item_id: short_item.id,
        orphan_id,
    }
}

// MARK: - Tests

/// Full A.1 migration acceptance test — acceptance criterion 13.8.
///
///   - factoidA lane entry is re-keyed to sourceA.id
///   - factoidB, factoidC, orphan entries are deleted
///   - all three factoid drawers are deleted
///   - all _distilled_from tunnels are deleted
///   - four representation columns are added to drawers (all NULL)
///   - shortItem drawer is untouched
#[test]
fn migration_re_keys_and_drops_correctly() {
    let fix = build_fixture();

    let report = run_distillation_data_migration(&fix.storage)
        .expect("migration must succeed");

    // ── Verify report counts ──────────────────────────────────────────
    assert_eq!(
        report.factoid_drawer_count, 3,
        "three factoid drawers (A, B, C) must be deleted"
    );
    assert_eq!(
        report.tunnel_count, 3,
        "three _distilled_from tunnels must be deleted"
    );
    assert_eq!(
        report.re_keyed_lane_count, 1,
        "exactly one lane entry must be re-keyed (factoidA → sourceA)"
    );
    // dropped = factoidB (0 tunnels) + factoidC (2 tunnels) + orphan = 3
    assert_eq!(
        report.dropped_lane_count, 3,
        "three lane entries must be dropped (factoidB, factoidC, orphan)"
    );

    let row_store = fix.storage.row_store();

    // ── Verify no factoid drawers remain ─────────────────────────────
    let remaining_factoids = row_store
        .query(
            "drawers",
            Some(&StoragePredicate::Eq(
                Column::new("drawers", "addedBy"),
                TypedValue::Text("distillation-daemon".to_string()),
            )),
            &[],
            None,
            None,
        )
        .expect("query factoid drawers");
    assert!(
        remaining_factoids.is_empty(),
        "no factoid drawers must remain after migration; found {}",
        remaining_factoids.len()
    );

    // ── Verify no _distilled_from tunnels remain ──────────────────────
    let remaining_tunnels = row_store
        .query(
            "tunnels",
            Some(&StoragePredicate::Eq(
                Column::new("tunnels", "label"),
                TypedValue::Text("_distilled_from".to_string()),
            )),
            &[],
            None,
            None,
        )
        .expect("query _distilled_from tunnels");
    assert!(
        remaining_tunnels.is_empty(),
        "no _distilled_from tunnels must remain after migration; found {}",
        remaining_tunnels.len()
    );

    // ── Verify re-keyed lane entry exists for sourceA ─────────────────
    let source_a_lane = row_store
        .query(
            "vectors",
            Some(&StoragePredicate::And(vec![
                StoragePredicate::Eq(
                    Column::new("vectors", "item_id"),
                    TypedValue::Text(fix.source_a_id.clone()),
                ),
                StoragePredicate::Eq(
                    Column::new("vectors", "model_id"),
                    TypedValue::Text("distillation-features-v1".to_string()),
                ),
            ])),
            &[],
            None,
            None,
        )
        .expect("query sourceA lane");
    assert_eq!(
        source_a_lane.len(), 1,
        "sourceA must have exactly 1 distillation-features-v1 lane entry after re-key"
    );

    // ── Verify all factoid and orphan lane entries are gone ───────────
    for (label, id) in [
        ("factoidA", fix.factoid_a_id.as_str()),
        ("factoidB", fix.factoid_b_id.as_str()),
        ("factoidC", fix.factoid_c_id.as_str()),
        ("orphan",   fix.orphan_id.as_str()),
    ] {
        let rows = row_store
            .query(
                "vectors",
                Some(&StoragePredicate::And(vec![
                    StoragePredicate::Eq(
                        Column::new("vectors", "item_id"),
                        TypedValue::Text(id.to_string()),
                    ),
                    StoragePredicate::Eq(
                        Column::new("vectors", "model_id"),
                        TypedValue::Text("distillation-features-v1".to_string()),
                    ),
                ])),
                &[],
                None,
                None,
            )
            .expect("query lane entry");
        assert!(
            rows.is_empty(),
            "{label} lane entry must be deleted after migration"
        );
    }

    // ── Verify four representation columns exist and are NULL ─────────
    // Query the shortItem row — it was never distilled, so its
    // representation columns must be NULL (the column default).
    let short_rows = row_store
        .query(
            "drawers",
            Some(&StoragePredicate::Eq(
                Column::new("drawers", "id"),
                TypedValue::Text(fix.short_item_id.clone()),
            )),
            &[],
            None,
            None,
        )
        .expect("query shortItem");
    let short_row = short_rows.first().expect("shortItem drawer must still exist after migration");

    for col in &[
        "distilled",
        "distilled_pipeline_version",
        "distilled_token_count",
        "distilled_at",
    ] {
        let val = short_row.get(col);
        assert!(
            val.is_none() || val == Some(&TypedValue::Null),
            "drawers.{col} must be NULL on shortItem after migration (step e)"
        );
    }

    // ── Verify source drawers survived migration intact ───────────────
    for (label, id) in [
        ("sourceA", fix.source_a_id.as_str()),
        ("sourceB", fix.source_b_id.as_str()),
    ] {
        let rows = row_store
            .query(
                "drawers",
                Some(&StoragePredicate::Eq(
                    Column::new("drawers", "id"),
                    TypedValue::Text(id.to_string()),
                )),
                &[],
                None,
                None,
            )
            .expect("query source drawer");
        assert!(
            !rows.is_empty(),
            "{label} drawer must survive the migration intact"
        );
    }

    // ── Verify shortItem drawer survived migration intact ─────────────
    assert!(
        !short_rows.is_empty(),
        "shortItem drawer must survive the migration intact"
    );
}

/// Verify that running the migration on a fresh estate (no factoids,
/// no tunnels) produces a zero-work report and leaves the estate unchanged.
#[test]
fn fresh_estate_produces_zero_work_report() {
    let store = Arc::new(InMemoryDrawerStore::new(NOW, None).expect("inmemory"));
    let storage: Arc<dyn Storage> = store.storage().expect("storage");
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(
            Arc::clone(&store) as Arc<dyn locus_kit::drawer_store::DrawerStore>,
            OwnerCredentials::new("dsm-fresh"),
            0,
            100,
        )
        .expect("open");

    // Capture a regular drawer — should not be touched.
    coord
        .capture(
            &handle,
            capture_frame("A plain memory on a fresh estate.", "notes", "user"),
            NOW,
        )
        .expect("capture plain drawer");

    let report = run_distillation_data_migration(&storage).expect("migration");

    assert_eq!(report.factoid_drawer_count, 0, "fresh estate: no factoid drawers");
    assert_eq!(report.tunnel_count, 0, "fresh estate: no _distilled_from tunnels");
    assert_eq!(report.re_keyed_lane_count, 0, "fresh estate: no lane entries to re-key");
    assert_eq!(report.dropped_lane_count, 0, "fresh estate: no lane entries to drop");
}

/// Verify idempotency: running the migration twice produces the same
/// final state (second run is a no-op on an already-migrated estate).
#[test]
fn migration_is_idempotent() {
    let fix = build_fixture();

    // First run.
    let first = run_distillation_data_migration(&fix.storage).expect("first migration");
    assert_eq!(first.factoid_drawer_count, 3);
    assert_eq!(first.re_keyed_lane_count, 1);

    // Second run — estate already clean, so all counts must be zero.
    let second = run_distillation_data_migration(&fix.storage).expect("second migration");
    assert_eq!(
        second,
        DistillationStorageMigrationReport {
            factoid_drawer_count: 0,
            tunnel_count: 0,
            re_keyed_lane_count: 0,
            dropped_lane_count: 0,
        },
        "second migration run must be a no-op"
    );

    // sourceA lane entry must still be there after the second run.
    let source_a_lane = fix
        .storage
        .row_store()
        .query(
            "vectors",
            Some(&StoragePredicate::And(vec![
                StoragePredicate::Eq(
                    Column::new("vectors", "item_id"),
                    TypedValue::Text(fix.source_a_id.clone()),
                ),
                StoragePredicate::Eq(
                    Column::new("vectors", "model_id"),
                    TypedValue::Text("distillation-features-v1".to_string()),
                ),
            ])),
            &[],
            None,
            None,
        )
        .expect("query sourceA lane after second run");
    assert_eq!(
        source_a_lane.len(), 1,
        "sourceA lane entry must survive a second migration run"
    );
}
