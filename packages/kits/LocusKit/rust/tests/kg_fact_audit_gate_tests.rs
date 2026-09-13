//! Gate tests — `withdraw_kg_fact` routes through `audit_gate::admit`
//! (verb Retract, active → withdrawn) and writes a sealed audit row.
//!
//! ## Four cases, two backends for Cases 1 and 3
//!
//! Case 1 (InMemory + SQLite): NON-UUID id, ANCHORED — exercises the SHA-256
//!   branch of `deterministic_row_key` and the `udc_qid` lattice-anchor branch.
//!   `Uuid::parse_str(FACT_ID_NON_UUID).is_err()` is asserted in each test body
//!   so a reader can see the SHA-256 branch is the one under test. A regression
//!   in either branch makes this RED.
//!
//! Case 2 (InMemory): UUID id — exercises the UUID passthrough branch of
//!   `deterministic_row_key`. row_id must equal the original UUID unchanged.
//!
//! Case 3 (InMemory + SQLite): UNANCHORED — empty `source_drawer_id` produces
//!   a null anchor; both `udc_code` and `qid_pointer` must be 0.
//!
//! Case 4 (InMemory): Anchor drawer absent — `source_drawer_id` names a drawer
//!   not in the estate; retirement must succeed with a null anchor rather than
//!   panicking or returning an error.
//!
//! Validation (InMemory): empty `changed_by` is rejected by the input guard.

use locus_kit::drawer::Drawer;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
use locus_kit::error::LocusKitError;
use locus_kit::kg_fact::KGFact;
use persistence_kit::row_key_derivation::deterministic_row_key;
use substrate_types::AuditEvent;
use substrate_types::LatticeAnchor;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Timestamp for store opens and mutations. Epoch MILLISECONDS, matching
/// every production caller (the v2 admission passes `a.now_millis`). The HLC
/// treats the value as an opaque i64, so the unit matters for parity with the
/// shipped callers rather than for the assertions here.
const NOW: i64 = 1_700_000_000;

/// A fact id that is NOT a valid UUID string — exercises the SHA-256 branch
/// of `deterministic_row_key`. Uuid::parse_str on this must return Err
/// (asserted in each Case 1 test body so the SHA-256 branch is visible).
const FACT_ID_NON_UUID: &str = "fact-not-a-uuid-2";

/// A fact id that IS a valid UUID string — exercises the UUID passthrough
/// branch of `deterministic_row_key`.
const FACT_ID_UUID: &str = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

/// The actor (changed_by) threaded through to the audit row.
const ACTOR: &str = "kgfact-audit-gate-test";

/// The reason threaded through to the audit row.
const REASON: &str = "gate-test-retirement";

/// UDC code for the anchored source drawer used in Cases 1 and 4.
const DRAWER_UDC: &str = "gate-test-udc-001";

/// Wikidata QID for the anchored source drawer used in Cases 1 and 4.
const DRAWER_QID: &str = "Q99999";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Open a fresh InMemoryDrawerStore for each test.
fn open_inmemory() -> InMemoryDrawerStore {
    InMemoryDrawerStore::new(NOW, None).unwrap()
}

/// RAII guard that deletes the SQLite file (and WAL/SHM siblings) on drop.
struct TempDb {
    path: String,
}

impl TempDb {
    fn new() -> Self {
        let name = format!("lk_kgfact_audit_gate_{}.db", Uuid::new_v4().simple());
        let path = std::env::temp_dir()
            .join(name)
            .to_string_lossy()
            .into_owned();
        TempDb { path }
    }

    fn path(&self) -> &str {
        &self.path
    }
}

impl Drop for TempDb {
    fn drop(&mut self) {
        for suffix in &["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{}", self.path, suffix));
        }
    }
}

/// Open a fresh SQLite store at `path`.
fn open_sqlite(path: &str) -> SqliteDrawerStore {
    SqliteDrawerStore::from_path(path, NOW, None, 5.0).unwrap()
}

/// Insert an anchored source drawer (udc_code + wikidata_qid) into the store.
/// Uses the supplied id so the caller can reference it as source_drawer_id on a fact.
fn insert_anchored_drawer(store: &dyn DrawerStore, id: &str) {
    let mut d = Drawer::new(id, "anchor drawer content", "test-parent", "gate-test", NOW - 100, "test-model-v1");
    d.udc_code = DRAWER_UDC.to_string();
    d.wikidata_qid = Some(DRAWER_QID.to_string());
    store.add_drawer(&d, NOW).unwrap();
}

