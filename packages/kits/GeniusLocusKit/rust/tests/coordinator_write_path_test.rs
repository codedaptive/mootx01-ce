// coordinator_write_path_test.rs — write-path conformance for EstateCoordinator.
//
// Tests the four write methods added in GLK-RUST-WRITE-PATH-01:
//   add_kg_fact, withdraw_kg_fact, add_diary_entry, diary_entries.
//
// Each test exercises the Rust EstateCoordinator surface against an in-memory
// estate, mirroring the Swift `VerbSurface` write-path tests. The authority
// for field semantics is VerbSurface.swift and DreamingWrites.swift.

use std::sync::Arc;

use genius_locus_kit::{EstateCoordinator, EstateHandle, VerbDispatchError, VerbError};

/// A handle whose UUID is not registered in any coordinator — triggers
/// EstateNotOpen on all verb calls. Uses a fixed non-zero UUID pattern
/// ([99u8; 16]) that no open call would ever produce.
fn unregistered_handle() -> EstateHandle {
    EstateHandle {
        estate_uuid: [99u8; 16],
        zoom_window_low: 0,
        zoom_window_high: 100,
    }
}
use locus_kit::{
    drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::OwnerCredentials,
};

const NOW: i64 = 1_700_000_000;

fn open_one() -> (EstateCoordinator, EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("owner"), 0, 100)
        .expect("open");
    (coord, handle)
}

// MARK: - add_kg_fact

/// A newly added kg-fact appears in recall_kg_facts (raw state 0, RowState Cluster A).
#[test]
fn add_kg_fact_appears_in_recall() {
    let (coord, handle) = open_one();
    let fact = coord
        .add_kg_fact(&handle, "Alice", "knows", "Bob", "src-1", NOW)
        .expect("add_kg_fact");
    assert!(!fact.id.is_empty(), "id must be a non-empty UUID string");
    assert_eq!(fact.subject, "Alice");
    assert_eq!(fact.predicate, "knows");
    assert_eq!(fact.object, "Bob");
    assert_eq!(fact.source_drawer_id, "src-1");
    assert_eq!(fact.filed_at, NOW);
    assert_eq!(fact.adjective_bitmap, 0, "new fact state is Active (0)");

    let facts = coord.recall_kg_facts(&handle).expect("recall");
    assert_eq!(facts.len(), 1);
    assert_eq!(facts[0].id, fact.id);
}

/// Each add_kg_fact call allocates a distinct UUID.
#[test]
fn add_kg_fact_ids_are_unique() {
    let (coord, handle) = open_one();
    let f1 = coord
        .add_kg_fact(&handle, "A", "p", "B", "src", NOW)
        .expect("add 1");
    let f2 = coord
        .add_kg_fact(&handle, "C", "q", "D", "src", NOW)
        .expect("add 2");
    assert_ne!(f1.id, f2.id);
}

/// add_kg_fact on an unknown handle returns EstateNotOpen.
#[test]
fn add_kg_fact_unknown_handle_returns_estate_not_open() {
    let coord = EstateCoordinator::new();
    let bad_handle = unregistered_handle();
    let err = coord
        .add_kg_fact(&bad_handle, "A", "p", "B", "", NOW)
        .unwrap_err();
    assert!(
        matches!(err, VerbDispatchError::EstateNotOpen { .. }),
        "got {err:?}"
    );
}

// MARK: - withdraw_kg_fact

/// A withdrawn kg-fact (RowState Cluster B, raw 18) is excluded from
/// active-recall (g_state_cluster >= RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW, 16).
#[test]
fn withdraw_kg_fact_excluded_from_active_recall() {
    let (coord, handle) = open_one();
    let fact = coord
        .add_kg_fact(&handle, "A", "p", "B", "src", NOW)
        .expect("add");
    coord.withdraw_kg_fact(&handle, &fact.id, NOW).expect("withdraw");

    let facts = coord.recall_kg_facts(&handle).expect("recall");
    assert!(
        facts.is_empty(),
        "withdrawn fact must not appear in active recall"
    );
}

// MARK: - revive round-trip through the GLK dispatch surface

