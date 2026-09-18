#![cfg(feature = "persistencekit")]
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration};
use queuekit::{
    JobId, PersistenceKitBackend, QueueBackend, QueueCheckpointStore, QueueKit, StreamId, HLC,
};
use std::sync::Arc;

#[test]
fn checkpoint_cas_is_retained_and_not_runnable() {
    let storage = Arc::new(InMemoryStorage::new(EstateConfiguration::new(
        uuid::Uuid::new_v4(),
        BackendConfiguration::InMemory,
    )));
    PersistenceKitBackend::open_schema(storage.as_ref()).unwrap();
    let queue = QueueKit::new(PersistenceKitBackend::new(storage));
    let store = QueueCheckpointStore::new(&queue).unwrap();
    let id = JobId("checkpoint".into());
    let stream = StreamId("checkpoints".into());
    let stamp = HLC {
        physical_time: 1,
        logical_count: 0,
        node_id: 1,
    };
    assert!(store
        .compare_and_swap(&id, &stream, None, b"first", stamp)
        .unwrap());
    assert!(!store
        .compare_and_swap(&id, &stream, None, b"second", stamp)
        .unwrap());
    assert!(store
        .compare_and_swap(&id, &stream, Some(b"first"), b"second", stamp)
        .unwrap());
    assert!(!store
        .compare_and_swap(&id, &stream, Some(b"first"), b"first", stamp)
        .unwrap());
    assert!(queue.backend().drain_available().unwrap().is_empty());
    assert!(queue.backend().completed(None).unwrap().is_empty());
    let reopened = QueueCheckpointStore::new(&queue).unwrap();
    assert_eq!(
        reopened.read(&id, &stream).unwrap(),
        Some(b"second".to_vec())
    );
}

/// F6: `delete` removes a retained checkpoint outright — the seam GLK's
/// expunge fan-out uses so a permanently-retired subject (an expunged source
/// drawer) does not keep its checkpoint row forever with no future pass ever
/// revisiting it.
#[test]
fn delete_removes_retained_checkpoint() {
    let storage = Arc::new(InMemoryStorage::new(EstateConfiguration::new(
        uuid::Uuid::new_v4(),
        BackendConfiguration::InMemory,
    )));
    PersistenceKitBackend::open_schema(storage.as_ref()).unwrap();
    let queue = QueueKit::new(PersistenceKitBackend::new(storage));
    let store = QueueCheckpointStore::new(&queue).unwrap();
    let id = JobId("checkpoint".into());
    let stream = StreamId("checkpoints".into());
    let stamp = HLC {
        physical_time: 1,
        logical_count: 0,
        node_id: 1,
    };
    assert!(store
        .compare_and_swap(&id, &stream, None, b"evidence", stamp)
        .unwrap());
    assert_eq!(store.read(&id, &stream).unwrap(), Some(b"evidence".to_vec()));

    assert!(
        store.delete(&id, &stream).unwrap(),
        "the row was present, so delete must report true"
    );
    assert_eq!(
        store.read(&id, &stream).unwrap(),
        None,
        "the checkpoint must be gone, not merely marked done"
    );

    // Idempotent: deleting an already-absent checkpoint is not an error.
    assert!(
        !store.delete(&id, &stream).unwrap(),
        "deleting an absent checkpoint must report false, not error"
    );
}

/// F6: `delete` must not touch a DIFFERENT job's checkpoint on the same
/// stream — the predicate scopes on (id, stream, status == "checkpoint")
/// exactly as `read` and `compare_and_swap` do.
#[test]
fn delete_is_scoped_to_exact_id() {
    let storage = Arc::new(InMemoryStorage::new(EstateConfiguration::new(
        uuid::Uuid::new_v4(),
        BackendConfiguration::InMemory,
    )));
    PersistenceKitBackend::open_schema(storage.as_ref()).unwrap();
    let queue = QueueKit::new(PersistenceKitBackend::new(storage));
    let store = QueueCheckpointStore::new(&queue).unwrap();
    let stream = StreamId("checkpoints".into());
    let target_id = JobId("target".into());
    let other_id = JobId("other".into());
    let stamp = HLC {
        physical_time: 1,
        logical_count: 0,
        node_id: 1,
    };
    assert!(store
        .compare_and_swap(&target_id, &stream, None, b"evidence", stamp)
        .unwrap());
    assert!(store
        .compare_and_swap(&other_id, &stream, None, b"evidence", stamp)
        .unwrap());

    let _ = store.delete(&target_id, &stream).unwrap();

    assert_eq!(store.read(&target_id, &stream).unwrap(), None);
    assert_eq!(
        store.read(&other_id, &stream).unwrap(),
        Some(b"evidence".to_vec()),
        "a different job on the same stream must survive"
    );
}
