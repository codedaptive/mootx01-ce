//! Atomic contradiction-proposal filing over `SqliteDrawerStore`: the port of
//! `AtomicConflictProposalTests.swift`. Same four theorems, same assertions:
//! one filing creates once and replays the stored tunnel; stale evidence,
//! tombstoned evidence and withdrawn evidence answer `Stale` without a write;
//! a superseded replay answers `Settled` without filing a replacement.

use std::collections::BTreeMap;

use locus_kit::adjectives::State;
use locus_kit::drawer::Drawer;
use locus_kit::drawer_store::{
    conflict_proposal_digests, AtomicConflictProposalOutcome, AtomicConflictProposalRequest,
    DrawerStore,
};
use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
use locus_kit::node_store::NodeStore;
use locus_kit::tunnel::Tunnel;
use locus_kit::tunnel_operational::{TunnelKind, TunnelLifecycle};
use persistence_kit::predicate::StoragePredicate;
use persistence_kit::types::{Column, TypedValue};
use substrate_lib::row_state::RowVerb;
use uuid::Uuid;

/// 2023-11-14T22:13:20Z in milliseconds, the instant the Swift twin uses.
const NOW: i64 = 1_700_000_000_000;

/// Deletes the SQLite file and its WAL/SHM companions when dropped.
struct TempDb {
    path: String,
}

impl TempDb {
    fn new() -> Self {
        let name = format!("locus_atomic_conflict_{}.db", Uuid::new_v4().simple());
        let path = std::env::temp_dir().join(name).to_string_lossy().into_owned();
        TempDb { path }
    }
}

impl Drop for TempDb {
    fn drop(&mut self) {
        for suffix in &["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{}", self.path, suffix));
        }
    }
}

struct Fixture {
    store: SqliteDrawerStore,
    _db: TempDb,
    source: Drawer,
    target: Drawer,
}

/// One estate with a root → Wing → Room tree and two drawers in the room.
fn make_fixture() -> Fixture {
    let db = TempDb::new();
    let store = SqliteDrawerStore::from_path(&db.path, NOW, None, 5.0).unwrap();
    let storage = store.storage().expect("storage must be available");
    let nodes = NodeStore::new(storage, None);
    let root = nodes.create_root("Estate", NOW).unwrap();
    let wing = nodes.create_node("Wing", root.id, NOW).unwrap();
    let room = nodes.create_node("Room", wing.id, NOW).unwrap();
    let room_id = room.id.to_string();
    let mut source = Drawer::new(Uuid::new_v4().to_string(), "source evidence", &room_id, "test", NOW, "test-model");
    source.udc_code = "001".to_owned();
    let mut target = Drawer::new(Uuid::new_v4().to_string(), "target evidence", &room_id, "test", NOW, "test-model");
    target.udc_code = "001".to_owned();
    store.add_drawer(&source, NOW).unwrap();
    store.add_drawer(&target, NOW).unwrap();
    Fixture { store, _db: db, source, target }
}

fn never_suppress(_tier: u8, _renewal: &str, _history: &[(u8, String)]) -> bool {
    false
}

/// The hunt's canonical pair spelling: both ids lowercased, sorted, joined by
/// a double bar.
fn pair_key(source: &Drawer, target: &Drawer) -> String {
    let mut ordered = [source.id.to_lowercase(), target.id.to_lowercase()];
    ordered.sort();
    format!("{}||{}", ordered[0], ordered[1])
}

fn request(source: &Drawer, target: &Drawer) -> AtomicConflictProposalRequest {
    let pair_key = pair_key(source, target);
    let renewal_identity = format!("tier1:{pair_key}:evidence-1");
    let (source_digest, evidence_digest) = conflict_proposal_digests(source, target, 1, &renewal_identity);
    AtomicConflictProposalRequest {
        source_drawer_id: source.id.clone(),
        target_drawer_id: target.id.clone(),
        pair_key,
        tier: 1,
        label: format!("{renewal_identity} proposed contradiction"),
        renewal_identity,
        replay_identity: "aria-v2:evidence-1".to_owned(),
        source_digest,
        evidence_digest,
        decline_suppresses: never_suppress,
    }
}

fn contradiction_tunnels(store: &SqliteDrawerStore) -> Vec<Tunnel> {
    store.all_tunnels().unwrap().into_iter().filter(|t| t.kind == TunnelKind::Contradicts).collect()
}

fn tunnel_of(outcome: &AtomicConflictProposalOutcome) -> Option<(&str, &str)> {
    match outcome {
        AtomicConflictProposalOutcome::Created { tunnel_id, lifecycle }
        | AtomicConflictProposalOutcome::Existing { tunnel_id, lifecycle } => Some((tunnel_id, lifecycle)),
        AtomicConflictProposalOutcome::Settled | AtomicConflictProposalOutcome::Stale => None,
    }
}

