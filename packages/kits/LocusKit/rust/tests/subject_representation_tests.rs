//! Subject trio tests (progressive recall PR-01).
//!
//! The subject is the one-sentence AI-facing summary of a drawer's
//! content — three nullable columns (`subject`, `subject_pipeline_version`,
//! `subject_at`) written or cleared together. NULL `subject` is the
//! backfill-eligibility predicate; there is no presence bit in v1 (the
//! operational feature-flag region is full — see
//! PR01_SUBJECT_QUAD_BLAST_RADIUS.md) and no bool field. Every
//! content-touching write NULLs the trio in the same statement, exactly
//! as it NULLs the distilled quad.
//!
//! Twin-parity mirror of Swift `SubjectRepresentationTests` case-for-case.
//!
//! Uses `InMemoryDrawerStore` because it is the single source of the real
//! `set_subject_representation` / `count_missing_subject` / expunge logic
//! (SQLite and Postgres wrappers delegate to it).

use locus_kit::drawer::Drawer;
use locus_kit::drawer_store::{DrawerStore, SUBJECT_LENGTH_CONTRACT};
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000;
const AI_V1: &str = "ai-v1";
const MINILLM_V1: &str = "minillm-v1";
const TEST_PARENT: &str = "00000000-0000-4000-8000-000000000001";
const SAMPLE_SUBJECT: &str =
    "Quarterly planning moved to Thursday; Sarah sends invites Monday; travel plans need updating.";

fn new_store() -> InMemoryDrawerStore {
    InMemoryDrawerStore::new(NOW, None).expect("store init")
}

fn make_id() -> String {
    Uuid::new_v4().to_string()
}

fn sample_drawer(id: &str) -> Drawer {
    let mut d = Drawer::new(
        id,
        "The quarterly planning meeting moved to Thursday. Sarah sends invites Monday.",
        TEST_PARENT,
        "bilby",
        NOW,
        "test-v1",
    );
    // udc_code is required by the gate for expunge paths.
    d.udc_code = "001".to_string();
    d
}

/// Fetch a drawer or panic with its id.
fn get(store: &InMemoryDrawerStore, id: &str) -> Drawer {
    store
        .get_drawer(id)
        .expect("get_drawer")
        .unwrap_or_else(|| panic!("drawer {id} must exist"))
}

// ---------------------------------------------------------------------------
// Entity defaults and constructor
// ---------------------------------------------------------------------------

#[test]
fn drawer_subject_fields_default_none() {
    let d = sample_drawer(&make_id());
    assert!(d.subject.is_none());
    assert!(d.subject_pipeline_version.is_none());
    assert!(d.subject_at.is_none());
}

// ---------------------------------------------------------------------------
// Store round-trip
// ---------------------------------------------------------------------------

#[test]
fn fresh_row_reads_none_subject() {
    let store = new_store();
    let id = make_id();
    store.add_drawer(&sample_drawer(&id), NOW).expect("add");
    let d = get(&store, &id);
    assert!(d.subject.is_none());
    assert!(d.subject_pipeline_version.is_none());
    assert!(d.subject_at.is_none());
}

#[test]
fn capture_time_subject_round_trips() {
    // PR-02's file_memory requirement lands the subject AT capture — the
    // row map must carry it on insert, not only via the setter.
    let store = new_store();
    let id = make_id();
    let mut d = sample_drawer(&id);
    d.subject = Some("Commute: switch to monthly transit pass.".to_string());
    d.subject_pipeline_version = Some(AI_V1.to_string());
    d.subject_at = Some(NOW);
    store.add_drawer(&d, NOW).expect("add");
    let loaded = get(&store, &id);
    assert_eq!(
        loaded.subject.as_deref(),
        Some("Commute: switch to monthly transit pass.")
    );
    assert_eq!(loaded.subject_pipeline_version.as_deref(), Some(AI_V1));
    assert_eq!(loaded.subject_at, Some(NOW));
}