/// Assert all Case 1 fields on the audit event (shared by InMemory and SQLite).
/// Caller already verified events.len() == 1.
///
/// - row_id.0 must equal the SHA-256-derived UUID for FACT_ID_NON_UUID
/// - verb must be "retract"
/// - after_lattice_anchor must equal LatticeAnchor::udc_qid(DRAWER_UDC, DRAWER_QID)
/// - after_lattice_anchor.qid_pointer != 0 (confirms udc_qid branch, not null-anchor)
/// - reason == Some(REASON)
/// - actor == ACTOR
/// - after_bitmaps.0 bits 0-5 == 18 (State::Withdrawn)
fn assert_case1_event(event: &AuditEvent) {
    let expected_row_id = deterministic_row_key(FACT_ID_NON_UUID);
    assert_eq!(
        event.row_id.0, expected_row_id.as_u128(),
        "row_id must equal deterministic_row_key(FACT_ID_NON_UUID) — SHA-256 branch"
    );
    assert_eq!(
        event.verb, "retract",
        "verb must be 'retract' (RowVerb::Retract rawValue)"
    );
    let expected_anchor = LatticeAnchor::udc_qid(DRAWER_UDC, DRAWER_QID);
    assert_eq!(
        event.after_lattice_anchor.udc_code, expected_anchor.udc_code,
        "after_lattice_anchor.udc_code must equal udc_qid(DRAWER_UDC, DRAWER_QID).udc_code"
    );
    assert_eq!(
        event.after_lattice_anchor.qid_pointer, expected_anchor.qid_pointer,
        "after_lattice_anchor.qid_pointer must equal udc_qid anchor's qid_pointer"
    );
    assert_ne!(
        event.after_lattice_anchor.qid_pointer, 0,
        "qid_pointer must be non-zero for a drawer with a non-empty wikidata_qid — \
         confirms udc_qid branch, not null-anchor branch"
    );
    assert_eq!(
        event.reason.as_deref(),
        Some(REASON),
        "reason must be threaded through to the audit row"
    );
    assert_eq!(
        event.actor, ACTOR,
        "actor must equal the changed_by parameter"
    );
    let state_raw = event.after_bitmaps.0 & 0x3F;
    assert_eq!(
        state_raw, 18,
        "adjective bits 0-5 must equal State::Withdrawn raw value (18)"
    );
}

// ---------------------------------------------------------------------------
// Case 1: NON-UUID id, ANCHORED — InMemory
// ---------------------------------------------------------------------------

/// Case 1A — InMemory: a fact whose id is NOT a UUID string produces a
/// SHA-256-derived row_id; a fact linked to an anchored drawer produces a
/// non-null udc_qid lattice anchor on the emitted audit event.
#[test]
fn test_case1a_inmemory_non_uuid_id_anchored() {
    // Confirm the id is NOT a UUID — proves the SHA-256 branch is exercised.
    assert!(
        Uuid::parse_str(FACT_ID_NON_UUID).is_err(),
        "FACT_ID_NON_UUID must not be a valid UUID string — SHA-256 branch is the one under test"
    );

    let store = open_inmemory();
    let drawer_id = Uuid::new_v4().to_string();
    insert_anchored_drawer(&store, &drawer_id);

    let fact = KGFact::new(
        FACT_ID_NON_UUID.to_string(),
        "gate-test-subject".to_string(),
        "is_about".to_string(),
        "gate-test-object".to_string(),
        drawer_id.clone(),
        NOW - 100,
    );
    store.add_kg_fact(&fact).unwrap();
    store
        .withdraw_kg_fact(FACT_ID_NON_UUID, ACTOR, Some(REASON), NOW + 1)
        .expect("withdraw_kg_fact must succeed for a valid active fact (Case 1A)");

    let row_uuid = deterministic_row_key(FACT_ID_NON_UUID);
    let events = store.audit_events_for_row(&row_uuid.to_string()).unwrap();
    assert_eq!(
        events.len(), 1,
        "exactly one audit event must be written for the SHA-256-derived row key"
    );
    assert_case1_event(events.first().unwrap());
}

// ---------------------------------------------------------------------------
// Case 1: NON-UUID id, ANCHORED — SQLite
// ---------------------------------------------------------------------------

