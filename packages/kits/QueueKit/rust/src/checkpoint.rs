//! Retained, CAS-fenced opaque progress in the existing queue envelope. These
//! records are neither runnable jobs nor successful domain-work receipts.
use crate::persistencekit::{PersistenceKitBackend, QUEUE_KIT_TABLE_NAME as TABLE};
use crate::{JobId, QueueBackend, QueueError, QueueKit, StreamId};
use persistence_kit::storage::Storage;
use persistence_kit::{Column, IsolationLevel, StoragePredicate as P, TypedValue as V};
use std::collections::BTreeMap;
use std::sync::Arc;
use substrate_types::hlc::HLC;

#[derive(Clone)]
pub struct QueueCheckpointStore {
    storage: Arc<dyn Storage>,
}

impl QueueCheckpointStore {
    pub fn acquire_drain_lease(
        &self,
        stream: &StreamId,
    ) -> Result<Option<QueueCheckpointLease>, QueueError> {
        use persistence_kit::storage::BackendConfiguration;
        match &self.storage.configuration().backend {
            BackendConfiguration::InMemory => Ok(Some(QueueCheckpointLease {
                stop: None,
                thread: None,
            })),
            BackendConfiguration::Sqlite { path, .. } => {
                let dir = std::path::Path::new(path).parent().ok_or_else(|| {
                    QueueError::BackendUnavailable("queue directory missing".into())
                })?;
                let lease = crate::DrainLease::new(
                    dir,
                    &stream.0,
                    format!("pid-{}-{}", std::process::id(), uuid::Uuid::new_v4()),
                );
                if !lease.try_acquire(crate::wall_now_secs()) {
                    return Ok(None);
                }
                let (stop, receive_stop) = std::sync::mpsc::channel();
                let thread = std::thread::spawn(move || {
                    while matches!(
                        receive_stop.recv_timeout(std::time::Duration::from_secs(5)),
                        Err(std::sync::mpsc::RecvTimeoutError::Timeout)
                    ) {
                        lease.heartbeat(crate::wall_now_secs());
                    }
                    lease.release();
                });
                Ok(Some(QueueCheckpointLease {
                    stop: Some(stop),
                    thread: Some(thread),
                }))
            }
            _ => Err(QueueError::BackendUnavailable(
                "checkpoint drain lease unavailable for this backend".into(),
            )),
        }
    }
    pub fn is_persistent(&self) -> bool {
        !matches!(
            self.storage.configuration().backend,
            persistence_kit::storage::BackendConfiguration::InMemory
        )
    }
    pub fn new<B: QueueBackend>(queue: &QueueKit<B>) -> Result<Self, QueueError> {
        let backend = queue
            .backend()
            .as_any()
            .downcast_ref::<PersistenceKitBackend>()
            .ok_or_else(|| {
                QueueError::BackendUnavailable("checkpoints require PersistenceKit".into())
            })?;
        Ok(Self {
            storage: backend.storage.clone(),
        })
    }

    pub fn read(&self, id: &JobId, stream: &StreamId) -> Result<Option<Vec<u8>>, QueueError> {
        let rows = self
            .storage
            .row_store()
            .query(TABLE, Some(&predicate(id, stream)), &[], Some(1), None)
            .map_err(error)?;
        rows.first()
            .map(|row| match row.get("payload") {
                Some(V::Blob(value)) => Ok(value.clone()),
                _ => Err(QueueError::BackendUnavailable(
                    "invalid checkpoint payload".into(),
                )),
            })
            .transpose()
    }

    pub fn compare_and_swap(
        &self,
        id: &JobId,
        stream: &StreamId,
        expected: Option<&[u8]>,
        payload: &[u8],
        stamp: HLC,
    ) -> Result<bool, QueueError> {
        let mut changed = false;
        self.storage
            .transaction(IsolationLevel::Serializable, &mut |txn| {
                let rows = txn.row_store().query(
                    TABLE,
                    Some(&predicate(id, stream)),
                    &[],
                    Some(1),
                    None,
                )?;
                if let Some(row) = rows.first() {
                    if let Some(V::Blob(previous)) = row.get("payload") {
                        if Some(previous.as_slice()) == expected {
                            changed = txn.row_store().update(
                                TABLE,
                                BTreeMap::from([("payload".into(), V::Blob(payload.to_vec()))]),
                                &predicate(id, stream),
                            )? == 1;
                        }
                    }
                } else if expected.is_none() {
                    txn.row_store().insert(
                        TABLE,
                        BTreeMap::from([
                            ("id".into(), V::Text(id.0.clone())),
                            ("stream_id".into(), V::Text(stream.0.clone())),
                            ("physical_time".into(), V::Int(stamp.physical_time)),
                            ("logical_count".into(), V::Int(stamp.logical_count as i64)),
                            ("node_id".into(), V::Int(stamp.node_id as i64)),
                            ("priority".into(), V::Int(50)),
                            ("status".into(), V::Text("checkpoint".into())),
                            ("payload".into(), V::Blob(payload.to_vec())),
                            (
                                "extensions".into(),
                                V::Text("{\"retainedCheckpoint\":true}".into()),
                            ),
                        ]),
                    )?;
                    changed = true;
                }
                Ok(())
            })
            .map_err(error)?;
        Ok(changed)
    }

    pub fn payloads(&self, stream: &StreamId) -> Result<Vec<Vec<u8>>, QueueError> {
        self.storage
            .row_store()
            .query(
                TABLE,
                Some(&P::And(vec![
                    P::Eq(col("stream_id"), V::Text(stream.0.clone())),
                    P::Eq(col("status"), V::Text("checkpoint".into())),
                ])),
                &[],
                None,
                None,
            )
            .map_err(error)?
            .into_iter()
            .map(|row| match row.get("payload") {
                Some(V::Blob(value)) => Ok(value.clone()),
                _ => Err(QueueError::BackendUnavailable(
                    "invalid checkpoint payload".into(),
                )),
            })
            .collect()
    }
}

pub struct QueueCheckpointLease {
    stop: Option<std::sync::mpsc::Sender<()>>,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl Drop for QueueCheckpointLease {
    fn drop(&mut self) {
        self.stop.take();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn col(name: &str) -> Column {
    Column::new(TABLE, name)
}
fn predicate(id: &JobId, stream: &StreamId) -> P {
    P::And(vec![
        P::Eq(col("id"), V::Text(id.0.clone())),
        P::Eq(col("stream_id"), V::Text(stream.0.clone())),
        P::Eq(col("status"), V::Text("checkpoint".into())),
    ])
}
fn error(e: impl std::fmt::Debug) -> QueueError {
    QueueError::BackendUnavailable(format!("{e:?}"))
}