#[test]
fn atomic_conflict_proposal_creates_once_replays_the_stored_tunnel_and_rejects_stale_evidence() {
    let fixture = make_fixture();
    let valid = request(&fixture.source, &fixture.target);

    let created = fixture.store.atomic_file_conflict_proposal(&valid, NOW + 1).unwrap();
    let (created_id, created_lifecycle) = tunnel_of(&created).expect("first filing creates a tunnel");
    assert_eq!(created_lifecycle, "proposed");
    let created_id = created_id.to_owned();

    let replayed = fixture.store.atomic_file_conflict_proposal(&valid, NOW + 2).unwrap();
    let (replayed_id, replayed_lifecycle) = tunnel_of(&replayed).expect("replay returns the stored tunnel");
    assert_eq!(replayed_id, created_id);
    assert_eq!(replayed_lifecycle, "proposed");
    assert_eq!(contradiction_tunnels(&fixture.store).len(), 1);

    // Validation and write share one serializable transaction: a digest that
    // no longer matches the fresh row neither creates nor replays.
    let stale = AtomicConflictProposalRequest {
        source_digest: "0".repeat(64),
        decline_suppresses: never_suppress,
        ..request(&fixture.source, &fixture.target)
    };
    assert_eq!(
        fixture.store.atomic_file_conflict_proposal(&stale, NOW + 3).unwrap(),
        AtomicConflictProposalOutcome::Stale,
        "stale evidence must not create or replay a proposal"
    );
    // A pair key that is not the hunt's canonical spelling is stale too.
    let single_bar = AtomicConflictProposalRequest {
        pair_key: valid.pair_key.replace("||", "|"),
        decline_suppresses: never_suppress,
        ..request(&fixture.source, &fixture.target)
    };
    assert_eq!(
        fixture.store.atomic_file_conflict_proposal(&single_bar, NOW + 4).unwrap(),
        AtomicConflictProposalOutcome::Stale,
        "a non-canonical pair key must not create or replay a proposal"
    );
    assert_eq!(contradiction_tunnels(&fixture.store).len(), 1);
}

#[test]
fn selected_evidence_tombstoned_after_analysis_cannot_file_a_contradiction() {
    let fixture = make_fixture();
    let selected = request(&fixture.source, &fixture.target);

    let mut values = BTreeMap::new();
    values.insert("tombstonedAt".to_owned(), TypedValue::Timestamp(NOW + 2));
    let storage = fixture.store.storage().expect("storage must be available");
    let updated = storage
        .row_store()
        .update(
            "drawers",
            values,
            &StoragePredicate::Eq(Column::new("drawers", "id"), TypedValue::Text(fixture.source.id.clone())),
        )
        .unwrap();
    assert_eq!(updated, 1, "fixture must tombstone exactly the source drawer");

    assert_eq!(
        fixture.store.atomic_file_conflict_proposal(&selected, NOW + 3).unwrap(),
        AtomicConflictProposalOutcome::Stale,
        "tombstoned selected evidence must not file a contradiction"
    );
    assert!(contradiction_tunnels(&fixture.store).is_empty());
}

#[test]
fn selected_evidence_withdrawn_after_analysis_cannot_file_a_contradiction() {
    let fixture = make_fixture();
    let selected = request(&fixture.source, &fixture.target);

    fixture
        .store
        .mutate_state(&fixture.source.id, State::Withdrawn, RowVerb::Retract, "test", None, NOW + 1)
        .unwrap();

    assert_eq!(
        fixture.store.atomic_file_conflict_proposal(&selected, NOW + 2).unwrap(),
        AtomicConflictProposalOutcome::Stale,
        "withdrawn selected evidence must not file a contradiction"
    );
    assert!(contradiction_tunnels(&fixture.store).is_empty());
}

#[test]
fn superseded_replay_reports_settled_without_filing_a_replacement() {
    let fixture = make_fixture();
    let selected = request(&fixture.source, &fixture.target);

    // The stored label ends with the replay identity, which is how the filer
    // recognises the replay of this exact selection.
    let mut superseded = Tunnel::new(
        Uuid::new_v4().to_string(),
        "Wing".to_owned(), "Room".to_owned(), "Wing".to_owned(), "Room".to_owned(),
        format!("{} {}", selected.label, selected.replay_identity),
        "test".to_owned(), NOW,
    );
    superseded.source_drawer_id = Some(fixture.source.id.clone());
    superseded.target_drawer_id = Some(fixture.target.id.clone());
    superseded.kind = TunnelKind::Contradicts;
    superseded.operational_bitmap = TunnelLifecycle::Superseded.raw_value() << 3;
    fixture.store.add_tunnel(&superseded).unwrap();

    assert_eq!(
        fixture.store.atomic_file_conflict_proposal(&selected, NOW + 1).unwrap(),
        AtomicConflictProposalOutcome::Settled,
        "superseded replay must report settled"
    );
    assert_eq!(contradiction_tunnels(&fixture.store).len(), 1);
}
