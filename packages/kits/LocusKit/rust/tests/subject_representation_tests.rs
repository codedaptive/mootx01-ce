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
const TEST_ACTOR: &str = "test-actor";
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
        .set_subject_representation(&id, SAMPLE_SUBJECT, AI_V1, NOW + 200, TEST_ACTOR, None)
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
        .set_subject_representation(&id, "First subject line.", AI_V1, NOW + 200, TEST_ACTOR, None)
        .expect("first set");
    store
        .set_subject_representation(&id, "Second subject line, regenerated.", MINILLM_V1, NOW + 300, TEST_ACTOR, None)
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
            TEST_ACTOR,
            None,
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
    let err = store.set_subject_representation(&id, &oversize, AI_V1, NOW + 200, TEST_ACTOR, None);
    assert!(err.is_err(), "oversize subject must be rejected");

    // Exactly at the contract: accepted.
    let exact = "y".repeat(SUBJECT_LENGTH_CONTRACT);
    let updated = store
        .set_subject_representation(&id, &exact, AI_V1, NOW + 201, TEST_ACTOR, None)
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
        .set_subject_representation(&id, "Derived subject line.", AI_V1, NOW + 100, TEST_ACTOR, None)
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
        .set_subject_representation(&i2, "Current-contract subject.", MINILLM_V1, NOW + 100, TEST_ACTOR, None)
        .expect("set d2");
    store
        .set_subject_representation(&i3, "Stale-contract subject.", "ai-v0-legacy", NOW + 100, TEST_ACTOR, None)
        .expect("set d3");
    store
        .expunge_gated(&i4, "test", None, NOW + 200, false)
        .expect("expunge d4");

    let missing = store
        .count_missing_subject(MINILLM_V1)
        .expect("count missing");
    assert_eq!(missing, 2); // i1 (NULL) + i3 (version mismatch)
}

// ---------------------------------------------------------------------------
// Tier-aware debt enumeration (PR-10) — twin of Swift
// tierAwareDebtEnumeration: NULL rows and listed tiers enumerate; ai-v1
// (above the requester) and the requester's own tier never do.
// ---------------------------------------------------------------------------

#[test]
fn tier_aware_debt_enumeration() {
    let store = new_store();
    let (null_id, ai_id, cons_id, model_id) = (make_id(), make_id(), make_id(), make_id());
    for id in [&null_id, &ai_id, &cons_id, &model_id] {
        store.add_drawer(&sample_drawer(id), NOW).expect("add");
    }
    store
        .set_subject_representation(&ai_id, "Filing-AI subject.", "ai-v1", NOW + 1, TEST_ACTOR, None)
        .expect("set ai");
    store
        .set_subject_representation(&cons_id, "Deterministic vague subject.", "consolidation-v1", NOW + 1, TEST_ACTOR, None)
        .expect("set cons");
    store
        .set_subject_representation(&model_id, "Model subject.", "minillm-v1", NOW + 1, TEST_ACTOR, None)
        .expect("set model");

    // NULL-only (the PR-09 default): just the NULL row.
    assert_eq!(store.count_subject_debt().unwrap(), 1);
    let null_only = store.subject_debt_batch(10).unwrap();
    assert_eq!(null_only.iter().map(|d| d.id.as_str()).collect::<Vec<_>>(), vec![null_id.as_str()]);

    // The Apple rider's view: NULL + the deterministic tiers; ai-v1 and
    // minillm-v1 NEVER enumerate.
    let tiers = vec!["consolidation-v1".to_string(), "seed-v1".to_string()];
    let rider_view = store.subject_debt_batch_including(10, &tiers).unwrap();
    let mut got: Vec<&str> = rider_view.iter().map(|d| d.id.as_str()).collect();
    got.sort();
    let mut want = vec![null_id.as_str(), cons_id.as_str()];
    want.sort();
    assert_eq!(got, want);
    assert_eq!(store.count_subject_debt_including(&tiers).unwrap(), 2);
}

// ---------------------------------------------------------------------------
// Custody audit row (MXE-SK — Codex cc90c5dcecb081918c159788e1ffb3d6).
// The atomicity half (forced audit-append failure rolls back the column
// write) lives inline in drawer_store_inmemory.rs, where the pub(crate)
// core constructor allows storage injection:
// `set_subject_failed_audit_append_rolls_back_subject_write`.
// ---------------------------------------------------------------------------

#[test]
fn set_subject_seals_exactly_one_custody_event_with_note() {
    let store = new_store();
    let id = make_id();
    store.add_drawer(&sample_drawer(&id), NOW).expect("add");

    let before = store.audit_events_for_row(&id).expect("trail before").len();
    store
        .set_subject_representation(
            &id,
            SAMPLE_SUBJECT,
            AI_V1,
            NOW + 200,
            TEST_ACTOR,
            Some("meeting moved; subject stale"),
        )
        .expect("set subject");

    let events = store.audit_events_for_row(&id).expect("trail after");
    assert_eq!(events.len(), before + 1, "exactly one custody event sealed");
    let e = events.last().expect("custody event");
    assert_eq!(e.verb, "setSubject");
    assert_eq!(e.actor, TEST_ACTOR);
    assert_eq!(e.reason.as_deref(), Some("meeting moved; subject stale"));
    // setSubject changes no bitmap and no anchor: before == after on
    // every value field. Cross-port equivalence: the Swift twin asserts
    // the same (verb, actor, reason, before==after) tuple for the same
    // inputs (SubjectRepresentationTests).
    assert_eq!(e.before_bitmaps, Some(e.after_bitmaps));
    assert_eq!(e.before_lattice_anchor, Some(e.after_lattice_anchor));
}

#[test]
fn set_subject_without_note_seals_row_with_absent_reason() {
    let store = new_store();
    let id = make_id();
    store.add_drawer(&sample_drawer(&id), NOW).expect("add");

    let before = store.audit_events_for_row(&id).expect("trail before").len();
    store
        .set_subject_representation(&id, SAMPLE_SUBJECT, AI_V1, NOW + 200, TEST_ACTOR, None)
        .expect("set subject");

    let events = store.audit_events_for_row(&id).expect("trail after");
    assert_eq!(
        events.len(),
        before + 1,
        "an absent reason is not an absent row: the custody event still seals"
    );
    let e = events.last().expect("custody event");
    assert_eq!(e.verb, "setSubject");
    assert_eq!(e.reason, None, "no note supplied ⇒ absent reason");
}

#[test]
fn set_subject_unknown_id_seals_no_audit_event() {
    let store = new_store();
    let ghost = "99999999-9999-4999-8999-999999999999";
    let updated = store
        .set_subject_representation(ghost, "x", AI_V1, NOW + 200, TEST_ACTOR, None)
        .expect("unknown id returns Ok(0)");
    assert_eq!(updated, 0);
    let events = store.audit_events_for_row(ghost).expect("trail");
    assert!(events.is_empty(), "no row updated ⇒ no custody event");
}