#[test]
fn set_subject_populates_all_three_atomically() {
    let store = new_store();
    let id = make_id();
    store.add_drawer(&sample_drawer(&id), NOW).expect("add");

    let updated = store
        .set_subject_representation(&id, SAMPLE_SUBJECT, AI_V1, NOW + 200)
        .expect("set subject");
    assert_eq!(updated, 1);

    let d = get(&store, &id);
    assert_eq!(d.subject.as_deref(), Some(SAMPLE_SUBJECT));
    assert_eq!(d.subject_pipeline_version.as_deref(), Some(AI_V1));
    assert_eq!(d.subject_at, Some(NOW + 200));
}

#[test]
fn set_subject_replaces_prior() {
    let store = new_store();
    let id = make_id();
    store.add_drawer(&sample_drawer(&id), NOW).expect("add");
    store
        .set_subject_representation(&id, "First subject line.", AI_V1, NOW + 200)
        .expect("first set");
    store
        .set_subject_representation(&id, "Second subject line, regenerated.", MINILLM_V1, NOW + 300)
        .expect("second set");
    let d = get(&store, &id);
    assert_eq!(d.subject.as_deref(), Some("Second subject line, regenerated."));
    assert_eq!(d.subject_pipeline_version.as_deref(), Some(MINILLM_V1));
    assert_eq!(d.subject_at, Some(NOW + 300));
}

#[test]
fn set_subject_unknown_id_updates_zero_rows() {
    let store = new_store();
    let updated = store
        .set_subject_representation(
            "99999999-9999-4999-8999-999999999999",
            "x-marks-the-spot subject",
            AI_V1,
            NOW + 200,
        )
        .expect("set subject on unknown id");
    assert_eq!(updated, 0);
}

#[test]
fn length_contract_enforced_at_boundary() {
    let store = new_store();
    let id = make_id();
    store.add_drawer(&sample_drawer(&id), NOW).expect("add");

    let oversize = "x".repeat(SUBJECT_LENGTH_CONTRACT + 1);
    let err = store.set_subject_representation(&id, &oversize, AI_V1, NOW + 200);
    assert!(err.is_err(), "oversize subject must be rejected");

    // Exactly at the contract: accepted.
    let exact = "y".repeat(SUBJECT_LENGTH_CONTRACT);
    let updated = store
        .set_subject_representation(&id, &exact, AI_V1, NOW + 201)
        .expect("exact-length subject accepted");
    assert_eq!(updated, 1);
}

// ---------------------------------------------------------------------------
// NULL-on-content-write (regeneration trigger + erasure scrub)
// ---------------------------------------------------------------------------

#[test]
fn expunge_clears_subject_with_content() {
    let store = new_store();
    let id = make_id();
    store.add_drawer(&sample_drawer(&id), NOW).expect("add");
    store
        .set_subject_representation(&id, "Derived subject line.", AI_V1, NOW + 100)
        .expect("set subject");

    store
        .expunge_gated(&id, "test", None, NOW + 200, false)
        .expect("expunge_gated");

    let d = get(&store, &id);
    assert_eq!(d.content, "");
    // The subject is content-derived text: it must not outlive the
    // erased content.
    assert!(d.subject.is_none());
    assert!(d.subject_pipeline_version.is_none());
    assert!(d.subject_at.is_none());
}

// ---------------------------------------------------------------------------
// count_missing_subject (the debt counter)
// ---------------------------------------------------------------------------

#[test]
fn count_missing_subject_semantics() {
    let store = new_store();
    // d1: no subject (counts). d2: current-contract subject (does not
    // count). d3: stale-contract subject (counts — regeneration
    // candidate). d4: expunged (does not count — content scrubbed empty,
    // which the predicate excludes).
    let (i1, i2, i3, i4) = (make_id(), make_id(), make_id(), make_id());
    for id in [&i1, &i2, &i3, &i4] {
        store.add_drawer(&sample_drawer(id), NOW).expect("add");
    }
    store
        .set_subject_representation(&i2, "Current-contract subject.", MINILLM_V1, NOW + 100)
        .expect("set d2");
    store
        .set_subject_representation(&i3, "Stale-contract subject.", "ai-v0-legacy", NOW + 100)
        .expect("set d3");
    store
        .expunge_gated(&i4, "test", None, NOW + 200, false)
        .expect("expunge d4");

    let missing = store
        .count_missing_subject(MINILLM_V1)
        .expect("count missing");
    assert_eq!(missing, 2); // i1 (NULL) + i3 (version mismatch)
}
