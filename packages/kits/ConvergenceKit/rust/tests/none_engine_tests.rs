// Integration tests for convergence-kit's None backend.

use std::sync::Arc;
use std::time::Duration;
use persistence_kit::{inmemory::InMemoryStorage, Storage};
use convergence_kit::{
    ConflictPolicy, NoSyncEngine, SyncDirection, SyncEngine, SyncError, SyncManifest, SyncState,
    SyncedTable,
};
use uuid::Uuid;

fn make_storage() -> Arc<dyn Storage> {
    let storage = InMemoryStorage::with_estate(Uuid::new_v4());
    Arc::new(storage)
}

fn sample_manifest() -> SyncManifest {
    SyncManifest::new(
        "test-kit",
        1,
        "zone-test",
        vec![SyncedTable::new("drawers", "id")
            .with_direction(SyncDirection::Bidirectional)
            .with_conflict_policy(ConflictPolicy::LastWriterWinsByHLC)],
    )
}

#[test]
fn enable_succeeds_when_disabled() {
    let mut engine = NoSyncEngine::new();
    let storage = make_storage();
    assert!(engine.enable(sample_manifest(), storage).is_ok());
}

#[test]
fn enable_twice_returns_already_enabled() {
    let mut engine = NoSyncEngine::new();
    let storage = make_storage();
    engine.enable(sample_manifest(), storage.clone()).unwrap();
    match engine.enable(sample_manifest(), storage) {
        Err(SyncError::AlreadyEnabled) => {}
        other => panic!("expected AlreadyEnabled, got {:?}", other),
    }
}

#[test]
fn push_pull_before_enable_errors() {
    let mut engine = NoSyncEngine::new();
    matches!(engine.push(), Err(SyncError::NotEnabled));
    matches!(engine.pull(), Err(SyncError::NotEnabled));
}

#[test]
fn push_pull_after_enable_returns_empty_receipts() {
    let mut engine = NoSyncEngine::new();
    let storage = make_storage();
    engine.enable(sample_manifest(), storage).unwrap();
    let push_receipt = engine.push().unwrap();
    assert_eq!(push_receipt.pushed, 0);
    assert_eq!(push_receipt.pulled, 0);
    let pull_receipt = engine.pull().unwrap();
    assert_eq!(pull_receipt.pulled, 0);
}

#[test]
fn state_transitions_with_enable_disable() {
    let mut engine = NoSyncEngine::new();
    let storage = make_storage();
    assert!(matches!(engine.state(), SyncState::Disabled));
    engine.enable(sample_manifest(), storage).unwrap();
    assert!(matches!(engine.state(), SyncState::Enabled { .. }));
    engine.disable().unwrap();
    assert!(matches!(engine.state(), SyncState::Disabled));
}

#[test]
fn subscribe_returns_immediately_finished_receiver() {
    let mut engine = NoSyncEngine::new();
    let rx = engine.subscribe();
    // First recv returns Disconnected quickly because the sender
    // was dropped.
    let result = rx.recv_timeout(Duration::from_millis(50));
    assert!(result.is_err());
}

#[test]
fn manifest_lookup_finds_known_table() {
    let manifest = sample_manifest();
    assert!(manifest.table_named("drawers").is_some());
    assert!(manifest.table_named("absent").is_none());
}

#[test]
fn synced_table_defaults_are_bidirectional_and_lww() {
    let t = SyncedTable::new("rows", "id");
    assert_eq!(t.direction, SyncDirection::Bidirectional);
    assert_eq!(t.conflict_policy, ConflictPolicy::LastWriterWinsByHLC);
}