/// capture → withdraw → mutate(Revive): the revive verb reaches LocusKit
/// through the GLK coordinator (the layer ARIA dispatches into) and a
/// withdrawn drawer returns to active. Re-reviving the now-active row
/// fails with the "already live" domain rule, proving the first revive
/// flipped the state to active. Mirrors the Swift VerbSurface round-trip.
#[test]
fn mutate_revive_from_withdrawn_round_trip() {
    use locus_kit::frames::MutationKind;
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::estate_types::LatticeAnchor;
    use locus_kit::frames::CaptureFrame;

    let (coord, handle) = open_one();
    let frame = CaptureFrame::new(
        "revive target",
        CaptureChannel::Typed,
        "test-room",
        LatticeAnchor::udc("0"),
        "test-agent",
        "test-embed-v1",
    );
    let drawer = coord.capture(&handle, frame, NOW).expect("capture");

    coord
        .withdraw(&handle, &drawer.id, Some("verb tests"), NOW)
        .expect("withdraw");

    // revive: withdrawn → active through the GLK verb surface.
    coord
        .mutate(&handle, &drawer.id, MutationKind::Revive, None)
        .expect("revive should succeed from withdrawn");

    // The row is now active; a second revive must refuse with the
    // already-live domain rule (proves the state actually flipped).
    let err = coord
        .mutate(&handle, &drawer.id, MutationKind::Revive, None)
        .unwrap_err();
    assert!(
        matches!(
            err,
            VerbDispatchError::Verb(VerbError::UnderlyingEstateFailure { .. })
        ),
        "re-revive of an active row must fail by domain rule: got {err:?}"
    );
}

/// Withdrawing a non-existent id returns an InvalidContent error.
#[test]
fn withdraw_kg_fact_unknown_id_returns_error() {
    let (coord, handle) = open_one();
    let err = coord
        .withdraw_kg_fact(&handle, "no-such-id", NOW)
        .unwrap_err();
    assert!(
        matches!(
            err,
            VerbDispatchError::Verb(VerbError::UnderlyingEstateFailure { .. })
        ),
        "got {err:?}"
    );
}

/// withdraw_kg_fact on an unknown handle returns EstateNotOpen.
#[test]
fn withdraw_kg_fact_unknown_handle_returns_estate_not_open() {
    let coord = EstateCoordinator::new();
    let bad_handle = unregistered_handle();
    let err = coord
        .withdraw_kg_fact(&bad_handle, "id", NOW)
        .unwrap_err();
    assert!(
        matches!(err, VerbDispatchError::EstateNotOpen { .. }),
        "got {err:?}"
    );
}

// MARK: - add_diary_entry

/// A newly added diary entry is returned by diary_entries.
#[test]
fn add_diary_entry_appears_in_diary_entries() {
    let (coord, handle) = open_one();
    let entry = coord
        .add_diary_entry(&handle, "skippy", "session note", "s1", "model-v1", NOW)
        .expect("add");
    assert!(!entry.id.is_empty());
    assert_eq!(entry.agent_name, "skippy");
    assert_eq!(entry.entry, "session note");
    assert_eq!(entry.topic, "s1");
    assert_eq!(entry.wing, "wing_skippy");
    assert_eq!(entry.room, "diary");
    assert_eq!(entry.filed_at, NOW);
    assert_eq!(entry.embedding_model_id, "model-v1");

    let entries = coord
        .diary_entries(&handle, "skippy", 10)
        .expect("diary_entries");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].id, entry.id);
}

/// Each add_diary_entry call allocates a distinct UUID.
#[test]
fn add_diary_entry_ids_are_unique() {
    let (coord, handle) = open_one();
    let e1 = coord
        .add_diary_entry(&handle, "skippy", "note A", "gen", "m", NOW)
        .expect("add 1");
    let e2 = coord
        .add_diary_entry(&handle, "skippy", "note B", "gen", "m", NOW)
        .expect("add 2");
    assert_ne!(e1.id, e2.id);
}

/// add_diary_entry substitutes "no-embedding" when embedding_model_id is empty.
/// Mirrors Swift DreamingWrites.addDiaryEntry guard.
#[test]
fn add_diary_entry_empty_model_id_substituted() {
    let (coord, handle) = open_one();
    let entry = coord
        .add_diary_entry(&handle, "skippy", "note", "gen", "", NOW)
        .expect("add");
    assert_eq!(
        entry.embedding_model_id, "no-embedding",
        "empty embedding_model_id must be substituted with 'no-embedding'"
    );
}