/// Case 1B — SQLite: same assertions as Case 1A, verifying that the
/// PersistenceKit SQLite backend durably stores the event and that the
/// SHA-256 row key and udc_qid anchor survive the SQLite round-trip.
#[test]
fn test_case1b_sqlite_non_uuid_id_anchored() {
    assert!(
        Uuid::parse_str(FACT_ID_NON_UUID).is_err(),
        "FACT_ID_NON_UUID must not be a valid UUID string — SHA-256 branch is the one under test"
    );

    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let drawer_id = Uuid::new_v4().to_string();
    insert_anchored_drawer(&store, &drawer_id);

    let fact = KGFact::new(
        FACT_ID_NON_UUID.to_string(),
        "gate-test-subject".to_string(),
        "is_about".to_string(),
        "gate-test-object".to_string(),
        drawer_id.clone(),
        NOW - 100,
    );
    store.add_kg_fact(&fact).unwrap();
    store
        .withdraw_kg_fact(FACT_ID_NON_UUID, ACTOR, Some(REASON), NOW + 1)
        .expect("withdraw_kg_fact must succeed for a valid active fact (Case 1B SQLite)");

    let row_uuid = deterministic_row_key(FACT_ID_NON_UUID);
    let events = store.audit_events_for_row(&row_uuid.to_string()).unwrap();
    assert_eq!(
        events.len(), 1,
        "exactly one audit event must be written (SQLite backend)"
    );
    assert_case1_event(events.first().unwrap());
}

// ---------------------------------------------------------------------------
// Case 2: UUID id (UUID passthrough) — InMemory
// ---------------------------------------------------------------------------

/// Case 2 — UUID id: when the fact's id IS a well-formed UUID string,
/// `deterministic_row_key` must return that UUID unchanged (UUID passthrough
/// branch, no SHA-256 derivation). The row_id in the audit event must equal
/// the original UUID's u128, not a re-derived value.
#[test]
fn test_case2_uuid_id_passthrough() {
    // Confirm the id IS a UUID — UUID passthrough branch is the one under test.
    let parsed_uuid = Uuid::parse_str(FACT_ID_UUID).expect("FACT_ID_UUID must be a valid UUID");

    let store = open_inmemory();
    let fact = KGFact::new(
        FACT_ID_UUID.to_string(),
        "uuid-passthrough-subject".to_string(),
        "is_about".to_string(),
        "uuid-passthrough-object".to_string(),
        "".to_string(),
        NOW - 100,
    );
    store.add_kg_fact(&fact).unwrap();
    store
        .withdraw_kg_fact(FACT_ID_UUID, ACTOR, None, NOW + 1)
        .expect("withdraw_kg_fact must succeed (Case 2)");

    let events = store.audit_events_for_row(FACT_ID_UUID).unwrap();
    assert_eq!(events.len(), 1, "exactly one audit event must be written (Case 2)");
    let event = events.first().unwrap();
    // UUID passthrough: row_id must equal the parsed UUID's u128, not a SHA-256 derivative.
    assert_eq!(
        event.row_id.0, parsed_uuid.as_u128(),
        "row_id must equal the original UUID unchanged (UUID passthrough branch)"
    );
}

// ---------------------------------------------------------------------------
// Case 3: UNANCHORED — InMemory
// ---------------------------------------------------------------------------

/// Case 3A — InMemory: a fact with an empty source_drawer_id takes the
/// null-anchor branch; the audit event must carry udc_code 0 and
/// qid_pointer 0. The retirement must succeed (null anchors are valid).
#[test]
fn test_case3a_inmemory_unanchored() {
    let store = open_inmemory();
    let fact_id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
    let fact = KGFact::new(
        fact_id.to_string(),
        "unanchored-subject".to_string(),
        "is_about".to_string(),
        "unanchored-object".to_string(),
        "".to_string(), // empty → null anchor
        NOW - 100,
    );
    store.add_kg_fact(&fact).unwrap();
    store
        .withdraw_kg_fact(fact_id, ACTOR, None, NOW + 1)
        .expect("withdraw_kg_fact must succeed for an unanchored fact");

    let events = store.audit_events_for_row(fact_id).unwrap();
    assert_eq!(
        events.len(), 1,
        "exactly one audit event must be written (unanchored fact)"
    );
    let event = events.first().unwrap();
    assert_eq!(
        event.after_lattice_anchor.udc_code, 0,
        "after_lattice_anchor.udc_code must be 0 (null anchor — empty source_drawer_id)"
    );
    assert_eq!(
        event.after_lattice_anchor.qid_pointer, 0,
        "after_lattice_anchor.qid_pointer must be 0 (null anchor — empty source_drawer_id)"
    );
}

// ---------------------------------------------------------------------------
// Case 3: UNANCHORED — SQLite
// ---------------------------------------------------------------------------

