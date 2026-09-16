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