/// wing convention: add_diary_entry sets wing = "wing_<agent_name>".
#[test]
fn add_diary_entry_wing_convention() {
    let (coord, handle) = open_one();
    let entry = coord
        .add_diary_entry(&handle, "bilby", "note", "gen", "m", NOW)
        .expect("add");
    assert_eq!(entry.wing, "wing_bilby");
    assert_eq!(entry.room, "diary");
}

/// add_diary_entry on an unknown handle returns EstateNotOpen.
#[test]
fn add_diary_entry_unknown_handle_returns_estate_not_open() {
    let coord = EstateCoordinator::new();
    let bad_handle = unregistered_handle();
    let err = coord
        .add_diary_entry(&bad_handle, "skippy", "note", "", "", NOW)
        .unwrap_err();
    assert!(
        matches!(err, VerbDispatchError::EstateNotOpen { .. }),
        "got {err:?}"
    );
}

// MARK: - diary_entries

/// diary_entries returns only entries for the requested agent.
#[test]
fn diary_entries_filtered_by_agent_name() {
    let (coord, handle) = open_one();
    coord
        .add_diary_entry(&handle, "skippy", "note A", "gen", "m", NOW)
        .expect("add skippy");
    coord
        .add_diary_entry(&handle, "bilby", "note B", "gen", "m", NOW)
        .expect("add bilby");

    let skippy_entries = coord.diary_entries(&handle, "skippy", 10).expect("skippy");
    let bilby_entries = coord.diary_entries(&handle, "bilby", 10).expect("bilby");
    assert_eq!(skippy_entries.len(), 1);
    assert_eq!(bilby_entries.len(), 1);
    assert_eq!(skippy_entries[0].agent_name, "skippy");
    assert_eq!(bilby_entries[0].agent_name, "bilby");
}

/// diary_entries respects last_n limit.
#[test]
fn diary_entries_last_n_limit() {
    let (coord, handle) = open_one();
    for i in 0..5 {
        coord
            .add_diary_entry(&handle, "skippy", &format!("note {i}"), "gen", "m", NOW + i as i64)
            .expect("add");
    }
    let entries = coord.diary_entries(&handle, "skippy", 3).expect("diary");
    assert_eq!(entries.len(), 3, "last_n = 3 must cap the result set");
}

/// diary_entries on an unknown handle returns EstateNotOpen.
#[test]
fn diary_entries_unknown_handle_returns_estate_not_open() {
    let coord = EstateCoordinator::new();
    let bad_handle = unregistered_handle();
    let err = coord
        .diary_entries(&bad_handle, "skippy", 10)
        .unwrap_err();
    assert!(
        matches!(err, VerbDispatchError::EstateNotOpen { .. }),
        "got {err:?}"
    );
}

// MARK: - round-trip

/// add_kg_fact + withdraw_kg_fact + add_diary_entry + diary_entries
/// all compose correctly across a single estate.
#[test]
fn write_path_full_round_trip() {
    let (coord, handle) = open_one();

    // Capture two facts.
    let f1 = coord
        .add_kg_fact(&handle, "A", "p", "B", "src", NOW)
        .expect("add f1");
    let f2 = coord
        .add_kg_fact(&handle, "C", "q", "D", "src", NOW)
        .expect("add f2");

    // Both appear in active recall.
    let active = coord.recall_kg_facts(&handle).expect("recall before withdraw");
    assert_eq!(active.len(), 2);

    // Withdraw f1; only f2 remains.
    coord.withdraw_kg_fact(&handle, &f1.id, NOW).expect("withdraw");
    let active = coord.recall_kg_facts(&handle).expect("recall after withdraw");
    assert_eq!(active.len(), 1);
    assert_eq!(active[0].id, f2.id);

    // Write two diary entries for two agents.
    coord
        .add_diary_entry(&handle, "skippy", "note 1", "gen", "m", NOW)
        .expect("diary 1");
    coord
        .add_diary_entry(&handle, "bilby", "note 2", "gen", "m", NOW)
        .expect("diary 2");

    let skippy = coord.diary_entries(&handle, "skippy", 5).expect("skippy");
    let bilby = coord.diary_entries(&handle, "bilby", 5).expect("bilby");
    assert_eq!(skippy.len(), 1);
    assert_eq!(bilby.len(), 1);
}