/// Case 3B — SQLite: same null-anchor assertions as Case 3A, verifying
/// that the SQLite backend stores and retrieves the null anchor correctly.
#[test]
fn test_case3b_sqlite_unanchored() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let fact_id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
    let fact = KGFact::new(
        fact_id.to_string(),
        "unanchored-subject-sqlite".to_string(),
        "is_about".to_string(),
        "unanchored-object-sqlite".to_string(),
        "".to_string(),
        NOW - 100,
    );
    store.add_kg_fact(&fact).unwrap();
    store
        .withdraw_kg_fact(fact_id, ACTOR, None, NOW + 1)
        .expect("withdraw_kg_fact must succeed for an unanchored fact (SQLite)");

    let events = store.audit_events_for_row(fact_id).unwrap();
    assert_eq!(
        events.len(), 1,
        "exactly one audit event must be written (unanchored fact, SQLite)"
    );
    let event = events.first().unwrap();
    assert_eq!(
        event.after_lattice_anchor.udc_code, 0,
        "after_lattice_anchor.udc_code must be 0 (null anchor — empty source_drawer_id, SQLite)"
    );
    assert_eq!(
        event.after_lattice_anchor.qid_pointer, 0,
        "after_lattice_anchor.qid_pointer must be 0 (null anchor — empty source_drawer_id, SQLite)"
    );
}

// ---------------------------------------------------------------------------
// Case 4: Anchor drawer absent — InMemory
// ---------------------------------------------------------------------------

/// Case 4 — the anchor drawer is absent: `source_drawer_id` names a drawer
/// id not present in the estate. The retirement must succeed (graceful
/// fallback to null anchor) rather than returning an error. Both anchor
/// halves must be 0, matching the null-anchor fallback branch.
#[test]
fn test_case4_absent_source_drawer() {
    let store = open_inmemory();
    let fact_id = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
    let absent_drawer_id = Uuid::new_v4().to_string(); // never inserted
    let fact = KGFact::new(
        fact_id.to_string(),
        "absent-drawer-subject".to_string(),
        "is_about".to_string(),
        "absent-drawer-object".to_string(),
        absent_drawer_id,
        NOW - 100,
    );
    store.add_kg_fact(&fact).unwrap();

    // Must succeed: absent drawer falls back to null anchor.
    store
        .withdraw_kg_fact(fact_id, ACTOR, None, NOW + 1)
        .expect("withdraw_kg_fact must succeed when source drawer is absent");

    let events = store.audit_events_for_row(fact_id).unwrap();
    assert_eq!(
        events.len(), 1,
        "exactly one audit event must be written (absent source drawer)"
    );
    let event = events.first().unwrap();
    // Absent drawer → null anchor fallback.
    assert_eq!(
        event.after_lattice_anchor.udc_code, 0,
        "after_lattice_anchor.udc_code must be 0 (absent drawer fallback to null anchor)"
    );
    assert_eq!(
        event.after_lattice_anchor.qid_pointer, 0,
        "after_lattice_anchor.qid_pointer must be 0 (absent drawer fallback to null anchor)"
    );
}

// ---------------------------------------------------------------------------
// Validation: empty changed_by
// ---------------------------------------------------------------------------

/// Input-validation test: passing an empty `changed_by` is rejected by the
/// pre-gate input guard before any transaction opens. No audit row is written
/// and the fact remains active (adjective_bitmap bits 0-5 == 0).
#[test]
fn test_validation_empty_changed_by_rejected() {
    let store = open_inmemory();
    let fact_id = "ffffffff-ffff-4fff-8fff-ffffffffffff";
    let fact = KGFact::new(
        fact_id.to_string(),
        "validation-subject".to_string(),
        "is_about".to_string(),
        "validation-object".to_string(),
        "".to_string(),
        NOW - 100,
    );
    store.add_kg_fact(&fact).unwrap();

    let err = store
        .withdraw_kg_fact(fact_id, "", None, NOW + 1)
        .expect_err("empty changed_by must be rejected");
    assert!(
        matches!(err, LocusKitError::InvalidContent(_)),
        "error must be InvalidContent for empty changed_by, got: {err:?}"
    );

    // Fact state must remain unchanged (bits 0-5 = 0 = active).
    let loaded = store
        .get_kg_fact(fact_id)
        .unwrap()
        .expect("fact must still exist after a rejected withdrawal");
    assert_eq!(
        loaded.adjective_bitmap & 0x3F, 0,
        "adjective bits 0-5 must remain 0 (active) after a rejected withdrawal"
    );
}
